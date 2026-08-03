package PBCFTools::Backend::Cluster;

# Shared async, wave-based cluster controller for LSF and Slurm.
#
# Design (ported from the original bsub.pl, generalized):
#   * Submission is ASYNC and BATCHED. Each "wave" writes one shell script that
#     runs the scheduler submit commands SEQUENTIALLY, launched in the background
#     (`bash wave.sh > wave.out &`). This never blocks the monitor and naturally
#     rate-limits submission to one `bsub`/`sbatch` at a time (no login-node storm).
#   * Job IDs are recovered by MARKER from the wave output at a fixed interval,
#     not by scheduler-side name lookup — so job names need no uniqueness and the
#     whole name-collision/recovery problem class disappears.
#   * A job is a FAILURE (=> re-batch with escalated resources) if:
#       (1) it never got an ID and a pre-scheduler local rejection was proven, or
#       (2) its exit-code sentinel .rc is nonzero, or the scheduler reports a
#           terminal-failure state, or
#       (3) it ended with no confirmed exit code (fail-closed: success must be
#           PROVEN by an exit-0 sentinel).
#   * Failures with try < ptry are escalated (+pmem_inc% mem, +pwal_inc% wall) and
#     re-submitted in the NEXT wave. try == ptry -> permanent failure.
#   * Waves do not overlap: a new wave launches only when the previous wave's
#     submission has finished (its .out contains PBCF_SUBMIT_DONE).
#
# Subclasses (LSF, Slurm) supply only scheduler-specific primitives:
#   _submit_program() _submit_cmd($job,$script) _extract_id($text)
#   _poll_states(\@ids) _cancel(\@ids) _fmt_wal($min) _fmt_mem($mb)

use strict;
use warnings;
use Carp qw(croak);
use File::Spec;
use File::Temp qw(tempfile);
use IO::Handle;   # $fh->error — a transcript read error must not read as clean EOF
use POSIX qw(ceil :sys_wait_h :signal_h);
use Time::HiRes qw(time sleep);
use PBCFTools::Helpers;

use constant {
    MARK        => 'PBCF_MARK',
    RC          => 'PBCF_RC',
    SUBMIT_DONE => 'PBCF_SUBMIT_DONE',
    # Resource ceilings, shared by up-front validation and per-retry escalation so
    # the two can never drift: wall time <= 366 days (in minutes), memory <= 100 TB.
    MAX_WAL_MIN => 366 * 24 * 60,
    MAX_MEM_MB  => 100 * 1024 * 1024,
};

