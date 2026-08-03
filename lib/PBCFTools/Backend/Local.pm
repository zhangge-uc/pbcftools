package PBCFTools::Backend::Local;

use strict;
use warnings;
use Carp qw(croak);
use Parallel::ForkManager;
use Time::HiRes qw(time);
use PBCFTools::Helpers;

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        pjobs     => $opts{pjobs},
        nchunks   => $opts{nchunks},
        verbose   => $opts{verbose} // 0,
        fail_stop => $opts{fail_stop} // 1,  # default: stop on first failure
        pids      => {},
        pm        => undef,
        _abort    => 0,
    }, $class;

    # Auto-detect CPU count if pjobs not specified (portable: Linux/macOS/BSD).
    # Default to 80% of the logical core count, rounded up: measured speedup keeps
    # improving well past half the cores, while leaving a little headroom matters on
    # a shared machine. POSIX::ceil is avoided so this stays dependency-free; the
    # guard keeps single-core machines at 1 rather than 0.
    #
    # Then cap at the number of chunks. Workers beyond that have nothing to run --
    # 77 workers for 69 chunks left 8 idle and reported a concurrency the run could
    # never reach, which is misleading in the summary and in the timing table.
    unless ($self->{pjobs} && $self->{pjobs} > 0) {
        my $n    = detect_ncpu();
        my $want = int($n * 0.8);
        $want++ if $want < $n * 0.8;          # ceiling
        $want = 1 if $want < 1;
        my $capped = 0;
        if ($self->{nchunks} && $self->{nchunks} > 0 && $want > $self->{nchunks}) {
            $want   = $self->{nchunks};
            $capped = 1;
        }
        $self->{pjobs} = $want;
        # Reported as part of the one-line run summary rather than on its own line;
        # the caller reads this through pjobs_note().
        $self->{pjobs_note} = $capped
            ? "auto, one per chunk"
            : sprintf("auto, 80%% of %d cores", $n);
    }

    return $self;
}

sub pjobs { return $_[0]->{pjobs} }

# How pjobs was arrived at, for the run summary; empty when the user set it.
sub pjobs_note { return $_[0]->{pjobs_note} }

sub run_jobs {
    my ($self, $jobs, $on_complete) = @_;
    my $n = scalar @$jobs;
    return $jobs if $n == 0;

    my $pjobs = $self->{pjobs};
    my $pm = Parallel::ForkManager->new($pjobs);
    $self->{pm} = $pm;
    $self->{_abort} = 0;

    my $completed = 0;
    my $failed    = 0;
    my $start_time = time();

    $pm->run_on_finish(sub {
        my ($pid, $exit_code, $ident, $exit_signal, $core_dump, $child) = @_;
        delete $self->{pids}{$pid};

        # Job identity comes from the ident given to start($idx) — it is present
        # even when the worker PROCESS died before reaching finish() (e.g. OOM),
        # unlike a finish() payload. Fail closed if it is somehow missing rather
        # than defaulting to job 0 and masking a real failure.
        my $idx = $ident;
        if (!defined $idx) {
            warn "\nLocal backend: a worker finished with no job identity — treating as failure.\n";
            $failed++;
            $self->{_abort} = 1 if $self->{fail_stop};
            return;
        }
        my $job = $jobs->[$idx];
        $job->{t2} = time();

        # Success requires a CLEAN exit: exit 0 AND no terminating signal. A
        # signal-killed worker never called finish(), so PFM reports exit_code 0
        # with exit_signal set — that is a failure, not a silent completion.
        if ($exit_code == 0 && !$exit_signal) {
            $job->{status} = 'completed';
            $completed++;
        } else {
            $job->{status} = 'failed';
            $failed++;
            my $err_msg = _read_err_file("$job->{file}.err");
            show_message(sprintf("\nJob '%s' FAILED (exit %d)%s\n",
                $job->{name}, $exit_code,
                $err_msg ? ": $err_msg" : ""));

            # Fail-stop: signal the dispatch loop to stop
            if ($self->{fail_stop}) {
                $self->{_abort} = 1;
            }
        }

        # Post-processing callback
        eval { $on_complete->($jobs, $job) if $on_complete; };
        warn "Post-processing error for $job->{name}: $@\n" if $@;

        # Status line
        my $running = scalar keys %{$self->{pids}};
        my $pending = $n - $completed - $failed - $running;
        show_status_line(
            total      => $n,
            done       => $completed,
            running    => $running,
            pending    => $pending,
            failed     => $failed,
            start_time => $start_time,
        );
    });

    # Dispatch jobs
    my $i = 0;
    for my $job (@$jobs) {
        # Fail-stop: if a job has failed, stop dispatching new jobs
        if ($self->{_abort}) {
            show_message("\nStopping dispatch — waiting for running jobs to finish...\n");
            last;
        }

        my $idx = $i;
        my $pid = $pm->start($idx);   # pass idx as the authoritative ident
        if ($pid) {
            # Parent
            $self->{pids}{$pid} = 1;
            $job->{status} = 'running';
            $job->{t1} = time();
            $i++;
            next;
        }

        # Child process: run in its own process group so cleanup can signal the
        # whole tree (this perl worker + the sh + bcftools it spawns), not just the
        # worker. Decode the FULL wait status via wait_status_exit so a signal-
        # killed shell (($? >> 8)==0) is a failure, not a silently-assembled chunk.
        # Reset INT/TERM/HUP to DEFAULT so a cleanup signal to the group just kills
        # this worker (default action) instead of re-running the parent CLI's
        # cleanup closure with a forked copy of ForkManager state.
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = 'DEFAULT';
        setpgrp(0, 0);
        my $cmd = $job->{cmd};
        my $err_file = "$job->{file}.err";
        system($cmd . " 2>" . shq($err_file));
        $pm->finish(wait_status_exit($?), { idx => $idx });
    }

    $pm->wait_all_children();
    $self->{pm} = undef;

    if ($failed > 0) {
        show_message(sprintf("\n%d of %d jobs failed.\n", $failed, $n));
        # Under fail-stop, dispatch was halted after the first failure, so some
        # jobs may never have run. The caller inspects per-job status and fails
        # closed (no partial output). We only report here.
        if ($self->{fail_stop}) {
            show_message("Dispatch halted on first failure (fail-stop). "
                . "No output will be assembled.\n");
        }
    }

    return $jobs;
}

sub cleanup {
    my ($self) = @_;
    warn "Terminating local child processes...\n";

    # Signal each worker's whole PROCESS GROUP (the perl worker + the sh and
    # bcftools it spawned), plus the worker pid directly to cover the brief window
    # before the child has called setpgrp(). `-$pid` can only ever target the
    # worker's own group (pgid == its pid), never the parent's, so it is safe.
    for my $pid (keys %{$self->{pids}}) {
        kill('TERM', -$pid);
        kill('TERM', $pid);
    }

    # Brief grace period, then force kill the group (catches descendants even if
    # the worker leader already exited) and the pid.
    sleep(2);
    for my $pid (keys %{$self->{pids}}) {
        kill('KILL', -$pid);
        kill('KILL', $pid);
    }

    # Reap
    if ($self->{pm}) {
        $self->{pm}->wait_all_children();
    }
}

sub _read_err_file {
    my ($path) = @_;
    return '' unless defined $path && -e $path && -s $path;
    open my $fh, '<', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    chomp $s if defined $s;
    return defined $s ? $s : '';
}

1;
