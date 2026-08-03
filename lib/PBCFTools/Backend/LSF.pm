package PBCFTools::Backend::LSF;

# LSF profile for the shared async cluster controller (see Backend/Cluster.pm).
# Only scheduler-specific primitives live here; the control loop is inherited.

use strict;
use warnings;
use PBCFTools::Backend::Cluster;
use parent -norequire, 'PBCFTools::Backend::Cluster';
use PBCFTools::Helpers;

# Resource formatting: bsub -W H:MM, -M <MB>.
sub _fmt_wal { my ($self, $min) = @_; return sprintf("%d:%02d", int($min / 60), $min % 60); }
sub _fmt_mem { my ($self, $mb)  = @_; return "${mb}MB"; }
sub _submit_program { return 'bsub'; }

# Build the bsub command that runs $script (a per-chunk worker with a sentinel).
sub _submit_cmd {
    my ($self, $job, $script) = @_;
    my $bsub = "bsub"
        . " -W " . $self->_fmt_wal($job->{wal_min})
        . " -M " . $self->_fmt_mem($job->{mem_mb})
        . " -n " . $job->{cpu}
        . " -e " . shq("$job->{file}.err")
        . " -o " . shq("$job->{file}.out")
        . " -J " . shq($job->{name} // $self->{ppre});
    $bsub .= " -q " . shq($self->{pqueue})   if $self->{pqueue};
    $bsub .= " -P " . shq($self->{paccount}) if $self->{paccount};
    $bsub .= " /bin/sh " . shq($script);
    return $bsub;
}

# Extract the job ID from one job's bsub submission output.
sub _extract_id {
    my ($self, $text) = @_;
    return ($text =~ /Job <(\d+)> is submitted/) ? $1 : undef;
}

# Poll states for a set of IDs. Returns ($healthy, { id => 'active'|'done'|'failed' }).
# $healthy is 0 when the query itself failed (a transient LSF outage), so the
# controller does NOT read the empty result as "all jobs vanished".
# Unrecognized states (UNKWN/ZOMBI/...) are reported as 'unknown': ordinary job
# classification remains grace-bounded, while cancellation cannot mistake a
# visible but unmapped state for confirmed absence.
sub _poll_states {
    my ($self, $ids) = @_;
    my %cat;
    return (1, \%cat) unless @$ids;
    my %requested = map { ($_ => 1) } @$ids;
    my %active = map { $_ => 1 } qw(PEND RUN PROV WAIT SSUSP USUSP PSUSP);
    my %done   = map { $_ => 1 } qw(DONE POST_DONE);
    my %failed = map { $_ => 1 } qw(EXIT POST_ERR);

    my ($out, $st, $timed_out, $output_ok) = $self->_run_scheduler_client(
        ['bjobs', '-a', '-w', '-noheader', @$ids]);   # -a includes finished jobs
    my %seen;
    my $complete = 1;
    for my $line (split /\n/, $out) {
        next unless $line =~ /\S/;
        if ($line =~ /^\s*Job\s+<(\d+)>(?::\s*Job)?\s+is\s+not\s+found\.?\s*$/i
                && $requested{$1}) {
            $cat{$1} = 'done';       # explicit per-ID absence, never an omission
            $seen{$1} = 1;
            next;
        }
        my @f = split ' ', $line;    # split ' ' trims leading whitespace (no empty field 0)
        unless (@f >= 3 && $f[0] =~ /^\d+$/ && $requested{$f[0]}) {
            $complete = 0;
            next;
        }
        my ($id, $stat) = ($f[0], $f[2]);
        $seen{$id} = 1;
        if    ($done{$stat})   { $cat{$id} = 'done'; }
        elsif ($failed{$stat}) { $cat{$id} = 'failed'; }
        elsif ($active{$stat}) { $cat{$id} = 'active'; }
        else                   { $cat{$id} = 'unknown'; }
    }
    # Health test shared with Slurm (see Cluster::_response_healthy): a nonzero
    # query fails closed unless its complete output accounts for every requested
    # ID with either a parsed row or an explicit per-ID not-found.
    my $healthy = $self->_response_healthy(
        $st, $timed_out, $output_ok, $complete, \%seen, $ids);
    return ($healthy, \%cat);
}

# bkill accepts many IDs per call; batch to stay under argv limits.
sub _cancel { return $_[0]->_cancel_batched('bkill', 100, $_[1]); }

1;
