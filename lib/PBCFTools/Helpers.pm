package PBCFTools::Helpers;

use strict;
use warnings;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Exporter qw(import);

our @EXPORT = qw(
    show_message
    show_status_line
    format_duration
    convert_length_to_integer
    format_walltime_lsf
    format_walltime_slurm
    format_memory_lsf
    format_memory_slurm
    detect_ncpu
    get_user_confirmation
    shq
    read_exit_code
    wait_status_exit
);

# Read a job's exit-code sentinel file (written by the worker script as its last
# act: `echo $? > FILE.rc`). Returns the integer exit code, or undef if the file
# is absent/empty/malformed. This is the ONLY trustworthy completion evidence
# when a scheduler job has vanished from squeue/sacct (or accounting is
# disabled): a non-empty *output* file can be a still-writing or crashed chunk,
# but the sentinel exists only after the worker actually exited.
sub read_exit_code {
    my ($path) = @_;
    return undef unless defined $path && -e $path && -s $path;
    open(my $fh, '<', $path) or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    $line =~ s/\s+//g;
    return ($line =~ /^\d+$/) ? int($line) : undef;
}

# Decode a raw wait status (from $? or the return of system()) into a single exit
# code that is NEVER 0 for an abnormal end. A process killed by a signal N leaves
# ($raw & 127) set and ($raw >> 8) == 0, so a bare `>> 8` reports success for a
# killed (e.g. OOM/SIGKILL) command. Use this everywhere a command's status is
# turned into pass/fail so a signal death can't masquerade as a clean exit.
sub wait_status_exit {
    my ($raw) = @_;
    return 127 if !defined $raw || $raw == -1;   # system()/exec failed to run
    return 128 + ($raw & 127) if ($raw & 127);   # killed by signal
    return $raw >> 8;                             # normal exit byte
}