sub new {
    my ($class, %opts) = @_;
    croak("--p_jobs is required for cluster mode") unless $opts{pjobs} && $opts{pjobs} > 0;

    my $wal_min = _parse_wal_min($opts{pwal} // '1hr');
    my $mem_mb  = _parse_mem_mb($opts{pmem}  // '8GB');
    croak("Invalid --p_wal '" . ($opts{pwal} // '') . "'") unless $wal_min && $wal_min > 0;
    croak("Invalid --p_mem '" . ($opts{pmem} // '') . "'") unless $mem_mb  && $mem_mb  > 0;

    my $self = bless {
        pjobs    => $opts{pjobs},
        ppre     => $opts{ppre} // 'pbcf',
        wal_min  => $wal_min,
        mem_mb   => $mem_mb,
        pcpu     => $opts{pcpu} // 1,
        pint     => $opts{pint} // 10,
        ptry     => $opts{ptry} // 3,
        pmem_inc => defined $opts{pmem_inc} ? $opts{pmem_inc} : 50,   # % mem bump per retry
        pwal_inc => defined $opts{pwal_inc} ? $opts{pwal_inc} : 50,   # % wall bump per retry
        pqueue   => $opts{pqueue},
        paccount => $opts{paccount},
        pdir     => $opts{pdir},           # where wave scripts/outputs live (shared FS)
        verbose  => $opts{verbose} // 0,
        nonce    => $opts{nonce} // _gen_nonce(),   # host+PID+random: unique across submit hosts
        submitted_ids  => [],
        _submitter_pids => [],              # background wave-submitter PIDs (for cleanup)
        _client_pids    => {},               # supervised scheduler poll/cancel clients
        _wave_seq       => 0,
        _cleaning       => 0,
    }, $class;

    # Validate numeric controls up front (bsub.pl and direct callers don't go
    # through pbcftools.pl's guards). Bad values would otherwise reach the
    # scheduler command or make escalation non-monotonic (mem->0, wall<0).
    my %max = (pjobs => 100_000, pcpu => 1024, pint => 86_400, ptry => 100,
               pmem_inc => 10_000, pwal_inc => 10_000);
    for my $k (qw(pjobs pcpu pint ptry)) {
        my $v = $self->{$k};
        croak("$k must be an integer in 1..$max{$k} (got '" . (defined $v ? $v : 'undef') . "')")
            unless defined $v && $v =~ /^\d+$/ && $v >= 1 && $v <= $max{$k};
    }
    for my $k (qw(pmem_inc pwal_inc)) {
        my $v = $self->{$k};
        croak("$k must be an integer in 0..$max{$k} (got '" . (defined $v ? $v : 'undef') . "')")
            unless defined $v && $v =~ /^\d+$/ && $v <= $max{$k};
    }
    # Once cancellation starts, retry only after a healthy scheduler poll proves
    # the old ID terminal/absent.  Bound that wait so an ambiguous scheduler state
    # becomes a hard UNKNOWN rather than hanging forever or spawning an overlap.
    if (defined $opts{cancel_timeout}) {
        croak("cancel_timeout must be an integer in 1..3600")
            unless $opts{cancel_timeout} =~ /^\d+$/
                && $opts{cancel_timeout} >= 1 && $opts{cancel_timeout} <= 3600;
        $self->{cancel_timeout} = $opts{cancel_timeout};
    } else {
        my $timeout = 6 * $self->{pint};
        $timeout = 120 if $timeout < 120;
        $timeout = 600 if $timeout > 600;
        $self->{cancel_timeout} = $timeout;
    }
    # A single scheduler poll/cancel operation must return control promptly even
    # when the site client hangs.  The cancellation barrier retains the longer
    # cancel_timeout; this shorter bound applies only to one client operation.
    $self->{client_timeout} = $self->{cancel_timeout} < 30
        ? $self->{cancel_timeout} : 30;
    return $self;
}

sub pjobs { return $_[0]->{pjobs} }

# Display names for a list of jobs, applying the '?' fallback used in every
# UNKNOWN/stray warning and croak message.
sub _job_names { return map { $_->{name} // '?' } @{$_[0]} }

# A run-unique, filename-safe nonce: short hostname + PID + random bytes. PID
# alone collides across submit hosts sharing one cluster filesystem; the random
# suffix also covers PID reuse. Used for the caller-created private run root and
# wave filenames so concurrent controllers never share worker/control artifacts.
sub _gen_nonce {
    my $host = (POSIX::uname())[1] // 'h';
    $host =~ s/[^A-Za-z0-9]//g;
    $host = substr($host, 0, 8) || 'h';
    my $rand = '';
    if (open(my $u, '<:raw', '/dev/urandom')) { read($u, my $b, 4); close $u; $rand = unpack('H*', $b); }
    $rand ||= sprintf('%08x', int(rand(2**31)));
    return $host . $$ . $rand;
}

# Create the private root used by one controller.  mkdir is the exclusivity
# primitive: callers must never use an "absent, then make_path" sequence for the
# run directory because two controllers can both pass that check.
sub _make_run_dir {
    my ($parent, $prefix, $nonce) = @_;
    croak("Run-directory parent is required") unless defined $parent && length $parent;
    croak("Run-directory parent '$parent' is not a directory") unless -d $parent;
    $prefix //= 'pbcf';
    $nonce  //= _gen_nonce();
    croak("Unsafe run-directory prefix '$prefix'") unless $prefix =~ /^[A-Za-z0-9._-]+$/;
    croak("Unsafe run nonce '$nonce'") unless $nonce =~ /^[A-Za-z0-9._-]+$/;
    my $dir = File::Spec->catdir($parent, "${prefix}_${nonce}");
    mkdir($dir) or croak("Cannot create exclusive run directory '$dir': $!");
    return $dir;
}

#-----------------------------------------------------------------------------
# Main control loop — identical for LSF and Slurm.
#-----------------------------------------------------------------------------
sub run_jobs {
    my ($self, $jobs, $on_complete) = @_;
    my $n = scalar @$jobs;
    return $jobs if $n == 0;

    for my $job (@$jobs) {
        $job->{try}     //= 0;
        $job->{status}    = 'pending';
        $job->{wal_min} //= $self->{wal_min};
        $job->{mem_mb}  //= $self->{mem_mb};
        $job->{cpu}     //= $self->{pcpu};
        delete $job->{id};
        delete $job->{submit_failed};
        delete $job->{submit_unknown};
        delete $job->{cancel_unknown};
        delete $job->{unknown_reason};
        delete $job->{cancel_since};
    }

    my ($completed, $perm_fail) = (0, 0);
    my $start = time();
    my $grace = $self->{pint} * 6;  $grace = 120 if $grace < 120;
    my $wave;   # the in-flight submission wave, or undef when submitter is free

    # Any fatal error after jobs have been submitted must clean up (stop the
    # submitter, cancel tracked IDs) before propagating, so we don't leak jobs.
    my $ok = eval {
    while ($completed + $perm_fail < $n) {
        # 1. Recover IDs from the in-flight wave; supervise its submitter; free the
        #    submitter slot when the wave is done.
        if ($wave) {
            $self->_recover_wave_ids($wave);
            # Guard a hung submitter: after a generous budget with no SUBMIT_DONE,
            # terminate it, then classify each complete marker/ID/RC transcript.
            my $budget = 60 + 10 * scalar(@{$wave->{jobs}});
            if (!$wave->{done} && (time() - $wave->{t0}) > $budget) {
                warn "\nWave submitter hung after ${budget}s; terminating and reconciling submissions.\n";
                $self->_kill_submitter($wave->{pid});
                $wave->{pid} = undef;
                # Re-read only complete records after the child is block-reaped.
                # A marked/no-RC command is UNKNOWN; jobs with no marker were
                # never attempted and remain pending for a later wave.
                $self->_recover_wave_ids($wave, interrupted => 1);
                $wave->{done} = 1;
            }
            if ($wave->{done}) {
                # Submission finished: block-reap the submitter (it exits right after
                # SUBMIT_DONE) and drop it from live tracking so cleanup can't later
                # signal a reused PID/pgroup.
                if ($wave->{pid}) {
                    my $pid = $wave->{pid};
                    waitpid($pid, 0);
                    $self->_forget_submitter($pid);
                    $wave->{pid} = undef;
                }
                $self->{_active_wave} = undef;
                $wave = undef;
            }
        }

        # 1b. Abort on an UNKNOWN submission outcome — a job may be running untracked,
        #     so retrying could overlap it. Fail closed rather than guess.
        if (my @unknown = grep { $_->{submit_unknown} || $_->{cancel_unknown} } @$jobs) {
            my @names = _job_names(\@unknown);
            my @why = map { $_->{unknown_reason} // 'submission outcome could not be proven' } @unknown;
            croak("Cluster outcome UNKNOWN for job(s): @names — " . join("; ", @why)
                . ". A job may still be running. Aborting without retry to avoid overlap; "
                . "check the scheduler for stray jobs (prefix '$self->{ppre}') and rerun.");
        }

        # 2. Poll scheduler states for jobs that have an ID. The poll reports
        #    HEALTH separately: on a failed/partial query we must NOT infer that a
        #    job has vanished (that would fail a live job and spawn an overlap).
        my @ids = grep { defined && length }
                  map  { $_->{id} }
                  grep { ($_->{status} // '') =~ /^(?:submitted|cancelling)$/ } @$jobs;
        my ($healthy, $states) = @ids ? $self->_poll_states(\@ids) : (1, {});

        # A failed old attempt owns its shared worker/data paths until a poll made
        # AFTER cancellation proves its scheduler ID terminal or absent.  An
        # active/unknown ID (or an unhealthy query) keeps the job in 'cancelling'.
        my @cancelled;
        for my $job (@$jobs) {
            next unless ($job->{status} // '') eq 'cancelling';
            my $cat = $states->{$job->{id}};
            if ($healthy && (!defined $cat || $cat eq 'done' || $cat eq 'failed')) {
                push @cancelled, $job;
            } elsif ((time() - ($job->{cancel_since} // time())) > $self->{cancel_timeout}) {
                $job->{cancel_unknown} = 1;
                $job->{unknown_reason} = "old scheduler ID $job->{id} could not be confirmed terminal/absent after cancellation";
            }
        }
        if (my @unknown = grep { $_->{cancel_unknown} } @$jobs) {
            my @names = _job_names(\@unknown);
            croak("Cluster outcome UNKNOWN for job(s): @names — cancellation could not be "
                . "confirmed by a healthy scheduler poll. Aborting without retry; check "
                . "the scheduler for possible live jobs (prefix '$self->{ppre}').");
        }
        for my $job (@cancelled) {
            $perm_fail += $self->_finish_failed_attempt($job);
        }

        # 3. Classify each submitted job (sentinel is the authority on success).
        my (@done, @failed);
        for my $job (@$jobs) {
            next unless ($job->{status} // '') eq 'submitted';
            my $verdict = $self->_classify($job, $states, $healthy, $grace);
            if    ($verdict eq 'completed') { $job->{status} = 'completed'; $job->{t2} = time(); $completed++; push @done, $job; }
            elsif ($verdict eq 'failed')    { push @failed, $job; }
            # 'wait' -> leave as submitted
        }

        # 4. Handle failures.  ID-less local submission rejections can be finalized
        #    immediately.  A scheduler-backed attempt enters 'cancelling' and is
        #    finalized only by the post-cancel healthy-poll barrier above.
        for my $job (@failed) {
            my $old_id = $job->{id};
            if (defined $old_id && length $old_id) {
                my $cancel_since = time();
                my $cancel_ok = $self->_cancel([$old_id]);
                warn "Cancellation command for job " . ($job->{name} // '?')
                    . " (ID $old_id) returned nonzero; waiting for scheduler confirmation.\n"
                    unless $cancel_ok;
                $job->{status}       = 'cancelling';
                $job->{cancel_since} = $cancel_since;
            } else {
                $perm_fail += $self->_finish_failed_attempt($job);
            }
        }

        # 5. Post-process completed jobs (callback handles ordering for text mode).
        for my $job (@done) {
            eval { $on_complete->($jobs, $job) if $on_complete; 1 }
                or warn "Post-processing error for " . ($job->{name} // '?') . ": $@\n";
        }

        # 6. Launch the next wave if the submitter is free and work is pending,
        #    capped at --p_jobs concurrent jobs. Slots refill as jobs complete.
        if (!$wave) {
            my @pending = grep { ($_->{status} // '') eq 'pending' } @$jobs;
            my $active  = scalar grep { ($_->{status} // '') =~ /^(?:submitted|cancelling)$/ } @$jobs;
            my $free    = $self->{pjobs} - $active;
            if (@pending && $free > 0) {
                @pending = @pending[0 .. $free - 1] if $free < @pending;
                $wave = $self->_submit_wave(\@pending);
            }
        }

        # 7. Progress + wait.
        my $running = scalar grep { ($_->{status} // '') =~ /^(?:submitted|cancelling)$/ && $_->{id} } @$jobs;
        my $pending = scalar grep { ($_->{status} // '') =~ /^(pending|submitted)$/ && !$_->{id} } @$jobs;
        show_status_line(
            total => $n, done => $completed, running => $running,
            pending => $pending, failed => $perm_fail, start_time => $start,
        );

        last if $completed + $perm_fail >= $n;
        sleep($self->{pint});
    }
    1;
    };
    unless ($ok) {
        my $err = $@;
        $self->cleanup();
        die $err;
    }

    warn "\n$perm_fail of $n jobs permanently failed.\n" if $perm_fail;
    return $jobs;
}

#-----------------------------------------------------------------------------
# Submit a wave: write each worker script + one background batch script, launch it.
#-----------------------------------------------------------------------------
sub _submit_wave {
    my ($self, $pending) = @_;
    my $seq = ++$self->{_wave_seq};
    my $dir = $self->{pdir} // '.';
    my $tag = "$self->{ppre}_$self->{nonce}";     # run-unique so concurrent controllers don't collide
    my $wave_sh  = File::Spec->catfile($dir, "${tag}_wave$seq.sh");
    my $wave_out = File::Spec->catfile($dir, "${tag}_wave$seq.out");
    my $submit_program = $self->_submit_program();
    croak("Unsafe scheduler submit program '$submit_program'")
        unless defined $submit_program && $submit_program =~ /^[A-Za-z0-9._+-]+$/;

    # Control-plane writes are checked and FATAL: a truncated wave (missing
    # SUBMIT_DONE) would hang the run forever, so a write failure aborts closed
    # rather than being mistaken for a per-job retry.
    open(my $wh, '>', $wave_sh) or croak("Cannot write wave script '$wave_sh': $!");
    print $wh "#!/bin/sh\n" or croak("Write to '$wave_sh' failed: $!");

    my @emitted;   # only jobs whose submit command was actually written, in order
    my @local_reject_files;
    my $k = 0;
    for my $job (@$pending) {
        # Attempt-specific sentinel: a LATE sentinel from a prior (cancelled) attempt
        # must never certify this new attempt, so each try writes its own .a<try>.rc.
        my $rcf = "$job->{file}.a$job->{try}.rc";
        unlink($rcf)               if -e $rcf;
        unlink("$job->{file}.out") if -e "$job->{file}.out";
        unlink("$job->{file}.err") if -e "$job->{file}.err";

        # Per-job worker: run the command, record its exit code as the sentinel,
        # and re-exit with it so the scheduler also sees the true status.
        my $script = "$job->{file}.sh";
        open(my $sh, '>', $script) or croak("Cannot write job script '$script': $!");
        print $sh "#!/bin/sh\n$job->{cmd}\nrc=\$?\necho \$rc > " . shq($rcf) . "\nexit \$rc\n"
            or croak("Write to '$script' failed: $!");
        close($sh) or croak("Close '$script' failed: $!");

        # A no-ID scheduler-client completion is UNKNOWN by default: even a
        # nonzero rc can occur after the scheduler accepted the RPC.  The sole
        # generic retryable case is proven separately, before invoking the client:
        # command -v could not resolve it, so no scheduler RPC was possible.
        my $reject_file = File::Spec->catfile(
            $dir, "${tag}_wave${seq}_${k}.local_reject");
        unlink($reject_file) if -e $reject_file;
        # Runtime control writes are FATAL to the wave: `|| exit` halts the script
        # if a marker/RC write to wave.out fails (e.g. disk full). Because MARK is
        # written BEFORE the submit, a failed MARK write stops the wave before job k
        # is submitted — preserving the invariant "no marker in the transcript ==
        # this job was never submitted", which recovery relies on to avoid overlap.
        print $wh "echo " . MARK . " $k || exit 42\n"       or croak("Write to '$wave_sh' failed: $!");
        print $wh "if command -v " . shq($submit_program) . " >/dev/null 2>&1; then\n"
            or croak("Write to '$wave_sh' failed: $!");
        print $wh "  " . $self->_submit_cmd($job, $script), "\n"
            or croak("Write to '$wave_sh' failed: $!");
        print $wh "  pbcf_submit_rc=\$?\nelse\n"
            or croak("Write to '$wave_sh' failed: $!");
        print $wh "  printf '%s\\n' exec_not_found > " . shq($reject_file) . "\n"
            or croak("Write to '$wave_sh' failed: $!");
        print $wh "  pbcf_submit_rc=127\nfi\n"
            or croak("Write to '$wave_sh' failed: $!");
        print $wh "echo " . RC . " $k \$pbcf_submit_rc || exit 42\n"
            or croak("Write to '$wave_sh' failed: $!");

        $job->{status} = 'submitted';
        delete $job->{id};
        delete $job->{submit_failed};
        delete $job->{absent_since};      # fresh attempt: reset terminal-observation timer
        push @emitted, $job;
        push @local_reject_files, $reject_file;
        $k++;
    }
    print $wh "echo " . SUBMIT_DONE . " || exit 42\n" or croak("Write to '$wave_sh' failed: $!");
    close($wh) or croak("Close '$wave_sh' failed: $!");

    # Launch the batch as a SUPERVISED background process in its own process group.
    # Block cleanup signals across fork + publication, and hold the child behind a
    # pipe barrier until its PID/wave are registered.  Thus a signal can never see
    # a live submitter without the wave.out path needed for reconciliation.
    pipe(my $ready_r, my $ready_w) or croak("pipe for wave submitter failed: $!");
    pipe(my $go_r,    my $go_w)    or croak("pipe for wave submitter failed: $!");
    my $block = POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP);
    my $oldmask = POSIX::SigSet->new();
    defined sigprocmask(SIG_BLOCK, $block, $oldmask)
        or croak("Cannot block cleanup signals around wave launch: $!");
    my $pid = fork();
    unless (defined $pid) {
        my $err = $!;
        sigprocmask(SIG_SETMASK, $oldmask);
        close $_ for ($ready_r, $ready_w, $go_r, $go_w);
        croak("fork for wave submitter failed: $err");
    }
    if ($pid == 0) {
        close $ready_r;
        close $go_w;
        # Do not run the parent CLI's cleanup closure in this fork.  Signals stay
        # blocked until publication, then take their normal default action here.
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = 'DEFAULT';
        setpgrp(0, 0);
        syswrite($ready_w, "R") == 1 or POSIX::_exit(127);
        close $ready_w;
        my $go = '';
        sysread($go_r, $go, 1) == 1 or POSIX::_exit(127);
        close $go_r;
        sigprocmask(SIG_SETMASK, $oldmask);
        open(STDOUT, '>', $wave_out) or POSIX::_exit(127);
        open(STDERR, '>&', \*STDOUT)  or POSIX::_exit(127);
        exec('/bin/sh', $wave_sh) or POSIX::_exit(127);
    }
    close $ready_w;
    close $go_r;
    my $ready = '';
    unless (sysread($ready_r, $ready, 1) == 1) {
        my $err = $!;
        kill('KILL', $pid);
        waitpid($pid, 0);
        sigprocmask(SIG_SETMASK, $oldmask);
        croak("Wave submitter failed before registration: $err");
    }
    close $ready_r;
    my $wave = { seq => $seq, out => $wave_out, jobs => \@emitted,
                 local_reject => \@local_reject_files,
                 done => 0, t0 => time(), pid => $pid };
    push @{$self->{_submitter_pids}}, $pid;
    $self->{_active_wave} = $wave;
    unless (syswrite($go_w, "G") == 1) {
        my $err = $!;
        close $go_w;
        $self->_kill_submitter($pid);
        sigprocmask(SIG_SETMASK, $oldmask);
        croak("Cannot release registered wave submitter: $err");
    }
    close $go_w;
    sigprocmask(SIG_SETMASK, $oldmask);

    # jobs => @emitted (NOT the original @$pending): recovery maps marker k to the
    # k-th EMITTED job, so a skipped/failed write can never misassociate IDs.
    return $wave;
}

# Terminate a background wave submitter (its whole process group) with TERM then KILL.
sub _kill_submitter {
    my ($self, $pid) = @_;
    return unless $pid;
    my $r = waitpid($pid, WNOHANG);
    if ($r == $pid || $r == -1) {
        $self->_forget_submitter($pid);
        return 1;
    }
    kill('TERM', -$pid);
    for (1 .. 10) {
        $r = waitpid($pid, WNOHANG);
        if ($r == $pid || $r == -1) {
            $self->_forget_submitter($pid);
            return 1;               # TERM succeeded: never signal this PID again
        }
        sleep(0.1);
    }
    kill('KILL', -$pid);
    do { $r = waitpid($pid, 0); } while ($r == -1 && $!{EINTR});
    $self->_forget_submitter($pid);
    return 1;
}

sub _forget_submitter {
    my ($self, $pid) = @_;
    @{$self->{_submitter_pids}} = grep { $_ != $pid } @{$self->{_submitter_pids} || []};
    if ($self->{_active_wave} && ($self->{_active_wave}{pid} // 0) == $pid) {
        $self->{_active_wave} = undef;
    }
}

# Run one scheduler poll/cancel client under an owned process group and a hard
# deadline.  Output goes to a file rather than a pipe so a verbose scheduler
# response cannot fill a pipe and deadlock the supervising parent.  Returns the
# complete merged output, raw wait status, a timeout flag, and an output-I/O
# health flag.
sub _run_scheduler_client {
    my ($self, $argv, $timeout) = @_;
    $timeout = $self->{client_timeout} unless defined $timeout;
    return ('', -1, 1, 0) unless $timeout && $timeout > 0;
    return ('', -1, 0, 0) unless ref($argv) eq 'ARRAY' && @$argv;

    my ($out_fh, $out_file);
    my $tmp_ok = eval {
        ($out_fh, $out_file) = tempfile('pbcf_sched_XXXXXX', TMPDIR => 1, UNLINK => 0);
        1;
    };
    return ('', -1, 0, 0) unless $tmp_ok && defined $out_fh && defined $out_file;

    pipe(my $ready_r, my $ready_w) or do {
        close $out_fh;
        unlink $out_file;
        return ('', -1, 0, 0);
    };
    my $block = POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP);
    my $oldmask = POSIX::SigSet->new();
    unless (defined sigprocmask(SIG_BLOCK, $block, $oldmask)) {
        close $_ for ($ready_r, $ready_w, $out_fh);
        unlink $out_file;
        return ('', -1, 0, 0);
    }

    my $pid = fork();
    unless (defined $pid) {
        sigprocmask(SIG_SETMASK, $oldmask);
        close $_ for ($ready_r, $ready_w, $out_fh);
        unlink $out_file;
        return ('', -1, 0, 0);
    }
    if ($pid == 0) {
        close $ready_r;
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = 'DEFAULT';
        setpgrp(0, 0) or POSIX::_exit(127);
        syswrite($ready_w, "R") == 1 or POSIX::_exit(127);
        close $ready_w;
        sigprocmask(SIG_SETMASK, $oldmask);
        open(STDOUT, '>&', $out_fh) or POSIX::_exit(127);
        open(STDERR, '>&', $out_fh) or POSIX::_exit(127);
        close $out_fh;
        if (!exec { $argv->[0] } @$argv) {
            POSIX::_exit(127);
        }
    }

    close $ready_w;
    my $ready = '';
    my $published = sysread($ready_r, $ready, 1) == 1;
    close $ready_r;
    unless ($published) {
        kill('KILL', $pid);
        my $r;
        do { $r = waitpid($pid, 0) } while ($r == -1 && $!{EINTR});
        sigprocmask(SIG_SETMASK, $oldmask);
        my ($out, $output_ok) = _read_client_output($out_fh, $out_file);
        return ($out, -1, 0, $output_ok);
    }
    $self->{_client_pids}{$pid} = 1;
    sigprocmask(SIG_SETMASK, $oldmask);

    my $deadline = time() + $timeout;
    my $status;
    while (1) {
        my $r = waitpid($pid, WNOHANG);
        if ($r == $pid) {
            $status = $?;
            delete $self->{_client_pids}{$pid};
            last;
        }
        if ($r == -1 && !$!{EINTR}) {
            $status = -1;
            delete $self->{_client_pids}{$pid};
            last;
        }
        last if time() >= $deadline;
        sleep(0.05);
    }

    my $timed_out = !defined $status;
    if ($timed_out) {
        $self->_stop_scheduler_client($pid);
        $status = -1;
    }
    my ($out, $output_ok) = _read_client_output($out_fh, $out_file);
    return ($out, $status, $timed_out, $output_ok);
}

# TERM the whole client process group, then KILL it and block-reap the leader.
# KILL is sent even if the leader exited after TERM so descendants cannot remain.
sub _stop_scheduler_client {
    my ($self, $pid) = @_;
    return unless $pid;
    my $reaped = 0;
    kill('TERM', -$pid);
    for (1 .. 5) {
        my $r = waitpid($pid, WNOHANG);
        if ($r == $pid || ($r == -1 && !$!{EINTR})) { $reaped = 1; last; }
        sleep(0.05);
    }
    kill('KILL', -$pid);
    unless ($reaped) {
        my $r;
        do { $r = waitpid($pid, 0) } while ($r == -1 && $!{EINTR});
    }
    delete $self->{_client_pids}{$pid};
    return 1;
}

sub _read_client_output {
    my ($fh, $path) = @_;
    my $out = '';
    my $ok = defined($fh) && seek($fh, 0, 0);
    if ($ok) {
        while (1) {
            my $n = sysread($fh, my $buf, 64 * 1024);
            if (!defined $n) {
                next if $!{EINTR};
                $ok = 0;
                last;
            }
            last if $n == 0;
            $out .= $buf;
        }
    }
    $ok = 0 unless defined($fh) && close($fh);
    unlink $path if defined $path && -e $path;
    return ($out, $ok ? 1 : 0);
}

#-----------------------------------------------------------------------------
# Recover job IDs from a wave's output file (by marker). Detect rejected submits.
#-----------------------------------------------------------------------------
sub _recover_wave_ids {
    my ($self, $wave, %opts) = @_;
    return unless $wave;
    my $fh;
    unless (open($fh, '<', $wave->{out})) {
        # On interrupted recovery the transcript can't even be opened: we cannot
        # tell which emitted jobs were submitted. Fail closed -> UNKNOWN, never leave
        # them as id-less 'submitted' (which would livelock the monitor or, in
        # cleanup, miss a possibly-live untracked job).
        if ($opts{interrupted}) {
            for my $job (@{$wave->{jobs} || []}) {
                next if $job->{id} || ($job->{status} // '') ne 'submitted';
                $job->{submit_unknown} = 1;
                $job->{unknown_reason} = "wave transcript '$wave->{out}' could not be opened during interrupted recovery: $!";
            }
        }
        return;   # not created yet / transient (non-interrupted) -> retry next cycle
    }
    my %seg;            # marker idx -> accumulated submission-output text
    my %rc;             # marker idx -> submit command exit status
    my %marked;         # marker idx -> submit command was actually started
    my $cur = -1;
    my $done = 0;
    my $mark = MARK;
    my $rctok = RC;
    my $sdone = SUBMIT_DONE;
    while (my $line = <$fh>) {
        # <$fh> returns an unterminated final fragment while the child is still
        # writing.  Never feed that fragment to an ID parser; a visible "12" may
        # later become the real Slurm ID "12345\n".
        next unless $line =~ /\n\z/;
        # EXACT, COMPLETE (newline-terminated) control records only — a submit line
        # that merely contains a token, or a partial last line still being written,
        # must not be recognized.
        if    ($line =~ /^\Q$mark\E[ \t]+(\d+)[ \t]*\r?\n$/)         { $cur = $1; $marked{$1} = 1; }
        elsif ($line =~ /^\Q$rctok\E[ \t]+(\d+)[ \t]+(\d+)[ \t]*\r?\n$/) { $rc{$1} = $2; $cur = -1; }
        elsif ($line =~ /^\Q$sdone\E[ \t]*\r?\n$/)                   { $done = 1; $cur = -1; }
        elsif ($cur >= 0)                                           { $seg{$cur} .= $line; }
    }
    # Was the transcript read cleanly? A mid-file READ error (or a failed close)
    # can make markers appear missing; on interrupted recovery that must NOT be
    # read as "never attempted", which would requeue a possibly-submitted job.
    my $read_ok = !$fh->error;
    $read_ok = 0 unless close($fh);
    $wave->{marked} = { %marked };

    my $by_idx = $wave->{jobs};
    for my $k (0 .. $#$by_idx) {
        my $job = $by_idx->[$k];
        next if $job->{id};                       # already recovered
        next unless ($job->{status} // '') eq 'submitted';
        if (defined $seg{$k} && (my $id = $self->_extract_id($seg{$k}))) {
            $job->{id} = $id;                      # accepted
            delete $job->{submit_failed};
            delete $job->{submit_unknown};
            delete $job->{unknown_reason};
            push @{$self->{submitted_ids}}, $id;
        } elsif (defined $rc{$k}) {
            # The submit command finished but no ID was parsed.  This is UNKNOWN
            # unless a separate local sidecar proves the scheduler client was not
            # even resolvable, so no scheduler RPC could have occurred.
            my $proof = _read_local_reject_proof(
                $wave->{local_reject} && $wave->{local_reject}[$k]);
            if ($self->_definitive_submit_rejection($rc{$k}, $proof)) {
                $job->{submit_failed} = 1;
            } else {
                $job->{submit_unknown} = 1;
                $job->{unknown_reason} = "marked submit had no complete job ID and no proven pre-scheduler rejection (rc=$rc{$k})";
            }
        } elsif ($marked{$k} && ($done || $opts{interrupted})) {
            # The submit command started, but interruption left neither a complete
            # ID nor an ordinary RC: scheduler acceptance is unknowable.
            $job->{submit_unknown} = 1;
            $job->{unknown_reason} = "marked submit ended without a complete job ID or return code";
        } elsif ($opts{interrupted} && $read_ok) {
            # No marker AND a clean transcript read: the sequential wave never
            # attempted this later job, so it is safe to requeue.
            $job->{status} = 'pending';
            delete $job->{submit_failed};
            delete $job->{absent_since};
        } elsif ($opts{interrupted}) {
            # Interrupted, no marker, but the transcript could not be fully read:
            # a missing marker might just be unread, so this job's fate is
            # unknowable -> fail closed rather than risk requeueing a live job.
            $job->{submit_unknown} = 1;
            $job->{unknown_reason} = "wave transcript could not be fully read during interrupted recovery; job status unknowable";
        } elsif ($done) {
            # A supposedly complete wave missing this job's marker is corrupt.
            $job->{submit_unknown} = 1;
            $job->{unknown_reason} = "completed submission wave omitted the job marker";
        }
        # else: no ID/RC yet and submission still running -> wait for next cycle.
    }
    $wave->{done} = $done;
}

# Only a separately recorded pre-exec failure is a generic definitive rejection.
# Scheduler-client output/rc is never proof by itself: a wrapper may return any
# nonzero code after the scheduler accepted the job but before the ID reached us.
sub _definitive_submit_rejection {
    my ($self, $rc, $proof) = @_;
    return defined($rc) && $rc == 127
        && defined($proof) && $proof eq 'exec_not_found';
}

sub _read_local_reject_proof {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open(my $fh, '<', $path) or return undef;
    my $proof = <$fh>;
    close $fh;
    return undef unless defined $proof;
    $proof =~ s/\r?\n\z//;
    return $proof eq 'exec_not_found' ? $proof : undef;
}

#-----------------------------------------------------------------------------
# Classify one submitted job. Success MUST be proven by an exit-0 sentinel.
#-----------------------------------------------------------------------------
sub _classify {
    my ($self, $job, $states, $healthy, $grace) = @_;

    return 'failed' if $job->{submit_failed};     # rejected submission
    return 'wait'   unless $job->{id};            # ID still pending

    # Sentinel is authoritative: an exit code, if present, decides outright.
    my $rc = read_exit_code("$job->{file}.a$job->{try}.rc");
    return ($rc == 0 ? 'completed' : 'failed') if defined $rc;

    # No sentinel yet — consult the scheduler state.
    my $cat = $states->{$job->{id}};              # 'active' | 'failed' | 'done' | undef(gone)
    if (defined $cat && $cat eq 'active') { delete $job->{absent_since}; return 'wait'; }
    return 'failed' if defined $cat && $cat eq 'failed';

    # 'done'/gone with no sentinel. NEVER conclude "gone -> failed" from an
    # UNHEALTHY poll (a transient scheduler-query failure returns everyone as
    # absent) — that would fail a live job and create an overlapping retry.
    return 'wait' unless $healthy;

    # Ended (or truly absent) without an exit code. Measure grace from the FIRST
    # terminal/absent observation, so a long job isn't failed the instant it ends
    # while its sentinel/accounting is still propagating over the shared FS.
    $job->{absent_since} //= time();
    return 'failed' if (time() - $job->{absent_since}) > $grace;
    return 'wait';
}

# Finalize one failed attempt only after either (a) it never received a scheduler
# ID due to a definitive local rejection, or (b) its old ID crossed the
# post-cancel healthy-poll barrier.  Returns 1 iff the job became permanent-fail.
sub _finish_failed_attempt {
    my ($self, $job) = @_;
    my $old_id = delete $job->{id};
    if (defined $old_id && length $old_id) {
        @{$self->{submitted_ids}} = grep { $_ ne $old_id } @{$self->{submitted_ids}};
    }
    $job->{try}++;
    delete $job->{submit_failed};
    delete $job->{absent_since};
    delete $job->{cancel_since};
    if ($job->{try} < $self->{ptry}) {
        $self->_escalate($job);
        $job->{status} = 'pending';
        warn sprintf("Job %s failed (attempt %d/%d), retrying with %s wall, %s mem\n",
            $job->{name} // '?', $job->{try}, $self->{ptry},
            $self->_fmt_wal($job->{wal_min}), $self->_fmt_mem($job->{mem_mb}));
        return 0;
    }
    $job->{status} = 'perm_fail';
    warn sprintf("Job %s failed after %d attempts, giving up.\n",
        $job->{name} // '?', $self->{ptry});
    return 1;
}

#-----------------------------------------------------------------------------
# Escalate resources for a retry (percentage bumps; canonical minutes / MB).
#-----------------------------------------------------------------------------
sub _escalate {
    my ($self, $job) = @_;
    # Cap escalated values at the same bounds the parsers enforce, so repeated
    # retries can't overflow into an invalid scheduler argument.
    my $wal = ceil($job->{wal_min} * (1 + $self->{pwal_inc} / 100));
    my $mem = ceil($job->{mem_mb}  * (1 + $self->{pmem_inc} / 100));
    $job->{wal_min} = $wal < MAX_WAL_MIN ? $wal : MAX_WAL_MIN;
    $job->{mem_mb}  = $mem < MAX_MEM_MB  ? $mem : MAX_MEM_MB;
}

sub cleanup {
    my ($self) = @_;
    if ($self->{_cleaning}) {
        $self->_stop_scheduler_client($_) for keys %{$self->{_client_pids} || {}};
        return;
    }
    $self->{_cleaning} = 1;
    my $wave = $self->{_active_wave};
    # A signal may arrive while the main loop is inside a scheduler poll/cancel.
    # Stop that supervised client first; cleanup's own cancellation clients are
    # independently deadline-bounded below.
    $self->_stop_scheduler_client($_) for keys %{$self->{_client_pids} || {}};
    # Stop any background submitter(s) FIRST so they cannot submit more jobs after
    # (or during) cancellation.
    for my $pid (@{$self->{_submitter_pids} || []}) {   # copy: _kill removes live PIDs
        $self->_kill_submitter($pid);
    }
    # Reconcile the in-flight wave: an ID emitted after the last monitor read but
    # before the submitter was stopped is in wave.out but not yet in submitted_ids.
    # Re-read it so those jobs get cancelled too.
    eval { $self->_recover_wave_ids($wave, interrupted => 1) if $wave; 1 }
        or warn "WARNING: could not reconcile final submission output during cleanup: $@";
    if ($wave) {
        my @unresolved = grep { $_->{submit_unknown} } @{$wave->{jobs} || []};
        if (@unresolved) {
            my @names = _job_names(\@unresolved);
            warn "WARNING: submission outcome UNKNOWN for marked job(s) @names; "
                . "a scheduler job may be running untracked (possible stray).\n";
        }
    }
    my %seen;
    my @ids = grep { defined && length && !$seen{$_}++ } @{$self->{submitted_ids}};
    if (@ids) {
        warn "Cancelling " . scalar(@ids) . " submitted job(s)...\n";
        my $cancel_ok = $self->_cancel(\@ids);
        warn "WARNING: scheduler cancellation command timed out or returned nonzero; "
            . "check for possible live jobs (prefix '$self->{ppre}').\n"
            unless $cancel_ok;
    }
    $self->{submitted_ids}   = [];
    $self->{_submitter_pids} = [];
    $self->{_active_wave}    = undef;
    $self->{_cleaning}       = 0;
    return;
}

#=============================================================================
# Canonical resource parsers (raw string -> minutes / MB).
#=============================================================================
sub _parse_wal_min {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/\s+//g;
    my $sec;
    if ($s =~ /^(\d+):(\d+):(\d+)$/) { return undef if $2 > 59 || $3 > 59; $sec = $1*3600 + $2*60 + $3; }
    elsif ($s =~ /^(\d+):(\d+)$/)    { return undef if $2 > 59; $sec = $1*3600 + $2*60; }   # H:MM
    elsif ($s =~ /^(?:(\d+)(?:h|hr))?(?:(\d+)(?:m|min))?(?:(\d+)(?:s|sec))?$/i
           && (defined $1 || defined $2 || defined $3)) {
        $sec = ($1 // 0) * 3600 + ($2 // 0) * 60 + ($3 // 0);
    }
    else { return undef; }
    return undef if $sec <= 0 || $sec > MAX_WAL_MIN * 60;   # reject nonpositive / absurd (>1yr)
    return int(($sec + 59) / 60);   # round up to whole minutes
}

sub _parse_mem_mb {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/\s+//g;
    return undef unless $s =~ /^(\d+(?:\.\d+)?)([kmgt])?b?$/i;
    my ($val, $unit) = ($1, lc($2 // 'm'));
    my %to_mb = (k => 1/1024, m => 1, g => 1024, t => 1024*1024);
    my $mb = ceil($val * $to_mb{$unit});
    return undef if $mb <= 0 || $mb > MAX_MEM_MB;   # reject nonpositive / absurd (>100TB)
    return $mb;
}

# Cancel a set of IDs in bounded batches, sharing one deadline across the whole
# set.  Subclass _cancel() supplies only the client program and batch size.
# Returns 1 iff every batch completed cleanly (exit 0) within the deadline; any
# timeout, signal, or nonzero exit -> 0 so the caller warns about possible strays.
sub _cancel_batched {
    my ($self, $program, $batch_size, $ids) = @_;
    my @ids = @$ids;
    my $ok = 1;
    my $deadline = time() + $self->{client_timeout};
    while (my @batch = splice(@ids, 0, $batch_size)) {
        my $remaining = $deadline - time();
        if ($remaining <= 0) { $ok = 0; last; }
        my (undef, $st, $timed_out) = $self->_run_scheduler_client(
            [$program, @batch], $remaining);
        $ok = 0 if $timed_out || $st == -1 || ($st & 127) || ($st >> 8) != 0;
    }
    return $ok;
}

# Shared poll-response health test for subclass _poll_states.  A scheduler query
# is HEALTHY only when its output was fully captured (output_ok), it did not time
# out or die by signal, and EITHER it exited 0 with complete output, OR it exited
# nonzero but its complete output still accounted for every requested ID (a parsed
# row or an explicit per-ID absence).  Fail-closed: an ambiguous or partial query
# is never read as "the jobs vanished", so a transient outage can't fail live jobs.
sub _response_healthy {
    my ($self, $st, $timed_out, $output_ok, $complete, $seen, $ids) = @_;
    return 0 if !$output_ok || $timed_out || $st == -1 || ($st & 127);
    return 0 unless $complete;
    return 1 if ($st >> 8) == 0;
    return !(grep { !$seen->{"$_"} } @$ids);
}

#=============================================================================
# Scheduler-specific primitives — subclasses MUST override these.
#=============================================================================
sub _submit_cmd  { croak "abstract: _submit_cmd" }
sub _submit_program { croak "abstract: _submit_program" }
sub _extract_id  { croak "abstract: _extract_id" }
sub _poll_states { croak "abstract: _poll_states" }
sub _cancel      { croak "abstract: _cancel" }
sub _fmt_wal     { croak "abstract: _fmt_wal" }
sub _fmt_mem     { croak "abstract: _fmt_mem" }

1;
