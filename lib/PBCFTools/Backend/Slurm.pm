package PBCFTools::Backend::Slurm;

# Slurm profile for the shared async cluster controller (see Backend/Cluster.pm).
# Only scheduler-specific primitives live here; the control loop is inherited.

use strict;
use warnings;
use PBCFTools::Backend::Cluster;
use parent -norequire, 'PBCFTools::Backend::Cluster';
use PBCFTools::Helpers;
use Time::HiRes qw(time);

# Resource formatting: sbatch --time HH:MM:SS, --mem <MB>.
sub _fmt_wal { my ($self, $min) = @_; return sprintf("%02d:%02d:00", int($min / 60), $min % 60); }
sub _fmt_mem { my ($self, $mb)  = @_; return "${mb}M"; }
sub _submit_program { return 'sbatch'; }

# Build the sbatch command that submits $script (a per-chunk worker with a
# sentinel). --parsable makes sbatch echo just the numeric job ID.
sub _submit_cmd {
    my ($self, $job, $script) = @_;
    my $sb = "sbatch --parsable"
        . " --job-name=" . shq($job->{name} // $self->{ppre})
        . " --time="     . $self->_fmt_wal($job->{wal_min})
        . " --mem="      . $self->_fmt_mem($job->{mem_mb})
        . " --cpus-per-task=" . $job->{cpu}
        . " --output="   . shq("$job->{file}.out")
        . " --error="    . shq("$job->{file}.err");
    $sb .= " --partition=" . shq($self->{pqueue})   if $self->{pqueue};
    $sb .= " --account="   . shq($self->{paccount}) if $self->{paccount};
    $sb .= " " . shq($script);
    return $sb;
}

# Extract the job ID from one job's sbatch --parsable output. Require an EXACT
# parsable line ("JOBID" or "JOBID;CLUSTER") — a site wrapper line like
# "123 credits remaining" must NOT be adopted as a job ID.
sub _extract_id {
    my ($self, $text) = @_;
    return ($text =~ /^(\d+)(?:;[^\r\n;]+)?[ \t]*\r?\n/m) ? $1 : undef;
}

# Poll states for a set of IDs. squeue lists active jobs; sacct has terminal
# states for finished ones. Returns ($healthy, { id => 'active'|'done'|'failed' }).
# $healthy is 0 when squeue itself errors (controller unreachable) so the
# controller does not read the empty result as "all jobs vanished". A parsed
# state is mapped explicitly: requeue/hold/suspend are 'active' (Slurm re-runs
# them; we must not start our own retry); truly terminal states are done/failed;
# unrecognized states are 'unknown' (grace-bounded for ordinary classification,
# but never accepted as cancellation confirmation).
sub _poll_states {
    my ($self, $ids) = @_;
    my %cat;
    my $idlist = join(",", @$ids);
    return (1, \%cat) unless $idlist =~ /\S/;

    # SE (SPECIAL_EXIT) is a specially-held requeued job and RV (REVOKED) is a
    # federated sibling that another cluster may be running — both are AMBIGUOUS,
    # not terminal failures, so treat them as active (Slurm's own lifecycle
    # resolves them; the sentinel is the final arbiter). Unknown codes are retained
    # as 'unknown' so the cancellation barrier cannot confuse them with absence.
    my %sq_active = map { $_ => 1 } qw(PD R CG CF S RD RF RH RQ RS SO SI ST SE RV);
    my %sq_fail   = map { $_ => 1 } qw(F TO OOM CA NF BF DL PR);
    my %sa_done   = map { $_ => 1 } qw(COMPLETED);
    my %sa_active = map { $_ => 1 } qw(REQUEUED REQUEUE_HOLD REQUEUE_FED RESIZING SUSPENDED PENDING RUNNING SPECIAL_EXIT REVOKED);
    my %sa_fail   = map { $_ => 1 } qw(FAILED TIMEOUT OUT_OF_MEMORY CANCELLED NODE_FAIL BOOT_FAIL DEADLINE PREEMPTED LAUNCH_FAILED);

    my %requested = map { ($_ => 1) } @$ids;
    my $deadline = time() + $self->{client_timeout};

    # squeue: non-terminal jobs. A nonzero response is usable only when every
    # requested ID is explicitly represented by a parsed row or per-ID invalid/
    # not-found line; an unqualified "Invalid job id specified" proves nothing.
    my ($sq, $sq_st, $sq_timeout, $sq_output_ok) = $self->_run_scheduler_client(
        ['squeue', "--jobs=$idlist", '--noheader', '--format=%i %t'],
        $deadline - time());
    my %sq_seen;
    my $sq_complete = 1;
    for my $line (split /\n/, $sq) {
        next unless $line =~ /\S/;
        my $missing = _explicit_missing_id($line);
        if (defined($missing) && $requested{$missing}) {
            $cat{$missing} = 'done';
            $sq_seen{$missing} = 1;
            next;
        }
        unless ($line =~ /^\s*(\d+)\s+(\S+)\s*$/ && $requested{$1}) {
            $sq_complete = 0;
            next;
        }
        my ($id, $t) = ($1, $2);
        $sq_seen{$id} = 1;
        if    ($t eq 'CD')      { $cat{$id} = 'done'; }
        elsif ($sq_fail{$t})    { $cat{$id} = 'failed'; }
        elsif ($sq_active{$t})  { $cat{$id} = 'active'; }
        else                         { $cat{$id} = 'unknown'; }
    }
    my $sq_healthy = $self->_response_healthy(
        $sq_st, $sq_timeout, $sq_output_ok, $sq_complete, \%sq_seen, $ids);
    return (0, \%cat) unless $sq_healthy;

    # sacct: terminal states for jobs no longer in squeue. sacct may legitimately
    # be disabled with an exit-0 empty response. Any failed/timed-out sacct is
    # unhealthy: otherwise an omitted finished job would look safely absent.
    my $remaining = $deadline - time();
    return (0, \%cat) unless $remaining > 0;
    my ($sa, $sa_st, $sa_timeout, $sa_output_ok) = $self->_run_scheduler_client(
        ['sacct', "--jobs=$idlist", '--noheader', '--parsable2', '--format=JobID,State'],
        $remaining);
    my %sa_seen;
    my $sa_complete = 1;
    for my $line (split /\n/, $sa) {
        next unless $line =~ /\S/;
        my $missing = _explicit_missing_id($line);
        if (defined($missing) && $requested{$missing}) {
            $cat{$missing} = 'done' unless exists $cat{$missing};
            $sa_seen{$missing} = 1;
            next;
        }
        my @f = split /\|/, $line;
        unless (@f >= 2 && $f[0] =~ /^\s*(\d+)(?:\.\S+)?\s*$/ && $requested{$1}) {
            $sa_complete = 0;
            next;
        }
        my $id = $1;
        next if $f[0] =~ /\./;                 # recognized .batch/.extern sub-step
        $sa_seen{$id} = 1;
        next if exists $cat{$id};              # squeue is authoritative for active
        my ($state) = split /\s+/, $f[1];       # strip "CANCELLED by ..."
        if    ($sa_done{$state})   { $cat{$id} = 'done'; }
        elsif ($sa_fail{$state})   { $cat{$id} = 'failed'; }
        elsif ($sa_active{$state}) { $cat{$id} = 'active'; }
        else                         { $cat{$id} = 'unknown'; }
    }
    my $sa_healthy = $self->_response_healthy(
        $sa_st, $sa_timeout, $sa_output_ok, $sa_complete, \%sa_seen, $ids);
    return ($sa_healthy, \%cat);
}

# Recognize only diagnostics that name the requested job ID on the same complete
# line. Slurm's common ID-less "Invalid job id specified" is deliberately not
# accepted as proof for a batched query.
sub _explicit_missing_id {
    my ($line) = @_;
    return $1 if $line =~ /^\s*(?:squeue|sacct):\s*(?:error:\s*)?
        (?:Invalid\s+job\s+id(?:\s+specified)?|Job\s+id\s+not\s+found)
        \s*[:=]?\s*<?(\d+)>?\.?\s*$/ix;
    return $1 if $line =~ /^\s*(?:squeue|sacct):\s*(?:error:\s*)?
        Job(?:ID)?\s*<?(\d+)>?\s+(?:is\s+)?not\s+found\.?\s*$/ix;
    return undef;
}

# scancel accepts many IDs per call; batch to stay under argv limits.
sub _cancel { return $_[0]->_cancel_batched('scancel', 200, $_[1]); }

1;