# Robust POSIX shell-quote for one argument. Commands are run via
# system(STRING)/backticks = /bin/sh -c, so any shell metacharacter in an
# argument OR in a user-supplied path (e.g. the `>` in `-i 'AF>0.05'`, or a
# `$(...)`/backtick/`;`/space in a `-o` output name or `--p_dir`) must be
# protected. Single-quote wrapping makes the content fully literal; a literal
# single quote becomes '\''. Safe tokens are passed through unquoted. Shared by
# the main script and every backend so quoting is consistent everywhere.
sub shq {
    my ($s) = @_;
    return "''" unless defined $s && length $s;
    return $s if $s =~ m{^[A-Za-z0-9._/:@=,+-]+$};   # no metacharacters -> as-is
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# Internal state for status line overwriting
my $last_status_len = 0;

#=============================================================================
# Display
#=============================================================================

sub show_message {
    my ($message) = @_;
    return unless defined $message;
    # Diagnostics go to STDERR so pbcftools' own banner/progress never contaminate a
    # data stream on STDOUT (e.g. `pbcftools view ... -o - | bcftools ...`).
    syswrite STDERR, $message;
    return;
}

# Single overwriting status line with ETA
# Usage: show_status_line(total => N, done => N, running => N, pending => N,
#                         failed => N, start_time => epoch)
sub show_status_line {
    my (%a) = @_;
    my $time_str = strftime("%H:%M:%S", localtime());
    my $done  = $a{done}    // 0;
    my $total = $a{total}   // 0;
    my $run   = $a{running} // 0;
    my $pend  = $a{pending} // 0;
    my $fail  = $a{failed}  // 0;

    my $msg = sprintf("[%s] %d/%d done", $time_str, $done, $total);
    $msg .= sprintf(" | %d running", $run)   if $run;
    $msg .= sprintf(" | %d pending", $pend)  if $pend;
    $msg .= sprintf(" | %d failed", $fail)   if $fail;

    # ETA from elapsed rate
    if ($a{start_time} && $done > 0 && $done < $total) {
        my $elapsed = time() - $a{start_time};
        my $rate = $done / $elapsed;
        my $remaining = ($total - $done) / $rate;
        $msg .= sprintf(" | ETA %s", format_duration($remaining));
    }

    # Pad to overwrite any longer previous line, then carriage return. Track the
    # pre-padding length so the next call overwrites exactly this line's content.
    my $base_len = length($msg);
    my $pad = $last_status_len - $base_len;
    $msg .= " " x $pad if $pad > 0;
    $last_status_len = $base_len;

    syswrite STDERR, "\r$msg";
    syswrite STDERR, "\n" if $done >= $total;
    return;
}

# Format seconds into human-readable duration
sub format_duration {
    my ($sec) = @_;
    return "0s" unless $sec && $sec > 0;
    $sec = int($sec + 0.5);
    if ($sec < 60) {
        return "${sec}s";
    } elsif ($sec < 3600) {
        return sprintf("%dm %02ds", int($sec / 60), $sec % 60);
    } else {
        my $h = int($sec / 3600);
        my $m = int(($sec % 3600) / 60);
        my $s = $sec % 60;
        return sprintf("%dh %02dm %02ds", $h, $m, $s);
    }
}

#=============================================================================
# Conversion utilities
#=============================================================================

# Convert sequence length string to integer (e.g., "1MB" -> 1000000, "1e6" -> 1000000)
sub convert_length_to_integer {
    my ($length_str) = @_;
    my %multipliers = (
        ''   => 1,
        'bp' => 1,
        'k'  => 1000,
        'kb' => 1000,
        'm'  => 1_000_000,
        'mb' => 1_000_000,
    );

    $length_str =~ s/\s+//g;
    $length_str = lc($length_str);

    if ($length_str =~ /^(\d+\.?\d*(?:e\d+)?)(.*)$/) {
        my $num_str = $1;
        my $unit = $2;
        if (exists $multipliers{$unit}) {
            my $base_val = 0 + $num_str;
            return int($base_val * $multipliers{$unit});
        } else {
            warn "Warning: Invalid unit '$unit' in '$length_str'.\n";
        }
    }

    warn "Warning: Invalid format '$length_str'. Cannot parse.\n";
    return 0;
}

# Parse a human wall-time string into total seconds.
# Accepts: "1h30m", "90m", "1:30", "2h", "1:30:45".
# Colon forms ("H:MM", "H:MM:SS") are interpreted as hours:minutes[:seconds]
# consistently for all backends — this is pbcftools' own --p_wal convention,
# NOT the native (backend-specific) meaning of a bare "MM:SS".
sub _parse_walltime_seconds {
    my ($time_str) = @_;
    return undef unless defined $time_str;

    $time_str =~ s#/\S+##;
    $time_str =~ s/\s+//g;

    my ($hours, $minutes, $seconds);
    if ($time_str =~ /^(\d+):(\d+)(?::(\d+))?$/) {
        ($hours, $minutes, $seconds) = ($1, $2, defined $3 ? $3 : 0);
        # Reject out-of-range colon fields rather than silently rolling them over
        # (`1:99` must not become 2h39m).
        if ($minutes > 59 || $seconds > 59) {
            warn "Warning: minutes/seconds must be < 60 in '$time_str'.\n";
            return undef;
        }
    } elsif ($time_str =~ /^(?:(\d+)(?:h|hr))?(?:(\d+)(?:m|min))?(?:(\d+)(?:s|sec))?$/i) {
        ($hours, $minutes, $seconds) = (
            defined $1 ? $1 : 0,
            defined $2 ? $2 : 0,
            defined $3 ? $3 : 0
        );
    } else {
        warn "Warning: Invalid time format '$time_str'.\n";
        return undef;
    }

    my $total_seconds = $hours * 3600 + $minutes * 60 + $seconds;
    if ($total_seconds <= 0) {
        warn "Warning: Time must be a positive value.\n";
        return undef;
    }
    return $total_seconds;
}

# Convert time string to LSF bsub -W format (H:MM). Rounds up to the minute.
sub format_walltime_lsf {
    my ($time_str) = @_;
    my $total_seconds = _parse_walltime_seconds($time_str);
    return "" unless defined $total_seconds;

    my $total_minutes = int(($total_seconds + 59) / 60);
    my $final_hours   = int($total_minutes / 60);
    my $final_minutes = $total_minutes % 60;

    return sprintf "%d:%02d", $final_hours, $final_minutes;
}

# Convert time string to Slurm sbatch --time format (HH:MM:SS).
# Slurm reads a bare "H:MM" as minutes:seconds, so the LSF format is wrong here;
# the fully-qualified HH:MM:SS form is unambiguous.
sub format_walltime_slurm {
    my ($time_str) = @_;
    my $total_seconds = _parse_walltime_seconds($time_str);
    return "" unless defined $total_seconds;

    my $h = int($total_seconds / 3600);
    my $m = int(($total_seconds % 3600) / 60);
    my $s = $total_seconds % 60;

    return sprintf "%02d:%02d:%02d", $h, $m, $s;
}

# Convert memory string to LSF bsub -M format (e.g. "8GB", "500m" -> "500M").
# A bare number defaults to MB. (Note: whether LSF honors the unit depends on the
# site's LSF_UNIT_FOR_LIMITS; the string produced here is well-formed regardless.)
sub format_memory_lsf {
    my ($mem_str) = @_;
    return "" unless defined $mem_str;
    $mem_str =~ s/^\s+|\s+$//g;
    my $original = $mem_str;

    if ($mem_str =~ /^(\d+(?:\.\d+)?)\s*([kmgt]b?)?$/i) {
        my ($value, $unit) = ($1, $2 // 'M');
        return uc($value . $unit);
    }
    warn "Warning: Invalid memory string format '$original'.\n";
    return "";
}

# Convert memory string to Slurm --mem format (single-letter suffix: K/M/G/T).
# Slurm rejects "8GB"; it wants "8G". A bare integer is interpreted as MB.
sub format_memory_slurm {
    my ($mem_str) = @_;
    return "" unless defined $mem_str;
    $mem_str =~ s/^\s+|\s+$//g;
    my $original = $mem_str;
    my $lc = lc($mem_str);

    if ($lc =~ /^(\d+(?:\.\d+)?)\s*([kmgt])b?$/) {
        return sprintf("%s%s", $1, uc($2));   # 8gb->8G, 8g->8G, 500m->500M
    } elsif ($lc =~ /^(\d+)$/) {
        return "${1}M";                        # bare number: Slurm default unit is MB
    }
    warn "Warning: Invalid memory string format '$original'.\n";
    return "";
}

# Detect the number of CPUs portably: Linux `nproc`, then macOS/BSD
# `sysctl -n hw.ncpu`, falling back to 4. `nproc` does not exist on macOS.
sub detect_ncpu {
    for my $cmd ('nproc 2>/dev/null', 'sysctl -n hw.ncpu 2>/dev/null') {
        my $n = `$cmd`;
        chomp $n if defined $n;
        return int($n) if defined $n && $n =~ /^\d+$/ && $n > 0;
    }
    return 4;
}

#=============================================================================
# User interaction
#=============================================================================

sub get_user_confirmation {
    my ($prompt) = @_;
    print "$prompt [y/n]: ";
    my $response = <STDIN>;
    chomp $response;
    return lc($response) eq 'y';
}

1;
