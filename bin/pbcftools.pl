#!/usr/bin/env perl

use strict;
use warnings;
use Carp qw(croak);
use feature 'say';

use List::Util;
use File::Temp qw/tempdir/;
use File::Path qw/make_path remove_tree/;
use File::Spec;
use File::Copy;
use IO::Handle;   # $fh->error — distinguish a read error from a clean EOF
use Text::ParseWords qw(quotewords);
use Pod::Usage qw(pod2usage);
use Getopt::Long qw(:config no_ignore_case bundling);
use POSIX qw(strftime);
use Time::HiRes qw(time sleep);

# Locate lib/ relative to THIS script WITHOUT FindBin. FindBin was historically
# core Perl, but some distributions now ship it separately (e.g. Fedora's
# perl-FindBin), so a minimal Perl >= 5.40 install dies at startup with
# "Can't locate FindBin.pm in @INC". File::Spec is already a hard dependency
# here, so this adds nothing new.
BEGIN {
    require File::Spec;
    my ($vol, $dir) = File::Spec->splitpath(File::Spec->rel2abs(__FILE__));
    unshift @INC, File::Spec->catpath($vol,
        File::Spec->catdir($dir, File::Spec->updir, 'lib'), '');
}
use PBCFTools::ArgParser qw(scan_command_argv);
use PBCFTools::Helpers;

our $VERSION = '1.0.1';

# show pbcftools version if it is the first argument
# `--version` at other position is passed through to bcftools 
if (@ARGV && $ARGV[0] eq '--version') {
    print "pbcftools $VERSION\n";
    exit 0;
}

# A single identifying line, in the style of ordinary command-line tools. The
# banner is written once, to STDERR, so it never contaminates piped output. It is
# suppressed for --help/--man, where pod2usage supplies its own heading.
unless (grep { $_ eq '--help' or $_ eq '-?' or $_ eq '--man' } @ARGV) {
    print STDERR "pbcftools $VERSION - parallel bcftools\n\n";
}

#=================================================================================================
# Step 0. Parse arguments
#=================================================================================================

# bcftools key options (intercepted)
my ($ofile);

# pbcftools parallel options
my ($pmode, $pjobs, $plen, $pdir, $ppre) = ('local', undef, '10MB', undef, 'pbcf');
my ($pref, $pfai);   # pfai: fasta index (.fai) for contig lengths (any organism)
# --p_index 1 (default) indexes the FINAL assembled output; 0 skips it. A user's own
# -W/--write-index overrides this and also chooses the format.
my $pindex = 1;
my $pyes;                # interaction options
my ($pwal, $pmem, $pcpu, $pint, $ptry)   = ('1hr', '8GB', 1, 10, 3);
my ($pmem_inc, $pwal_inc) = (50, 50);    # % mem / wall-time increase per retry (cluster)
my ($pqueue, $paccount);                 # LSF -q / -P  |  Slurm --partition / --account

my ($help, $man);

# bcftools passthrough args
my $bcftools_args;

# Capture the full invocation for the output provenance header, before
# GetOptions consumes the --p* options.
my $orig_cmdline = "pbcftools " . join(" ", @ARGV);
$orig_cmdline =~ s/[\r\n]+/ /g;
# Run start time, formatted exactly like bcftools' own header `Date=` field
# (ctime form, e.g. "Tue Jul 28 13:36:45 2026").
my $run_start_date = scalar(localtime());

# Preserve a plugin argument separator: bcftools plugins take their own options
# after `--` (e.g. `+fill-tags ... -- -t AF,AC`). Getopt::Long consumes the first
# `--`, so pull everything from `--` onward aside and re-append it verbatim.
my @after_ddash;
for my $i (0 .. $#ARGV) {
    if ($ARGV[$i] eq '--') {
        @after_ddash = @ARGV[$i .. $#ARGV];   # keep the '--' itself
        @ARGV        = @ARGV[0 .. $i - 1];
        last;
    }
}

# pbcftools' own options live in a namespace bcftools cannot occupy: every one is
# --p_<name>, and NO bcftools long option contains an underscore (checked across all
# 226 of them). Since getopt_long abbreviation is prefix matching, no bcftools option
# can ever have "p_..." as a prefix either, so the two namespaces are disjoint by
# construction rather than by luck.
#
# This replaced --pjobs/--pref/... which collided: `--pref` was simultaneously ours
# and a valid abbreviation of `bcftools isec --prefix`, so we consumed it plus the
# next argv token — an INPUT FILE — and exited 0 having intersected one file instead
# of two. The runtime ambiguity guard that used to detect that case is gone; there is
# nothing left to detect.
#
# pass_through:    anything not ours belongs to bcftools.
# no_auto_abbrev:  no longer needed for SAFETY (an abbreviation of --p_jobs still
#                  contains an underscore and so still cannot be a bcftools option),
#                  but kept for predictability — a pbcftools option must be spelled
#                  in full, and everything else reaches bcftools untouched.
# no_getopt_compat: without it Getopt::Long ALSO accepts `+p_len` as `--p_len`.
# That let `isec -f +p_len A PASS C -o A` slip past the value-position check — which
# looks for `--p_` spellings — and destroy input A at exit 0. '+' is bcftools' plugin
# prefix (`bcftools +fill-tags`), so it was never ours to claim.
Getopt::Long::Configure("pass_through", "no_auto_abbrev", "no_getopt_compat");
# Snapshot argv BEFORE GetOptions consumes our options. _resolve_output_dest() needs
# it: bcftools applies last-occurrence-wins across -o / --output / --output-dir, and
# that ORDER cannot be reconstructed afterwards because GetOptions has already
# removed the spellings it recognised.
my @argv_before_getopt = @ARGV;
GetOptions(
    'output|o=s' => \$ofile,

    'p_mode=s'    => \$pmode,
    'p_jobs=i'    => \$pjobs,
    'p_len=s'     => \$plen,
    'p_dir=s'     => \$pdir,
    'p_pre=s'     => \$ppre,

    'p_ref=s'     => \$pref,
    'p_fai=s'     => \$pfai,

    'p_index=i'   => \$pindex,

    'p_yes'       => \$pyes,

    'p_wal=s'     => \$pwal,
    'p_mem=s'     => \$pmem,
    'p_cpu=i'     => \$pcpu,
    'p_int=i'     => \$pint,
    'p_try=i'     => \$ptry,
    'p_mem_inc=i' => \$pmem_inc,
    'p_wal_inc=i' => \$pwal_inc,
    'p_queue=s'   => \$pqueue,
    'p_account=s' => \$paccount,

    'help|?'     => \$help,
    'man'        => \$man,
) or pod2usage(2);

# --p_pre becomes both a scheduler job-name and a filesystem path component, so
# constrain it to a conservative, shell/filesystem-safe alphabet (no spaces,
# metacharacters, or path separators). shq() would neutralize shell injection
# regardless, but rejecting these up front also prevents path traversal and
# malformed job names, and keeps a clear failure over a confusing downstream one.
if (defined $ppre && ($ppre !~ /^[A-Za-z0-9._-]+$/ || length($ppre) > 32)) {
    pod2usage(-message => "ERROR: --p_pre must be 1-32 chars of letters, digits, '.', '_' or '-' "
        . "(got '$ppre').\n", -exitval => 2);
}

# Validate --p_mode up front: an unknown value (e.g. a 'slrum' typo) must NOT
# silently fall through to Local mode and launch --p_jobs workers on a login node.
unless ($pmode =~ /^(?:local|lsf|slurm)$/) {
    pod2usage(-message => "ERROR: --p_mode must be one of: local, lsf, slurm (got '$pmode').\n",
        -exitval => 2);
}

# Cluster backends require an explicit --p_dir on a filesystem visible from BOTH
# the submit host and the compute nodes. Without it we would fall back to a
# submit-node-local temp dir that workers cannot see, so chunk scripts/outputs
# silently vanish. A path-name heuristic can't prove visibility; require the
# explicit choice (a warning would be defeated by --p_yes).
if ($pmode =~ /^(?:lsf|slurm)$/ && !defined $pdir) {
    pod2usage(-message => "ERROR: --p_dir is required for --p_mode $pmode and must be on a "
        . "filesystem visible from both the submit host and the compute nodes "
        . "(a node-local temp dir would make chunk outputs invisible).\n", -exitval => 2);
}

# With pass_through, @ARGV retains all unrecognized options (-r, -s, -f, etc.)
# and positional args (command name, file path) in their original order.
# Re-append the plugin args that followed `--`.
$bcftools_args = [@ARGV, @after_ddash];
@ARGV = ();

# Immutable copy of the user's original bcftools argv. The parallel path mutates
# $bcftools_args (strips -l/--file-list, positional inputs, -r, overlap, ...),
# but every DIRECT passthrough must run the user's command verbatim — otherwise a
# merge/isec that routes to bcftools directly would run with its inputs stripped.
my $orig_bcftools_args = [@$bcftools_args];

# pod2usage(1)/(2) passes those as the EXIT VALUE, leaving verbosity at 0, so both
# printed only the SYNOPSIS. Verbosity 1 gives usage plus the options sections;
# verbosity 2 renders the whole POD as a man page. Exit 0 -- asking for help is not
# an error.
# -verbose 1 only picks up headings literally named OPTIONS/ARGUMENTS, and ours is
# "PBCFTOOLS OPTIONS", so it printed the SYNOPSIS alone. -verbose 99 selects the
# named sections explicitly.
pod2usage(-verbose  => 99,
          -sections => 'NAME|SYNOPSIS|PBCFTOOLS OPTIONS|EXAMPLES',
          -exitval  => 0) if $help;
pod2usage(-verbose => 2, -exitval => 0) if $man;

# Extract bcftools command (first non-flag arg)
my $command;
if (scalar @$bcftools_args >= 1 && $bcftools_args->[0] !~ /^-/) {
    $command = $bcftools_args->[0];
} else {
    croak("Usage: pbcftools [COMMAND] [OPTIONS]\nPlease provide a bcftools command.");
}

# Accept the `bcftools plugin NAME ...` spelling as equivalent to `+NAME ...`.
# When `plugin` is followed by a bare plugin name, collapse `plugin NAME` into
# `+NAME` so all the `+NAME` handling below applies uniformly. A bare `plugin`,
# or `plugin -l`/`-h` (no name), is left as-is and caught by the informational
# passthrough just below. An explicit path (`plugin /path/x.so`) is not
# collapsed — it falls through to the informational/normal path unchanged.
if (lc($command) eq 'plugin') {
    my $name = $bcftools_args->[1];
    if (defined $name && $name =~ /^[A-Za-z][\w-]*$/) {
        $command = "+$name";
        splice(@$bcftools_args, 0, 2, "+$name");   # `plugin NAME` -> `+NAME`
    }
}


# ---------------------------------------------------------------------------
# Auto-indexing (-W / --write-index) is a WHOLE-OUTPUT request, not a per-chunk one.
# Left in place it made every chunk build an index that is then thrown away when the
# chunks are concatenated -- pure waste, N times over. Capture the user's intent
# here, remove the flag from what the workers run, and apply it once to the
# assembled result. An explicit -W also overrides --p_index, since asking for an
# index is unambiguous, and it carries the format the user asked for (-W=tbi).
my $index_fmt;                       # undef = csi (bcftools default)
{
    my @keep;
    for my $t (@$bcftools_args) {
        if ($t =~ /^--write-index(?:=(\S+))?$/) { $pindex = 1; $index_fmt = $1; next }
        if ($t =~ /^-W(?:=(\S+))?$/)            { $pindex = 1; $index_fmt = $1; next }
        push @keep, $t;
    }
    @$bcftools_args = @keep;
}

# Normalize short-option bundles for every INTERNAL decision that follows
# (routing, region/output-type detection, splitting). $orig_bcftools_args keeps
# the user's original spelling, so passthrough runs verbatim and the provenance
# header still matches a direct bcftools run. If a bundle cannot be resolved we
# do NOT guess: run bcftools directly.
my $bundle_unresolved = 0;
my $short_arity;                 # letter => 0 flag, 1 value, 2 FILE-valued
my $file_long = {};              # long option name => 1 if FILE-valued
my $long_arity;                  # long option name => 0 flag, 1 value, 2 FILE-valued
{
    my $arity_info = _short_opt_arity($command);
    $short_arity = $arity_info ? $arity_info->{short} : undef;
    $file_long   = $arity_info ? $arity_info->{file_long} : {};
    $long_arity  = $arity_info ? $arity_info->{long} : undef;
    my $expanded = _expand_short_bundles($bcftools_args, $command);
    if (!defined $expanded) { $bundle_unresolved = 1; }
    else                    { $bcftools_args = $expanded; }
    # Rewrite unambiguous long-option ABBREVIATIONS to their canonical names, so
    # that every guard below (destructive-alias, stdin, positional, region) sees
    # the real option and not a prefix it fails to recognise. Done here, once.
    $bcftools_args = _canonicalize_long_opts($bcftools_args, $arity_info) if $arity_info;

    # RESOLVE THE OUTPUT DESTINATION the way bcftools does: the LAST occurrence
    # wins, whatever spelling it used. GetOptions intercepts only exact -o/--output,
    # so every other spelling stayed in the argv, and two bugs followed:
    #   * `query --out FILE` and `cnv --output-dir DIR` died with "Please provide a
    #     bcftools output file" on commands that work serially;
    #   * `query -o A --out B` wrote to A and left an empty B, where serial writes
    #     only to B — and `cnv -o A --output-dir B` let the surviving --output-dir
    #     override staging so both workers wrote concurrently into B.
    # Order can only be judged on the ORIGINAL argv, because GetOptions has already
    # removed the spellings it recognised. Every output option is then stripped from
    # the worker argv, since pbcftools supplies its own -o per chunk.
    if ($arity_info) {
        my $resolved = _resolve_output_dest(\@argv_before_getopt, $arity_info);
        $ofile = $resolved if defined $resolved;
        _strip_output_opts($bcftools_args, $arity_info);
    }

    # A --p<name> spelling without the underscore belongs to neither tool. Name the
    # right option instead of letting bcftools report a bare "unrecognized option".
    # Only fires for tokens bcftools has no option for, so a real bcftools option is
    # never intercepted — a diagnostic on a path that fails anyway, not a guard.
    _warn_renamed_wrapper_opts($bcftools_args, $arity_info) if $arity_info;

    # A --p_<name> token that sat where bcftools expected a VALUE was captured by
    # GetOptions before the subcommand's arity was known, taking the next argument
    # with it. Detect that and stop — the argument it removed may be an input file.
    _refuse_wrapper_opt_in_value_position(\@argv_before_getopt, $arity_info, $command)
        if $arity_info;
}
# Snapshot AFTER bundle expansion but BEFORE the parallel path strips file lists,
# positional inputs, -r and overlap. The destructive-output guard must scan this:
# the user's original spelling hides bundled options (`-uvLIST`), and the mutated
# copy has already lost the very inputs the guard exists to protect.
my $guard_args = [@$bcftools_args];

# An option whose VALUE is stdin ('-') can be read exactly ONCE. The argument
# validation probe consumes it, and every worker then reads EOF: `view -S-` kept
# sample HG00096 serially but produced ZERO samples in parallel, at exit 0.
# Detect it on the EXPANDED argv (so `-S-` is already `-S -`) and run directly.
my $stdin_valued_opt;
{
    my @a = @$bcftools_args;
    # A leading '^' is bcftools' EXCLUDE prefix on [^]FILE options, not part of
    # the filename: `-S ^-` still reads the sample list from stdin. Strip it
    # before testing, or the check misses the negated spelling (`view -S^-`
    # returned ALL samples in parallel vs. the correct subset serially, exit 0).
    my $is_stdin = sub { defined $_[0] && $_[0] =~ /^\^?-$/ };
    for my $i (1 .. $#a) {
        last if $a[$i] eq '--';
        if ($a[$i] =~ /^--([A-Za-z0-9-]+)=(.*)$/s && $is_stdin->($2)) {
            $stdin_valued_opt = "--$1" if $file_long->{$1};
            last if $stdin_valued_opt;
            next;
        }
        next unless $is_stdin->($a[$i+1]);
        if ($a[$i] =~ /^-([A-Za-z])$/ && $short_arity && ($short_arity->{$1} // 0) == 2) {
            $stdin_valued_opt = "-$1"; last;
        }
        if ($a[$i] =~ /^--([A-Za-z0-9-]+)$/ && $file_long->{$1}) { $stdin_valued_opt = $a[$i]; last }
    }
}

# Informational plugin invocations take no input/output and just print — defer
# straight to bcftools and exit, before the input/output-file requirements below:
#   pbcftools plugin                 (list common plugin options)
#   pbcftools plugin -l              (list available plugins; --list-plugins too)
#   pbcftools +NAME -h               (a plugin's own usage; --help form is the
#                                     wrapper's usage, handled by GetOptions)
# `-h` is treated as informational ONLY for plugin commands — for `view`/`query`
# it means "header only" and must pass through normally.
if ($command =~ /^\+/ || lc($command) eq 'plugin') {
    my $informational = (lc($command) eq 'plugin');   # bare/uncollapsed `plugin`
    $informational ||= grep { /^(?:-h|--help|-l|--list-plugins)$/ } @$bcftools_args;
    if ($informational) {
        exit(_bcftools_passthrough($orig_bcftools_args, undef, $command,
            "informational plugin command"));
    }
}

# Extract input file(s)
# For single-input commands: scan args for existing file
# For multi-input commands (merge/isec): use --file-list/-l to get all input files
my $ifile;        # primary input file (used for contig detection)
my $file_list;    # path to file list (if provided via -l/--file-list)
my @input_files;  # all input files (populated for multi_input mode)
my $mixed_input_passthrough = 0;  # merge/isec given BOTH positional inputs AND a -l list
my $multi_primary_why;            # single-input cmd with >1 primary operand -> passthrough (fail-safe)
my $input_parse_ambiguous = 0;    # bounded parser did not recognize the full argv grammar

# Only merge takes multiple inputs on the parallel path (isec is routed straight to
# bcftools). Gating on the command (not on "how many positional args happen to be
# existing files") prevents misclassifying a file-valued option argument — e.g.
# `annotate -h header.txt input.vcf.gz` — as a second input, and prevents reading
# `-l` as a file list for commands where it means something else (e.g. `query -l` =
# --list-samples, which takes no value).
my %MULTI_INPUT_CMD = (merge => 1);

# Commands whose primary operands must be identified exactly use a bounded,
# command-aware structural parser.  The schema is deliberately finite: a newer
# bcftools option that is not yet described is ambiguity, never permission to
# guess which tokens are inputs and region-split them.
my $input_scan = scan_command_argv($bcftools_args, $command);
$input_parse_ambiguous = $input_scan && $input_scan->{ambiguous};

# Check for a role-tagged file list only on a fully understood multi-input argv.
# The last occurrence wins like getopt_long; every occurrence is stripped from
# the parallel argv by INDEX, never by matching its text.
if ($MULTI_INPUT_CMD{lc($command)} && !$input_parse_ambiguous) {
    my $lists = $input_scan->{roles}{file_list} // [];
    if (@$lists) {
        $file_list = $lists->[-1]{value};
        my %drop = map { ($_ => 1) } map { @{$_->{indices}} } @$lists;
        $bcftools_args = [ map { $bcftools_args->[$_] } grep { !$drop{$_} } 0 .. $#$bcftools_args ];
    }
}

if ($input_parse_ambiguous) {
    # Leave argv and input state untouched.  The alias guard below sees all
    # plausible operands; then the normal passthrough path reports this reason.
} elsif (defined $file_list) {
    # Explicit file list via -l/--file-list
    show_message("Input file list: $file_list\n");
    open(my $fh, '<', $file_list) or croak("Cannot open file list '$file_list': $!");
    while (<$fh>) {
        chomp;
        next if /^\s*$/ || /^#/;
        push @input_files, $_;
    }
    # A mid-file READ error looks like EOF and would silently accept only a PREFIX
    # of the inputs (dropping samples/files). Require a clean read + close.
    croak("Read error on file list '$file_list' (a partial input list is unsafe): $!")
        if $fh->error;
    close($fh) or croak("Close of file list '$file_list' failed: $!");
    croak("File list '$file_list' is empty.") unless @input_files;
    $ifile = $input_files[0];
    show_message(sprintf("  %d input files (first: %s)\n", scalar @input_files, $ifile));
    # bcftools merge/isec process positional inputs AND a -l list together, but the
    # wrapper only discovers contigs/lengths from the list — a positional input with
    # a later-only contig or out-of-range records would be silently dropped. If ANY
    # positional input file is present alongside the list, run through bcftools
    # directly (fail-closed). Extension-AGNOSTIC to match the indexed-input policy
    # (_is_indexed): an indexed input may be named `sample.data` or have no
    # extension. A conservative false positive only loses parallelism, which is safe.
    if (@{$input_scan->{operands}}) {
        $mixed_input_passthrough = 1;
    }
} elsif ($MULTI_INPUT_CMD{lc($command)}) {
    # Multi-input command without -l: every structurally identified operand is
    # an input, independent of its extension.
    @input_files = map { $_->{value} } @{$input_scan->{operands}};

    if (@input_files) {
        $ifile = $input_files[0];
        show_message(sprintf("Detected %d positional input files (first: %s)\n",
            scalar @input_files, $ifile));
        # Strip input files from bcftools_args — they are passed via per-chunk
        # file lists in bcftools_split_jobs instead.
        my %drop = map { ($_->{index} => 1) } @{$input_scan->{operands}};
        $bcftools_args = [ map { $bcftools_args->[$_] } grep { !$drop{$_} } 0 .. $#$bcftools_args ];
    }
} else {
    # Single-input command: identify the one input VCF/BCF to probe for contigs.
    # Do NOT strip anything — everything else passes through to bcftools.
    if ($input_scan) {
        my @operands = map { $_->{value} } @{$input_scan->{operands}};
        $ifile = $operands[0] if @operands;
    } else {
        # FAIL-SAFE: a single-input command with MORE THAN ONE plausible primary
        # operand must NOT be region-split. bcftools view/query/filter/annotate read
        # the FIRST operand; guessing (e.g. the last VCF-looking one) can discover
        # contigs from the wrong file and silently emit no data. The candidate set is
        # EXTENSION-AGNOSTIC — an indexed input may be extensionless (`sample`) or a
        # `.vcf.gz`; preferring VCF-suffixed names would miss an extensionless first
        # input paired with a suffixed second and re-open the same silent-drop hole.
        my @primary = _collect_positional_files($bcftools_args, $short_arity);
        if (@primary > 1) {
            $multi_primary_why = "'$command' has more than one positional input ("
                . scalar(@primary) . "); region-splitting can't know which bcftools "
                . "treats as primary, so it could silently drop data";
        } elsif (@primary) {
            $ifile = $primary[0];       # the one primary input (bcftools' first operand)
        }
    }
    # query -v/--vcf-list reads a FILE OF VCFs (multi-input); the parallel path can't
    # discover contigs across the list safely — run directly.
    if (lc($command) eq 'query' && _has_flag($bcftools_args, 'v', 'vcf-list')) {
        $multi_primary_why = "'query -v/--vcf-list' reads multiple VCFs from a list";
    }

}

# Refuse an output path that aliases an input BEFORE anything can overwrite it —
# including the passthrough exits below (an unindexed `view in.vcf -o in.vcf` would
# otherwise run bcftools directly and destroy the input). Must precede EVERY
# passthrough and the parallel path.
_refuse_io_alias($ofile, _alias_candidate_paths($guard_args, $command, $ofile));

if (defined $stdin_valued_opt) {
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        "'$stdin_valued_opt -' reads from stdin, which can only be consumed once"));
}

if ($bundle_unresolved) {
    # A short-option bundle contained a letter this bcftools' --help did not
    # describe (or arity could not be read at all). Splitting could silently drop
    # a hidden -r/-R or mis-handle a hidden -O, so run bcftools directly. This MUST
# come after _refuse_io_alias: an early exit here would skip the destructive
# output-alias check and let bcftools overwrite one of its own inputs.
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        "a short-option bundle could not be resolved against 'bcftools $command --help'"));
}


if ($input_parse_ambiguous) {
    my $detail = join('; ', @{$input_scan->{ambiguities}});
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        "argument syntax outside the bounded '$command' parser"
        . (length($detail) ? ": $detail" : '')));
}

# --- General precondition for parallelization: a region-seekable input ---
# pbcftools can only split by region when it has an INDEXED input to seek into
# (all N of them for merge/isec). A file is region-seekable if it carries a
# companion .csi/.tbi index — true for bgzipped VCF/BCF and any other indexed
# bgzipped file, regardless of extension. If there is no input, or an input is
# not indexed (plain text, unindexed, or a stdin stream), there is nothing to
# region-split: run the command with plain bcftools and exit, behaving exactly
# like bcftools. This transparently covers informational commands, streamed
# input, and unindexed files — and keeps pbcftools a safe drop-in wrapper.
{
    my @inputs = @input_files ? @input_files : (defined $ifile ? ($ifile) : ());
    my @unseekable = grep { !_is_indexed($_) } @inputs;
    if ($multi_primary_why || !@inputs || @unseekable) {
        my $why = $multi_primary_why ? $multi_primary_why
                : !@inputs ? "no input file to region-split"
                : "input not indexed (need .csi/.tbi): " . join(", ", @unseekable[0 .. ($#unseekable < 2 ? $#unseekable : 2)]);
        exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command, $why));
    }
}

# --- User -R/--regions-file: run directly (v1) ------------------------------
# A regions FILE would need to be read and grouped by contig to parallelize
# correctly; for v1 pass it through. Inline -r/--regions IS parallelized (grouped
# by contig, one worker per contig — see Step 1). -R also historically conflicts
# with the per-chunk -r we inject.
# `--regions-f...` is bcftools' unique abbreviation of --regions-file (distinct
# from --regions and --regions-overlap), so match the prefix, not just the exact.
if (grep { /^-R/ || /^--regions-f[a-z]*(?:$|=)/ } @$bcftools_args) {
    # `-R` (any attached value, e.g. `-Rfile`) or --regions-file[=...]/abbrev.
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        "-R/--regions-file (regions from a file)"));
}

# Note: the hard "-o is required" check is deferred until AFTER command
# classification — some passthrough commands (isec -p, convert -h) use their own
# output mechanism (a prefix/directory) and legitimately have no -o.


my $is_vcf = (defined $ofile && $ofile =~ /\.(vcf|bcf)(?=\.|$)/i) ? 1 : 0;
# An EXPLICIT output-type flag is authoritative and overrides the extension guess:
# -O b|z|u|v -> VCF/BCF (even with a non-standard name like `-Ob -o cohort`);
# -O t -> tabular TEXT (e.g. `csq -Ot -o result.vcf.gz` writes TSV, not VCF, so it
# must NOT go to the VCF concat path). Check the LAST -O (bcftools last-wins).
{
    # `--output-t...` (abbreviation of --output-type; --output alone is -o) and -O.
    my $otype;
    for my $i (0 .. $#$bcftools_args) {
        my $a = $bcftools_args->[$i];
        if    ($a =~ /^-O([a-z])/i || $a =~ /^--output-t[a-z]*=([a-z])/i)  { $otype = lc($1); }
        elsif ($a =~ /^(?:-O|--output-t[a-z]*)$/ && defined $bcftools_args->[$i+1]
               && $bcftools_args->[$i+1] =~ /^([a-z])/i)                   { $otype = lc($1); }
    }
    if (defined $otype) {
        $is_vcf = ($otype =~ /^[bzuv]$/) ? 1 : 0;   # b/z/u/v -> VCF/BCF; t (or other) -> text
    }
}

# Command classification for parallelization strategy
# region:      standard split-by-interval, concat output (embarrassingly parallel)
# chromosome:  split by whole chromosome only (HMM/sequential algorithms)
# multi_input: pass ALL input files to each region chunk
# aggregate:   run per-region, then merge/aggregate results
# incompatible: cannot be parallelized
my %CMD_MODE = (
    # region: embarrassingly parallel
    'view'      => 'region',
    'query'     => 'region',
    'filter'    => 'region',
    'annotate'  => 'region',
    'call'      => 'region',
    'norm'      => 'region',
    'convert'   => 'region',
    'csq'       => 'region',
    # chromosome: HMM/sequential-state algorithms. State carries ALONG a contig but
    # contigs are independent, so these split by WHOLE CHROMOSOME and are never
    # sub-divided within one (see $whole_chrom). Sub-splitting would corrupt the
    # result — a run cut mid-segment is reported as two truncated, overlapping
    # segments instead of one.
    #  - roh: tabular text. Each chunk's header repeats the '# The command line
    #    was:' line with that chunk's -r, so assembly normalizes that line out
    #    (see append_tab_file) and rewrites it to the user's command.
    'roh'       => 'chromosome',
    # multi_input: need all files per region
    'merge'     => 'multi_input',
    # aggregate: per-region then merge
    'stats'     => 'aggregate',
    # incompatible
    # isec runs SERIALLY by choice, not by necessity. Supporting it in parallel
    # required pbcftools to model three separate isec-specific quirks -- that -O
    # selects a format only when -w/--write is given (otherwise the output is a
    # tab-delimited sites list whatever -O says), that -p/--prefix writes a
    # multi-file directory, and that -w must not be confused with -W/--write-index.
    # Each is a rule tracking bcftools semantics that pbcftools has no business
    # knowing. It was also the one command with a known parallel failure on a
    # supported bcftools (1.19: serial succeeds, parallel exits non-zero). Trading a
    # modest speedup for the removal of both the special cases and the defect is the
    # better bargain; see KNOWN_ISSUES.md.
    'isec'      => 'incompatible',
    # cnv also runs SERIALLY by choice. It writes a DIRECTORY of sample-named files
    # (summary.tab, dat.<s>.tab, cn.<s>.tab, plot.<s>.py) whose names carry no contig,
    # so a parallel run had to give each contig its own subdirectory -- a layout that
    # differs from serial by design, and an entire third output kind ('dir') with its
    # own publication, path-rebinding and rerun rules. Removing it removes a surprise
    # as well as the machinery; see KNOWN_ISSUES.md.
    'cnv'       => 'incompatible',
    'sort'      => 'incompatible',
    'index'     => 'incompatible',
    'concat'    => 'incompatible',
    'reheader'  => 'incompatible',
    'head'      => 'incompatible',
    'consensus' => 'incompatible',
    'split'     => 'incompatible',
    'scatter'   => 'incompatible',
    # These are real bcftools commands that pbcftools does not divide. Listing them
    # means `pbcftools <cmd>` runs bcftools rather than refusing: the whole promise
    # of the wrapper is that an existing command line still works when you prepend
    # pbcftools, and refusing a legitimate command breaks that for no benefit.
    #   gtcheck   compares samples across the WHOLE file; per-region tallies are not
    #             combinable without re-deriving the comparison.
    #   polysomy  fits a model per sample over a whole chromosome arm.
    #   mpileup   IS region-divisible in principle, and is the classic case for it,
    #             but it reads BAM/CRAM rather than VCF, so the contig discovery and
    #             input handling here do not apply. Left for a later release.
    'gtcheck'   => 'incompatible',
    'polysomy'  => 'incompatible',
    'mpileup'   => 'incompatible',
);

# bcftools plugins are invoked as `+name`. Only plugins that are verified
# serial-equivalent under region splitting AND have an exact end-to-end test are
# classified 'region'. For v1 that is +fill-tags alone: it recomputes per-record
# INFO tags (AC/AN/AF/...) with no cross-region state, and its output matches
# serial byte-for-byte in the regression suite.
#
# Other per-record plugins (+setGT, +fill-from-fasta, +missing2ref) are plausibly
# region-independent but are NOT parallelized in v1 — they emit a summary line to
# stderr/stdout ("Filled N alleles") that the per-region validation cannot yet
# distinguish from a fatal error, and some modes (+setGT random targets) restart
# their RNG per chunk and so are not serial-equivalent. They run unparallelized
# via passthrough until each gets command-aware validation + an exact test.
my %PLUGIN_MODE = (
    'fill-tags'       => 'region',       # recompute AC/AN/AF/... per record (tested)
    'setGT'           => 'incompatible', # summary output + RNG-per-chunk modes
    'fill-from-fasta' => 'incompatible', # not yet validated serial-equivalent
    'missing2ref'     => 'incompatible', # not yet validated serial-equivalent
    'split'           => 'incompatible', # one output per sample/group
    'scatter'         => 'incompatible', # one output per region set
);

# Fail closed on unrecognized commands: silently region-splitting a command with
# global state (a future/unknown bcftools subcommand) could corrupt output.
my $cmd_mode;
# When a specific check routes a command to 'incompatible', it records WHY here so
# the single passthrough notice states the exact reason (not a generic fallback).
my $incompat_why;
if ($command =~ /^\+(.+)$/) {
    my $plugin = $1;
    $cmd_mode = $PLUGIN_MODE{$plugin};
    unless (defined $cmd_mode) {
        croak("Plugin '+$plugin' is not classified as region-safe by pbcftools.\n"
            . "  Region-parallel plugins (v1): +fill-tags\n"
            . "  Run other plugins directly with bcftools, or add '+$plugin' to\n"
            . "  \%PLUGIN_MODE in pbcftools.pl once it is verified region-independent\n"
            . "  (serial-equivalent output + an exact end-to-end test).");
    }
} else {
    $cmd_mode = $CMD_MODE{lc($command)};
    unless (defined $cmd_mode) {
        croak("Command '$command' is not recognized by pbcftools.\n"
            . "  Region-parallel:  view query filter annotate norm call convert csq\n"
            . "  Plugins:          +fill-tags\n"
            . "  Aggregate:        stats\n"
            . "  Multi-input:      merge\n"
            . "  Per-chromosome:   roh\n"
            . "  pbcftools refuses unknown commands rather than risk splitting a\n"
            . "  global-state command incorrectly. Run it directly with bcftools, or\n"
            . "  add it to \%CMD_MODE in pbcftools.pl if it is genuinely region-safe.");
    }
}

# --- Mode-aware refinement (the parallel-safety guard) ----------------------
# The command name alone is not enough: some OPTIONS make an otherwise
# region-safe command boundary-sensitive — it needs neighboring records, spans a
# transcript, or moves a record's coordinate. Those operations still reset at a
# contig boundary, so we run them per WHOLE CHROMOSOME. Options that emit a
# multi-file family or a shared side file cannot be split at all -> passthrough.
# Detection is structural (see _has_opt) and fails toward the stricter mode.
if ($cmd_mode eq 'region') {
    my $chrom_reason;
    if ($command eq 'norm') {
        # -f left-aligns (unless -N = check-only), -a atomizes, -g right-aligns in
        # transcripts: each can move/create records across an interval boundary.
        # -N (do-not-normalize) is mode-RELAXING (makes -f check-only, region-safe),
        # so detect it conservatively with _has_flag — a false positive would wrongly
        # skip chromosome mode. -f/-a/-g are mode-tightening (over-match is safe).
        $chrom_reason = 'left-align / atomize / GFF right-align can move records across boundaries'
            if (_has_opt($bcftools_args, 'f', 'fasta-ref') && !_has_flag($bcftools_args, 'N', 'do-not-normalize'))
            || _has_opt($bcftools_args, 'a', 'atomize')
            || _has_opt($bcftools_args, 'g', 'gff-annot');
    } elsif ($command eq 'filter') {
        $chrom_reason = 'SnpGap/IndelGap inspect neighboring variants'
            if _has_opt($bcftools_args, 'g', 'SnpGap', 'G', 'IndelGap');
    } elsif ($command eq 'call') {
        $chrom_reason = 'gVCF blocks group consecutive sites across boundaries'
            if _has_opt($bcftools_args, 'g', 'gvcf');
    } elsif ($command eq 'csq') {
        if (_has_opt($bcftools_args, 'dump-gff')) {
            $incompat_why = "'csq --dump-gff' writes a shared side file";
            $cmd_mode = 'incompatible';
        } elsif (!_has_flag($bcftools_args, 'l', 'local-csq')) {
            # -l (local-csq) is mode-RELAXING (region-safe); detect conservatively so
            # an attached fasta/GFF value containing 'l' can't suppress chromosome mode.
            #
            # Haplotype-aware csq reasons across records within a transcript, so it is
            # never split WITHIN a contig. Splitting BETWEEN contigs was checked
            # directly against bcftools: with a GFF covering both contigs, per-contig
            # output is byte-identical to a whole-file run, and FORMAT/BCSQ is emitted
            # per record (only where there is a consequence) rather than being decided
            # for the whole file.
            #
            # A review reported a case where the two differed on the final record. It
            # could not be reproduced here, and the check that appeared to confirm it
            # was invalid: `bcftools csq` ERRORS when a VCF contig is absent from the
            # GFF, so the per-contig comparison had been made against a truncated file.
            # Recorded as an open question rather than acted on — see the ledger.
            $chrom_reason = 'haplotype-aware consequences need complete transcripts';
        }
    } elsif ($command eq 'convert') {
        if (_has_opt($bcftools_args, 'gvcf2vcf')) {
            $chrom_reason = 'gVCF reference blocks expand beyond region boundaries';
        } elsif (_has_opt($bcftools_args, 'g', 'G', 'gensample', 'h', 'hapsample', 'H', 'haplegendsample',
                          'gensample2vcf', 'hapsample2vcf', 'haplegendsample2vcf', 'tsv2vcf')) {
            # Forward GEN/HAP/SAMPLE modes write a multi-file family from a prefix;
            # reverse (*2vcf) modes (short -G/-H) read non-VCF input. Neither is a
            # single-stream region job. Note: convert '-h' is --hapsample, NOT help.
            $incompat_why = "'convert' file-family / reverse mode";
            $cmd_mode = 'incompatible';
        }
    } elsif ($command eq 'view') {
        # -h/--header-only is a whole-file query; -H/--no-header emits headerless
        # records that `concat` can't identify as VCF. Both run directly.
        if (_has_opt($bcftools_args, 'h', 'header-only', 'H', 'no-header')) {
            $incompat_why = "'view -h/-H' (header-only / no-header) can't be region-merged";
            $cmd_mode = 'incompatible';
        }
    } elsif ($command eq 'query') {
        # `query -H/-HH` prints a header whose LAST field carries no trailing
        # newline and runs into the data, so a multi-line format defeats any
        # header-line count. Run header-printing query directly for v1. (query
        # WITHOUT -H parallelizes fine — every line is data, concatenated as-is.)
        if (_has_opt($bcftools_args, 'H', 'print-header')) {
            $incompat_why = "'query -H' (with header) isn't tiled safely in v1";
            $cmd_mode = 'incompatible';
        }
    }
    if ($chrom_reason) {
        $cmd_mode = 'chromosome';
        show_message("NOTE: '$command' is boundary-sensitive here — $chrom_reason.\n"
            . "  Running per whole chromosome (not arbitrary regions) for correctness.\n");
    }
}
# roh -O z writes BGZF-COMPRESSED text. The per-contig assembler is a plain-text
# header-stripping concatenator and cannot read a compressed chunk, so compressed
# roh runs directly. Uncompressed roh (-O s / -O r / default 'sr') assembles
# correctly in chromosome mode. This check is OUTSIDE the region-mode chain above
# because roh is classified 'chromosome', which that chain never sees.
if ($cmd_mode eq 'chromosome' && lc($command) eq 'roh') {
    my $ov = _opt_value($bcftools_args, 'O', 'output-type');
    if (defined $ov && $ov =~ /z/i) {
        $incompat_why = "'roh -O z' writes compressed text the per-contig assembler cannot concatenate";
        $cmd_mode = 'incompatible';
    }
}


# stats: single-input, site-only stats are section-additive (merged by
# plot-vcfstats -m). But per-sample stats (-s/-S) and two-file comparisons are
# NOT exactly reducible — plot-vcfstats merging approximates HWE and averages
# some per-sample metrics per chunk. Run those directly with bcftools.
if ($cmd_mode eq 'aggregate' && $command eq 'stats') {
    my @positional_inputs = map { $_->{value} } @{$input_scan->{operands}};
    if (_has_opt($bcftools_args, 's', 'S', 'samples', 'samples-file') || @positional_inputs >= 2) {
        $incompat_why = "'stats' with per-sample (-s/-S) or two-file input is not exactly mergeable by plot-vcfstats -m";
        $cmd_mode = 'incompatible';
    } elsif (_has_opt($bcftools_args, 'u', 'user-tstv')) {
        # plot-vcfstats -m does not carry the custom transition/transversion section
        # through the merge: `stats -u AF:0:1:10` emits two USR rows serially and NONE
        # after merging, at exit 0. Silently losing a whole section the user explicitly
        # asked for is worse than not parallelising it.
        $incompat_why = "'stats -u/--user-tstv' emits a USR section that plot-vcfstats -m "
                      . "cannot merge across regions";
        $cmd_mode = 'incompatible';
    }
}

# Multi-input (merge/isec) refinement: gVCF merge groups reference blocks across
# boundaries (needs whole-contig context, which the multi-input splitter can't do
# in v1), and isec -p/--prefix writes a multi-file directory. Run both directly.
if ($cmd_mode eq 'multi_input') {
    if ($mixed_input_passthrough) {
        $incompat_why = "'$command' mixes positional inputs with a -l/--file-list; "
            . "region-splitting can't discover contigs from both safely";
        $cmd_mode = 'incompatible';
    } elsif (_has_opt($bcftools_args, 'no-index', 'force-no-index')) {
        # --no-index/--force-no-index forbids -r/-R in bcftools, but the parallel
        # path injects a per-chunk -r into every worker. Run directly instead.
        $incompat_why = "'$command --no-index' forbids the per-region -r the parallel path injects";
        $cmd_mode = 'incompatible';
    } elsif ($command eq 'merge' && _has_opt($bcftools_args, 'g', 'gvcf')) {
        $incompat_why = "'merge --gvcf' groups reference blocks across region boundaries";
        $cmd_mode = 'incompatible';
    }
}


# Commands that write to stdout only (no -o support) — use shell redirect
my %STDOUT_CMD = map { $_ => 1 } qw(stats roh cnv);

# Output-family correction: stats/roh/cnv emit tabular TEXT (or a directory), never
# VCF/BCF — regardless of any -O flag. `roh -O z` is BGZF-compressed *text*, so the
# generic -O-based $is_vcf inference would wrongly send it to the VCF concat path.
$is_vcf = 0 if $STDOUT_CMD{lc($command)};

# INVARIANT K (output kind): the SHAPE of a command's output — 'vcf' (assembled by
# concat), 'text' (assembled by append) or 'dir' (one subdirectory per contig) —
# is resolved HERE, once, and every consumer uses this answer. The rule is
# genuinely per-subcommand and cannot be inferred from -O or the filename alone:
#   csq -Ot  -> text, despite a .vcf.gz name
#   isec     -> text for EVERY -O, unless -w/--write is given
#   cnv      -> a DIRECTORY, always
#   query    -> text in bcftools, ALWAYS. pbcftools does not yet model that: the
#               extension heuristic still infers 'vcf' from a .vcf/.bcf output name
#               and the run is then REFUSED ("Query command cannot output VCF/BCF
#               format") even though serial bcftools happily writes its table to
#               that name. Loud, never wrong output. See TODO-1 in the ledger.
# Asking this question separately in each consumer is what produced a BCF pushed
# through the text assembler, an isec sites list sent to VCF concat, and a cnv
# rerun that wrote flat serial files on top of per-contig directories.
my $output_kind = $is_vcf ? 'vcf' : 'text';

# `query -l` / `--list-samples` (incl. abbreviations like `--list-s`) lists the
# samples of the whole file: region-independent, prints to stdout. Route it to
# the direct-run path (_bcftools_passthrough handles the stdout redirect).
if (lc($command) eq 'query' && _has_flag($bcftools_args, 'l', 'list-samples')) {
    $cmd_mode = 'incompatible';
}

# Outputs that must NOT go through multi-chunk assembly (which opens, reopens,
# pre-cleans, and on failure unlinks the destination). Each is streamed/written by
# ONE bcftools process instead, preserving serial semantics:
#   * a stdout stream ('-', /dev/stdout, /dev/fd/1, or anything that IS fd 1) — the
#     assembler would write a literal file named '-', corrupt a pipe, or try to
#     unlink live stdout;
#   * a non-regular file (/dev/null, a FIFO, a device) — corrupt/block/delete;
#   * a symlink — pre-clean would unlink the link itself and leave its target stale,
#     whereas bcftools writes through it.
if (defined $ofile && _is_stdout_dest($ofile)) {
    $cmd_mode = 'incompatible';
    $incompat_why = "output '$ofile' is a stdout stream; running one bcftools process so the stream is not corrupted or pre-cleaned";
} elsif (defined $ofile && -l $ofile) {
    $cmd_mode = 'incompatible';
    $incompat_why = "output '$ofile' is a symlink; running one bcftools process so its target is not replaced by pre-clean";
} elsif (defined $ofile && -e $ofile && ! -f $ofile
         && !(lc($command) eq 'cnv' && -d $ofile)) {
    # `cnv` writes a DIRECTORY of per-sample files, so an existing directory at -o
    # is its normal rerun case, not a hazard. Without this exemption the guard
    # matched every rerun and silently dropped cnv to a single serial bcftools —
    # the parallelism promise held only on the very first run.
    $cmd_mode = 'incompatible';
    $incompat_why = "output '$ofile' is not a regular file; streaming it through a single bcftools process";
}

if ($cmd_mode eq 'incompatible') {
    # Whole-file / global-order commands can't be region-split. Like every other
    # non-parallelizable case, just run bcftools directly (transparent drop-in)
    # with the standardized notice — no separate confirmation prompt. Keep
    # "cannot be parallelized" in the reason so the run log states why.
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        $incompat_why // "'$command' cannot be parallelized by region (operates on whole-file structure or global order)"));
}

# The parallel path (region/chromosome/aggregate/multi_input) needs an explicit
# output file. Passthrough/incompatible commands have already exited above.
unless (defined $ofile) {
    croak("Please provide a bcftools output file (-o|--output)");
}

if ($cmd_mode eq 'aggregate') {
    show_message("NOTE: '$command' produces summary output. pbcftools will run per-region\n"
        . "  and merge results automatically.\n");
}
if ($cmd_mode eq 'chromosome') {
    show_message("NOTE: '$command' uses sequential algorithms. Splitting per-chromosome only.\n");
}
my %mi_contig_maxlen;   # multi-input: max contig length across all inputs (see below)
if ($cmd_mode eq 'multi_input') {
    croak("Command '$command' requires multiple input files.\n"
        . "  Use: pbcftools $command -l filelist.txt -o output ...\n"
        . "  Or:  pbcftools $command file1.vcf.gz file2.vcf.gz ... -o output ...")
        unless @input_files > 0;
    show_message(sprintf("NOTE: '$command' multi-input mode: %d files will be passed to each region chunk.\n",
        scalar @input_files));
    # Region discovery uses the FIRST input's contigs. That is only safe if every
    # input's contigs are a subset of the first's — otherwise records on a
    # later-only contig would be silently omitted (they'd never be in any chunk's
    # region). FAIL CLOSED on a contig-set mismatch rather than lose data. This
    # reads each input's index header (fast); merging per-sample VCFs against one
    # reference — the normal case — passes instantly.
    show_message("Checking input contig sets are consistent...\n");
    my $first = _file_contigs($input_files[0]);
    %mi_contig_maxlen = %$first;   # will hold the MAX length per contig across inputs
    my @unknown_len = grep { !$first->{$_} } keys %$first;   # length 0 = index reported '.'
    for my $f (@input_files[1 .. $#input_files]) {
        my $fc = _file_contigs($f);
        my @extra = grep { !exists $first->{$_} } keys %$fc;
        if (@extra) {
            @extra = sort @extra;
            croak("Multi-input contig mismatch: input\n    $f\n"
                . "  has contig(s) absent from the first input ("
                . join(", ", @extra[0 .. ($#extra < 4 ? $#extra : 4)]) . (@extra > 5 ? ", …" : "") . ").\n"
                . "  Their records would be omitted by region discovery. Ensure all inputs\n"
                . "  share the same reference/contigs, or merge them with bcftools directly.");
        }
        # Same-named contig with a LARGER length in a later file would otherwise
        # lose records beyond the first input's bound — take the max.
        for my $c (keys %$fc) {
            push @unknown_len, $c unless $fc->{$c};
            $mi_contig_maxlen{$c} = $fc->{$c} if $fc->{$c} > ($mi_contig_maxlen{$c} // 0);
        }
    }
    # If any input reports an UNKNOWN length (index '.') for a shared contig, we
    # cannot bound region discovery and could silently omit later records. --p_fai
    # is only an acceptable escape if it supplies a POSITIVE length for EVERY such
    # contig — and we must actually fold that length into the max used for region
    # discovery (get_chr_sizes gives the first VCF header priority over the FAI).
    if (@unknown_len) {
        my %fai;
        if (defined $pfai && length $pfai && open(my $fh, '<', $pfai)) {
            while (<$fh>) {
                my ($n, $l) = split /\t/;
                $fai{$n} = $l if defined $n && defined $l && $l =~ /^\d+$/ && $l > 0;
            }
            close $fh;
        }
        # Built-in human lengths (--p_ref 37|38|hg19|hg38) are an equally valid
        # escape and need no external file — the same source get_chr_sizes uses
        # for single-input. (The pre-07/23 code resolved multi-input lengths via
        # get_chr_sizes and so honored --p_ref; the consistency guard added later
        # must too, or --p_ref-only human merges wrongly fail closed.) Fail-closed
        # is preserved: only an AUTHORITATIVE external length (--p_fai or --p_ref)
        # may bound an unknown contig — a sibling file's own header length must
        # NOT, since that file whose length is unknown could hold records beyond
        # it (this is what the T39 guard checks).
        my $mi_has_chr = (grep { /^chr/i } keys %mi_contig_maxlen) ? 1 : 0;
        my $ref_len = _builtin_ref_lengths($pref, $mi_has_chr);
        my %u = map { $_ => 1 } @unknown_len;
        my @still;
        for my $c (sort keys %u) {
            my $len = $fai{$c} || $ref_len->{$c};
            if ($len) {
                $mi_contig_maxlen{$c} = $len if $len > ($mi_contig_maxlen{$c} // 0);
            } else {
                push @still, $c;
            }
        }
        if (@still) {
            croak("Multi-input: contig length is unknown (index reports '.') for: "
                . join(", ", @still[0 .. ($#still < 4 ? $#still : 4)]) . (@still > 5 ? ", …" : "") . ".\n"
                . "  Region discovery can't safely bound these, so later-file records\n"
                . "  beyond the first input might be omitted. Provide --p_ref 37|38 (human),\n"
                . "  --p_fai ref.fa.fai with a length for every such contig, add ##contig\n"
                . "  length headers, or merge directly with bcftools.");
        }
    }
    show_message("  contig sets consistent (names subset first input; using max lengths).\n");
}
if ($is_vcf && $command eq "query") {
    croak("Query command cannot output VCF/BCF format.");
}

# Input file checks
(-e $ifile) or croak("Input file '$ifile' not found.");

#=================================================================================================
# Normalize region options before building the worker command
#=================================================================================================

# (-R/--regions-file was already passed through earlier. -t/-T targets are
# compatible and pass through — they filter within each chunk by POS, which
# composes correctly with the per-chunk -r we inject.)
#
# --regions-overlap policy. Per the bcftools manual, the default for -r/-R is
# `record` (1): a record is matched if it OVERLAPS the region even when its POS
# is outside (before) it — so an indel starting before the region and spanning
# in is included. pbcftools reproduces this by giving the FIRST chunk of each
# region the user's (or default `record`) overlap at its outer-left edge, while
# INTERNAL chunks use `pos` so each record lands in exactly one chunk (no dup).
# Capture the user's value (exact match — `--regions` must not be confused with
# `--regions-overlap`) and strip it; we re-inject the right value per chunk.
my $user_overlap;
{
    my @kept; my $skip = 0;
    for my $i (0 .. $#$bcftools_args) {
        if ($skip) { $skip = 0; next; }
        my $a = $bcftools_args->[$i];
        # `--regions-o...` (any abbreviation from --regions-o to --regions-overlap)
        # uniquely identifies --regions-overlap (--regions-file is --regions-f...,
        # --regions is exact). bcftools accepts such abbreviations.
        if ($a =~ /^--regions-o[a-z]*$/ && defined $bcftools_args->[$i+1]) {
            $user_overlap = $bcftools_args->[$i+1]; $skip = 1; next;
        } elsif ($a =~ /^--regions-o[a-z]*=(.+)$/) {
            $user_overlap = $1; next;
        }
        push @kept, $a;
    }
    $bcftools_args = \@kept;
}
# `variant` (2) overlap can EXCLUDE a record whose POS is inside the region (an
# edge anchor base), so per-chunk POS ownership would diverge from serial. If the
# user asked for variant overlap WITH a -r restriction, pass through.
if (defined $user_overlap && $user_overlap =~ /^(?:variant|2)$/i
    && grep { /^-r/ || /^--regions(?:$|=)/ } @$bcftools_args) {
    # re-inject the stripped overlap so bcftools sees the user's exact request
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        "-r with --regions-overlap variant can't be tiled exactly"));
}

#=================================================================================================
# Validate bcftools command (dummy region test)
#=================================================================================================

# Reconstruct bcftools args (excluding command name)
# Positional input files (if multi_input) were already stripped from $bcftools_args above
my @cmd_args = @{$bcftools_args}[1..$#$bcftools_args];

my $bcftools_cmd = join(" ", map { shq($_) } @cmd_args);

# Region-stripped args for VALIDATION ONLY. Validation injects a dummy
# `-r __NOEXIST__:1-1`; if the user's own -r/-R stays in the command it wins under
# bcftools last-option-wins and validation would serially process the real region.
# (The parallel worker path re-derives its own region handling separately.)
my $val_bcftools_cmd = do {
    my (@va, $sk);
    for my $a (@cmd_args) {
        if ($sk)                            { $sk = 0; next; }
        if ($a =~ /^(?:-r|--regions)$/)     { $sk = 1; next; }   # -r VALUE / --regions VALUE
        next if $a =~ /^--regions=/;                             # --regions=VALUE
        next if $a =~ /^-r.+$/;                                  # attached -rVALUE
        next if $a =~ /^-R/;                                     # -R / -RFILE
        next if $a =~ /^--regions-f[a-z]*(?:$|=)/;               # --regions-file[=...]
        push @va, $a;
    }
    join(" ", map { shq($_) } @va);
};

my $full_cmd = "bcftools $command $bcftools_cmd -o " . shq($ofile);
show_message("Command: $full_cmd\n");

# Validate by running on a nonexistent region — exercises argument parsing
# Skip validation for multi_input: opening all N files just for validation is too expensive
if ($cmd_mode eq 'multi_input') {
    show_message("Skipping validation (multi-input: opening all files would be too slow).\n");
} else {
    # -o before the passthrough args (so it precedes any plugin `--`); stdout
    # commands redirect at the end.
    # `cnv` is in %STDOUT_CMD only because its output is not VCF; it does NOT write
    # to stdout — it REQUIRES `-o DIR` and exits non-zero without one. Give the
    # validation probe a throwaway directory (the dummy region matches no records,
    # so nothing is written into it).
    my ($val_out_opt, $val_redir);
    my $val_cnv_dir;
    if (lc($command) eq 'cnv') {
        $val_cnv_dir = tempdir(CLEANUP => 1);
        $val_out_opt = "-o " . shq($val_cnv_dir);
        $val_redir   = " > /dev/null";
    } else {
        $val_out_opt = $STDOUT_CMD{$command} ? "" : "-o /dev/null";
        $val_redir   = $STDOUT_CMD{$command} ? " > /dev/null" : "";
    }
    # The probe writes to /dev/null, so an auto-index request (-W / --write-index)
    # would try to create "/dev/null.csi" and fail — rejecting `view ... -W`, an
    # ordinary command that works serially. Drop it from the PROBE only: pbcftools
    # indexes the published output itself, so the user's intent is still met.
    my $val_probe_cmd = $val_bcftools_cmd;
    $val_probe_cmd =~ s/(?:^|\s)--write-index(?:=\S+)?(?=\s|$)/ /g;
    $val_probe_cmd =~ s/(?:^|\s)-W(?:=\S+)?(?=\s|$)/ /g;
    my $validate_cmd = "bcftools $command -r __NOEXIST__:1-1 --regions-overlap pos $val_out_opt $val_probe_cmd$val_redir 2>&1";
    show_message("\nValidating bcftools arguments...\n");
    my $validate_out = `$validate_cmd`;
    my $validate_raw = $?;
    my $validate_rc  = wait_status_exit($validate_raw);   # signal-killed != success
    # Abnormal termination (exec failure or a killed process) is NEVER benign, even
    # if the captured output happens to contain the expected dummy-region diagnostic.
    my $validate_abnormal = ($validate_raw == -1) || ($validate_raw & 127);

    my @validate_lines = split(/\n/, $validate_out);

    # EXIT STATUS is authoritative. Many valid commands print normal diagnostics
    # to stderr while succeeding (e.g. `call --gvcf` prints a diploid-assumption
    # notice; default `csq` prints GFF parse/index info). Treating that text as
    # fatal would reject valid work — so we do NOT. We fail only on a nonzero exit
    # that is not the expected "no such contig" from our dummy region. Invalid
    # arguments/expressions already exit nonzero, so they are still caught.
    my $benign_rc = !$validate_abnormal
        && grep { /no such contig|could not parse region/i } @validate_lines;
    if ($validate_rc != 0 && !$benign_rc) {
        show_message("ERROR: bcftools argument validation failed (exit $validate_rc):\n"
            . join("\n", @validate_lines) . "\n");
        exit(1);
    }
    # Surface any stderr as non-fatal diagnostics for the run log.
    my @diag = grep { $_ !~ /no such contig|could not parse region|^\s*$|^Lines\s+total|^\s+\(the command/i } @validate_lines;
    if (@diag) {
        show_message("bcftools diagnostics during validation (non-fatal, exit $validate_rc):\n");
        show_message("  $_\n") for @diag;
    }
    show_message("Arguments validated.\n");
}

#=================================================================================================
# Output overwrite check — LAST preflight step, so a rejected command (unknown
# command, -R refusal, failed validation) never destroys an existing output.
#=================================================================================================

# Confirm overwrite, but do NOT delete the existing output yet: assembly writes
# (concat -o / stats redirect / text move) all truncate-or-replace it at the end,
# so deleting now would destroy a valid previous result if the run fails during
# any later preflight step (region discovery, backend construction, ...).
if (-e $ofile && !$pyes && !get_user_confirmation("$ofile already exists. Overwrite it?")) {
    croak("Operation cancelled.");
}

#=================================================================================================
# Individual bcftools thread guard
#=================================================================================================

# Check for --threads in bcftools args
my $user_threads;
for my $i (0 .. $#$bcftools_args) {
    if ($bcftools_args->[$i] =~ /^--threads[=]?(\d+)?$/) {
        $user_threads = $1 // $bcftools_args->[$i+1];
        last;
    }
}
if ($user_threads) {
    if ($pmode eq 'local') {
        # Local: all workers share this machine's cores.
        my $ncpu = detect_ncpu();
        my $effective_jobs = $pjobs || (int($ncpu / 2) || 1);
        my $total = $user_threads * $effective_jobs;
        warn sprintf("WARNING: local mode: %d workers x %d threads = %d, exceeding %d cores.\n"
            . "  Lower --threads or --p_jobs to avoid oversubscription.\n",
            $effective_jobs, $user_threads, $total, $ncpu) if $total > $ncpu;
    } else {
        # LSF/Slurm: each job is allocated --p_cpu cores on a compute node; the
        # controller's core count (detect_ncpu) is irrelevant. --threads above
        # --p_cpu oversubscribes a single job's allocation.
        warn sprintf("WARNING: %s mode: bcftools --threads %d exceeds --p_cpu %d (cores per job).\n"
            . "  Raise --p_cpu to >= %d, or lower --threads, to avoid oversubscription.\n",
            uc($pmode), $user_threads, $pcpu, $user_threads) if $user_threads > $pcpu;
    }
}

#=================================================================================================
# Prepare parallel options
#=================================================================================================

# Temp directory
my $auto_tmp = 0;   # 1 if pbcftools created the temp dir itself (safe to clean on success)
# Set once the result has been published to -o. Until then a signal must PRESERVE
# $pdir (the chunk outputs and .err logs are the only record of what went wrong);
# after it, the staging dir is pure garbage and may be very large.
my $pdir_publishable = 0;
my $explicit_pdir = defined $pdir;
my $run_nonce;
if (defined $pdir) {
    # NEVER recursively delete a user-supplied directory — `--p_dir . --p_yes` or a
    # --p_dir pointing at a data/results dir would destroy it. Require the dir to
    # be new or already empty; refuse a non-empty existing tree.
    if (-e $pdir) {
        croak("--p_dir '$pdir' exists and is not a directory.") unless -d $pdir;
        opendir(my $dh, $pdir) or croak("Cannot read --p_dir '$pdir': $!");
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir($dh);
        # Retained run-private children from a same-prefix invocation are safe:
        # every new controller creates another exclusive nonce child below this
        # parent. Refuse unrelated contents to preserve the established guard
        # against accidentally selecting a data/results directory.
        my @unrelated = grep {
            $_ !~ /^\Q${ppre}_\E[A-Za-z0-9._-]+$/
                || !-d File::Spec->catdir($pdir, $_)
        } @entries;
        croak("--p_dir '$pdir' is not empty. Refusing to reuse it (pbcftools will not "
            . "delete an existing directory). Pass a new or empty --p_dir.") if @unrelated;
    } else {
        make_path($pdir) or croak("Cannot create '$pdir': $!");
    }
    $pdir = File::Spec->rel2abs($pdir);
} else {
    $pdir = tempdir(CLEANUP => 0);
    $auto_tmp = 1;
}

# Every explicit --p_dir is a user-owned parent, not the artifact directory itself.
# A nonce-named child is created atomically with mkdir, so concurrent local or
# cluster controllers cannot share lists, chunks, scripts, sentinels, or logs.
# The default local tempdir remains unchanged and is removed after success.
if ($explicit_pdir) {
    require PBCFTools::Backend::Cluster;
    $run_nonce = PBCFTools::Backend::Cluster::_gen_nonce();
    $pdir = PBCFTools::Backend::Cluster::_make_run_dir($pdir, $ppre, $run_nonce);
}

# Disk space check: warn if less than 2x total input size available.
# For multi-input (merge/isec) the temp usage scales with all inputs, not just
# the first, so sum them.
{
    my $isize = 0;
    if (@input_files) {
        $isize += (-s $_ || 0) for @input_files;
    } else {
        $isize = -s $ifile || 0;
    }
    my $min_free = $isize * 2;
    my $df_out = `df -P @{[ shq($pdir) ]} 2>/dev/null | tail -1`;
    if ($df_out =~ /\S+\s+\S+\s+\S+\s+(\d+)/) {
        my $avail_kb = $1;
        my $avail_bytes = $avail_kb * 1024;
        if ($avail_bytes < $min_free) {
            my $avail_gb = sprintf("%.1f", $avail_bytes / 1e9);
            my $need_gb  = sprintf("%.1f", $min_free / 1e9);
            show_message("WARNING: Only ${avail_gb}GB free on temp dir ($pdir), recommend at least ${need_gb}GB (2x input).\n");
            unless ($pyes || get_user_confirmation("Continue anyway?")) {
                croak("Operation cancelled: insufficient disk space.");
            }
        }
    }
}

# Parse plen
my $plen_int = convert_length_to_integer($plen);
if ($plen_int && $plen_int > 0) {
    $plen = $plen_int;
} else {
    warn "Invalid block length '$plen', using default (10MB).\n";
    $plen = 10_000_000;
}

# Parse walltime and memory for cluster backends. LSF and Slurm use different
# time/memory string formats, so format per backend (see Helpers.pm):
#   LSF   -W  => H:MM        --mem-equivalent -M => "8GB"
#   Slurm --time => HH:MM:SS  --mem            => "8G"
# Only cluster backends use walltime/memory. FAIL CLOSED on an unparseable value:
# the formatters return a safe canonical string (digits/colons only) or undef, so
# retaining the *original* string on failure would let a payload like
# `--p_wal '1h; touch X #'` reach the scheduler shell command. Never fall back to
# the raw input.
if ($pmode eq 'lsf' || $pmode eq 'slurm') {
    my ($fw, $fm);
    if ($pmode eq 'slurm') {
        $fw = format_walltime_slurm($pwal);
        $fm = format_memory_slurm($pmem);
    } else {
        $fw = format_walltime_lsf($pwal);
        $fm = format_memory_lsf($pmem);
    }
    croak("Invalid --p_wal '$pwal' for --p_mode $pmode (use e.g. 1hr, 30min, 2:00, 01:30:00).")
        unless defined $fw && length $fw;
    croak("Invalid --p_mem '$pmem' for --p_mode $pmode (use e.g. 8GB, 512MB).")
        unless defined $fm && length $fm;
    $pwal = $fw;
    $pmem = $fm;

    # Positive-integer guards for numeric controls that flow into the scheduler
    # command (GetOptions enforces integer-ness via =i, but not sign/zero).
    for my $ctl (['--p_cpu', $pcpu], ['--p_int', $pint], ['--p_try', $ptry]) {
        my ($nm, $v) = @$ctl;
        croak("$nm must be a positive integer (got '$v').") if defined $v && $v < 1;
    }
}

#=================================================================================================
# Step 1. Get chromosome sizes and split jobs
#=================================================================================================

my ($chrs, $chr_len, $chr_nvar, $region_len) = get_chr_sizes($ifile, $pref, $pfai);

# Multi-input: a later file may declare a longer length for a shared contig.
# Region discovery uses the first input's lengths, so raise each to the max seen
# across all inputs (computed during the contig-consistency check) — otherwise
# records beyond the first input's bound would be omitted.
if (%mi_contig_maxlen) {
    for my $c (@$chrs) {
        $chr_len->{$c} = $mi_contig_maxlen{$c}
            if defined $mi_contig_maxlen{$c} && $mi_contig_maxlen{$c} > ($chr_len->{$c} // 0);
    }
}

# Detect an inline user -r/--regions (a -R file was passed through earlier).
# bcftools uses LAST-option-wins for repeated -r, so keep the last value.
my $user_region;
for my $i (0 .. $#$bcftools_args) {
    my $a = $bcftools_args->[$i];
    if ($a =~ /^(?:-r|--regions)$/ && defined $bcftools_args->[$i+1]) { $user_region = $bcftools_args->[$i+1]; }
    elsif ($a =~ /^--regions=(.+)$/) { $user_region = $1; }
    elsif ($a =~ /^-r(.+)$/)         { $user_region = $1; }   # attached short: -r1:1-1000000
}

# Overlap for the FIRST chunk of each region (its outer-left edge): the user's
# choice if they asked for `pos` (POS must be inside), otherwise bcftools' default
# `record` (include records spanning in from before). Internal chunks always use
# `pos`. `variant` was already passed through above.
my $first_overlap = (defined $user_overlap && $user_overlap =~ /^(?:pos|0)$/i) ? 'pos' : '';

my @regions;             # genome-wide path: [chr,start,end] tuples (sub-split by plen)
my $user_contig_jobs;    # user -r path: arrayref of per-contig region STRINGS
my $whole_chrom = ($cmd_mode eq 'chromosome') ? 1 : 0;

if (defined $user_region) {
    # Strip the user's -r/--regions from the args (each worker gets its own -r).
    my (@kept, $skip);
    for my $i (0 .. $#$bcftools_args) {
        if ($skip) { $skip = 0; next; }
        my $a = $bcftools_args->[$i];
        if ($a =~ /^(?:-r|--regions)$/) { $skip = 1; next; }   # -r VALUE / --regions VALUE
        next if $a =~ /^--regions=/;                            # --regions=VALUE
        next if $a =~ /^-r.+$/;                                 # attached short -rVALUE
        push @kept, $a;
    }
    $bcftools_args = \@kept;
    $bcftools_cmd  = join(" ", map { shq($_) } @{$bcftools_args}[1..$#$bcftools_args]);

    # Parse the user's regions into [chr,start,end] tuples, preserving contig
    # order of first appearance. bcftools region grammar (distinct forms!):
    #   chr          -> whole contig [1, len]
    #   chr:pos      -> single position [pos, pos]
    #   chr:beg-     -> from beg to contig end [beg, len]
    #   chr:beg-end  -> [beg, end] (end clamped to contig len)
    my (%by_c, @order, %render_of);
    for my $reg (split /,/, $user_region) {
        # {name}[:...] lets a contig name contain ':'. Keep the AS-WRITTEN contig
        # token ($cbr, braces included) for the worker -r; strip braces only for
        # the length lookup.
        my ($cbr, $rest);
        if    ($reg =~ /^(\{[^}]*\})(?::(.*))?$/) { ($cbr, $rest) = ($1, $2); }
        elsif ($reg =~ /^([^:]+)(?::(.*))?$/)     { ($cbr, $rest) = ($1, $2); }
        # NEVER silently skip a component: a typo would drop the data the user asked
        # for and report success. Fail closed with a clear message instead.
        else { croak("Cannot parse region '$reg' in -r/--regions. Fix it, or run bcftools directly."); }
        (my $c = $cbr) =~ s/^\{//; $c =~ s/\}$//;   # bare name for lookup
        unless (exists $chr_len->{$c}) {
            # Not record-bearing in this input. If it is a VALID contig — declared
            # in the header, or a known --p_fai/--p_ref reference contig — it is not a
            # typo: it is simply empty here (or, for multi-input merge, may carry
            # records only in a LATER file). Allow it, bounded by its resolved
            # length, so any records present are captured and none silently dropped.
            if (defined $region_len->{$c} && $region_len->{$c} > 0) {
                $chr_len->{$c}  = $region_len->{$c};
                $chr_nvar->{$c} //= 0;
            } else {
                # In NEITHER the index nor the header/--p_fai/--p_ref: a genuine typo
                # (or a contig with no determinable length). Fail closed.
                croak("Region '$reg' refers to contig '$c', which is not in the input "
                    . "(known contigs: " . join(", ", @{$chrs}) . "). "
                    . "A typo here would silently drop data. If '$c' is a real but empty\n"
                    . "  contig, add its ##contig header length or pass --p_ref/--p_fai; "
                    . "otherwise fix the region, or run bcftools directly.");
            }
        }
        my ($s, $e);
        if    (!defined $rest || $rest eq '') { ($s,$e) = (1, $chr_len->{$c}); }   # whole contig
        elsif ($rest =~ /^(\d+)-(\d+)$/)      { ($s,$e) = ($1, $2); }              # beg-end
        elsif ($rest =~ /^(\d+)-$/)           { ($s,$e) = ($1, $chr_len->{$c}); }  # beg-  (to end)
        elsif ($rest =~ /^(\d+)$/)            { ($s,$e) = ($1, $1); }              # single position
        else { croak("Cannot parse the position part of region '$reg' in -r/--regions. Fix it, or run bcftools directly."); }
        $e = $chr_len->{$c} if $e > $chr_len->{$c};
        # Group by the CANONICAL bare contig name, not the as-written spelling:
        # `1` and `{1}` name the SAME contig, and keying on the literal token made
        # them two independent groups whose intervals then overlapped, emitting
        # duplicate records (and, for roh, restarting the HMM on one contig).
        # Keep the first spelling seen for this contig to render the worker -r.
        $render_of{$c} = $cbr unless exists $render_of{$c};
        push @order, $c unless exists $by_c{$c};
        push @{$by_c{$c}}, [$render_of{$c}, $s, $e];
    }

    # Grouping rule. A record can overlap two intervals on the SAME contig, and a
    # single bcftools call deduplicates them; the wrapper must not. Also, bcftools
    # processes contigs in the order they appear in -r, so the job order must
    # follow @order. Therefore: if ANY contig has multiple intervals (or the
    # command is boundary-sensitive), coalesce EVERY contig into one ordered worker
    # (default overlap, no sub-split) — no duplication, order preserved. Only when
    # all contigs have a single interval AND the command is region-safe do we
    # sub-split each for parallelism (first-chunk overlap captures spanning records).
    my $any_multi = grep { @{$by_c{$_}} > 1 } @order;
    if ($cmd_mode eq 'chromosome' || $any_multi) {
        $user_contig_jobs = [ map { join(",", map { "$_->[0]:$_->[1]-$_->[2]" } @{$by_c{$_}}) } @order ];
        show_message(sprintf("User region '%s' — %d contig worker(s) (coalesced, order preserved).\n",
            $user_region, scalar @$user_contig_jobs));
    } else {
        @regions = map { @{$by_c{$_}} } @order;
        show_message(sprintf("User region '%s' — sub-splitting %d interval(s) for parallelism.\n",
            $user_region, scalar @regions));
    }
} else {
    # Genome-wide: one tuple per contig (sub-split by plen unless whole-chrom mode).
    @regions = map { [$_, 1, $chr_len->{$_}] } @{$chrs};
    show_message("Chromosome mode: one worker per contig (no sub-splitting).\n") if $whole_chrom;
}

my $jobs = bcftools_split_jobs($command, $bcftools_cmd, $ifile, $ofile, $pdir, $ppre, $plen, \@regions,
    ($cmd_mode eq 'multi_input' ? \@input_files : undef), $whole_chrom, $user_contig_jobs, $first_overlap);
my $n = scalar @{$jobs};

# Guard: no jobs means the requested region matched no contigs in the input.
# Fail clearly here rather than later with a confusing "concat 0 files" error.
if ($n == 0) {
    croak("No regions to process — nothing to run.\n"
        . ($user_region
            ? "  Region '$user_region' matches no contigs in the input.\n"
            : "  The input has no usable contigs.\n")
        . "  Input contigs: " . join(", ", @{$chrs}) . "\n");
}

# One chunk means there is nothing to parallelize: the single region unit already
# covers the whole requested scope, so plain bcftools with the ORIGINAL arguments
# produces exactly the same result (same region, same default overlap — a lone
# chunk is the "first chunk", which never gets --regions-overlap injected). Run it
# directly and exit, behaving like bcftools, and remove the private run dir we
# created before splitting so the passthrough leaves nothing behind. This also
# means a single chunk never needs `plot-vcfstats -m` for 'stats' (which rejects a
# lone input) or a concat/merge of one file.
# INVARIANT K: a 'dir'-kind output must NOT take this shortcut. bcftools cnv writes
# sample-named files FLAT into -o, whereas the parallel path writes one
# subdirectory per contig — a structurally different layout at the same path. A
# restricted rerun (e.g. `-r 1` over a directory built by a full run) therefore
# dropped flat files on top of stale per-contig directories and exited 0. With one
# chunk the parallel path costs nothing and keeps the layout consistent.
if ($n == 1) {
    remove_tree($pdir) if -d $pdir;   # $pdir is always a dir we created (temp, or a nonce child of --p_dir)
    exit(_bcftools_passthrough($orig_bcftools_args, $ofile, $command,
        "only one region chunk (no parallelism to gain)"));
}

show_message(sprintf("Split into %d jobs (plen=%s)\n", $n, _format_bp($plen)));

#=================================================================================================
# Step 2. Create backend and signal handler
#=================================================================================================

my $backend;

if ($pmode eq 'lsf') {
    require PBCFTools::Backend::LSF;
    croak("--p_jobs is required for LSF mode (--p_mode lsf)") unless $pjobs;
    $backend = PBCFTools::Backend::LSF->new(
        pjobs    => $pjobs,
        ppre     => $ppre,
        pwal     => $pwal,
        pmem     => $pmem,
        pcpu     => $pcpu,
        pint     => $pint,
        ptry     => $ptry,
        pqueue   => $pqueue,
        paccount => $paccount,
        pdir     => $pdir,           # wave scripts/outputs live here (shared FS)
        nonce    => $run_nonce,
        pmem_inc => $pmem_inc,       # % memory bump per retry
        pwal_inc => $pwal_inc,       # % wall-time bump per retry
    );
} elsif ($pmode eq 'slurm') {
    require PBCFTools::Backend::Slurm;
    croak("--p_jobs is required for Slurm mode (--p_mode slurm)") unless $pjobs;
    $backend = PBCFTools::Backend::Slurm->new(
        pjobs    => $pjobs,
        ppre     => $ppre,
        pwal     => $pwal,
        pmem     => $pmem,
        pcpu     => $pcpu,
        pint     => $pint,
        ptry     => $ptry,
        pqueue   => $pqueue,
        paccount => $paccount,
        pdir     => $pdir,           # wave scripts/outputs live here (shared FS)
        nonce    => $run_nonce,
        pmem_inc => $pmem_inc,       # % memory bump per retry
        pwal_inc => $pwal_inc,       # % wall-time bump per retry
    );
} else {
    require PBCFTools::Backend::Local;
    $backend = PBCFTools::Backend::Local->new(
        pjobs     => $pjobs,
        nchunks   => $n,               # never auto-detect more workers than chunks
        fail_stop => ($pyes ? 0 : 1),  # --p_yes disables fail-stop prompt
    );
}

# Update pjobs from backend (may have been auto-detected)
$pjobs = $backend->pjobs();

my $wnote = $backend->can('pjobs_note') ? $backend->pjobs_note : undef;
show_message(sprintf("Mode: %s | Jobs: %d | Workers: %d%s | Dir: %s\n",
    uc($pmode), $n, $pjobs, ($wnote ? " ($wnote)" : ""), $pdir));

# Signal handler: clean up on Ctrl-C
my $signal_cleanup = sub {
    my ($sig) = @_;
    warn "\nCaught SIG$sig, cleaning up...\n";
    $backend->cleanup() if $backend;
    # A signal that lands AFTER the result is safely published leaves nothing in
    # the staging dir worth keeping — and $pdir can hold tens of GB for a
    # whole-genome run, so exiting without this leaked it. Chunk outputs are still
    # preserved for every FAILURE path; $pdir_publishable is only ever set once
    # publication has succeeded.
    if ($pdir_publishable && $auto_tmp && defined $pdir && -d $pdir) {
        remove_tree($pdir);
    }
    exit(128 + ($sig eq 'INT' ? 2 : $sig eq 'TERM' ? 15 : 1));
};
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = $signal_cleanup;

# Run a publication step with INT/TERM/HUP DEFERRED, then deliver any signal that
# arrived. Publication is the one window where the user's real output is being
# replaced: a signal landing between "move the data" and "move its index", or
# part-way through cnv's per-contig moves, leaves the destination internally
# inconsistent (new data + stale index, or a partial contig set). These steps are
# renames, so deferring costs nothing in practice; the cleanup handler still runs
# immediately afterwards.
# The closure receives a predicate it can call to ask "has a signal arrived?". It
# should call that immediately before the FIRST operation that mutates the user's
# path and give up if the answer is yes: deferring blindly meant a SIGTERM during a
# long cross-device copy still went on to replace the destination and then exited
# 143 — an interrupted run that changed pre-existing output, which the release rule
# forbids. Once the swap itself has begun there is no way back, so the guarantee is
# "either entirely the old content or entirely the new, never partial" (see the
# ledger's L9), and the check keeps the abort window as wide as it can be.
sub _with_signals_deferred {
    my ($code) = @_;
    my $pending;
    local $SIG{INT} = local $SIG{TERM} = local $SIG{HUP} = sub { $pending = $_[0] };
    my @r = eval { $code->(sub { defined $pending }) };
    my $err = $@;
    if (defined $pending) {
        # $signal_cleanup exits, so a real failure inside the block would vanish
        # behind "Caught SIGTERM" — telling the operator the run was interrupted
        # when in fact the destination was unwritable. Report the cause first.
        warn $err if $err;
        # NOTE: $pdir_publishable is NOT set here. Only the closure knows whether it
        # actually finished publishing, and staging must survive if it did not.
        $signal_cleanup->($pending);         # exits
    }
    die $err if $err;
    return wantarray ? @r : $r[0];
}

#=================================================================================================
# Step 3. Run jobs
#=================================================================================================

my $time1 = strftime("%Y-%m-%d %H:%M:%S", localtime());
show_message("\n========== Start: $time1 ==========\n");

# Post-processing callback
my $current = 0;
my $header  = "";

# `query` text output has NO header lines on the parallel path (query -H passes
# through above). Every line is data — which may legitimately start with '#'
# (e.g. `-f '#%CHROM\t%POS\n'`) — so concatenate all lines with no stripping.
my $text_hdr_lines;
# Text output is assembled INTO A RUN-PRIVATE STAGING FILE and only renamed onto
# the user's -o once every chunk has been verified. Appending straight to $ofile
# published a partial, plausible-looking result: a SIGTERM mid-run left 69k of
# 615k lines sitting at the requested path (VCF never had this — concat writes
# $ofile in one step at the end).
my $text_stage = File::Spec->catfile($pdir, 'para_text_assembly.out');
$text_hdr_lines = 0 if $command eq 'query';

my $on_complete = sub {
    my ($all_jobs, $job) = @_;
    my $j = scalar @{$all_jobs};

    if ($cmd_mode eq 'aggregate' || $output_kind ne 'text') {
        # Aggregate (stats), VCF/BCF, and cnv (whose "output" is a per-contig
        # DIRECTORY, never a tab file — it must NOT reach append_tab_file): just
        # verify the chunk output exists; assembly order does not matter here.
        my $f = $job->{file};
        if (!(-e $f && -s $f)) {
            warn "WARNING: Output file missing or empty for $job->{name}: $f\n";
        }
        $current++;
    } else {
        # Text: sequential append (must process in order). A failure here
        # (header/column mismatch, I/O error) must FAIL the run — mark the job
        # failed so the fail-closed check aborts, not just warn and continue.
        until ($current >= $j || ($all_jobs->[$current]->{status} // '') ne 'completed') {
            my $cf = $all_jobs->[$current]->{file};
            my $ok = eval { $header = append_tab_file($text_stage, $cf, $header, $text_hdr_lines); 1 };
            unless ($ok) {
                $all_jobs->[$current]->{status} = 'failed';
                warn "ERROR assembling text output for $all_jobs->[$current]->{name}: "
                    . ($@ || 'unknown error') . "\n";
                last;
            }
            $current++;
        }
    }
};

# Remove any pre-existing output + stale index NOW — after all preflight, right
# before workers run (the text path's on_complete appends to $ofile as chunks
# finish, and needs it absent for the first chunk's move). Doing it here, not in
# preflight, means a failure during validation/region-discovery/backend setup
# never destroyed a valid previous result.
# Only a REGULAR file is pre-cleaned; a non-regular output (/dev/null, /dev/stdout,
# a FIFO) is written in place by bcftools and must not be unlinked.
# NOTE: the destination is NOT pre-cleaned. It used to be removed here because the
# text path appended straight to $ofile, but text now assembles in $pdir, so every
# output family is staged and published at the end. Deleting up front meant an
# interrupt (or any later failure) destroyed the user's previous VALID result and
# left nothing in its place. Replacement now happens at publish time only.
my $publish_stage = File::Spec->catfile($pdir, 'para_publish.out');
sub _publish_output {
    # $drop_index: remove the replaced output's stale .csi/.tbi. Only an INDEXABLE
    # output (VCF/BCF) has them; for a text result (stats, roh) a same-named .csi
    # belongs to something else entirely, and deleting it destroyed an unrelated
    # user file on an otherwise successful run.
    # $abort: optional predicate, re-checked immediately before the destination is
    # mutated. A cross-device publish COPIES first, which for a whole-genome result
    # takes minutes; checking only before the call meant a SIGTERM arriving during
    # the copy was deferred and the rename went ahead anyway, replacing the user's
    # previous output on an interrupted run. Returns 'ABORTED' (truthy, so callers'
    # `or croak` does not fire) after removing its own scratch file.
    my ($src, $dst, $drop_index, $abort) = @_;
    return 0 unless defined $src && -e $src;
    return 'ABORTED' if $abort && $abort->();     # nothing touched yet
    unless (rename($src, $dst)) {          # atomic within a filesystem
        # Cross-device: copy to a SIBLING of the destination first, so a failure
        # or signal never leaves a half-written file at the user's path.
        # CLAIM the scratch name ATOMICALLY. File::Copy::copy() overwrites its
        # destination and the failure path then unlinks it, so a fixed
        # "$dst.pbcf.$$" destroyed a pre-existing file of that name — a leftover
        # from a crashed run that reused the PID, or the user's own file. A
        # `!-e $cand` test first is not enough either: that is check-then-use, and
        # an external writer can win the gap between the test and the copy, after
        # which we would still overwrite and rename away their file. O_CREAT|O_EXCL
        # closes the gap in one syscall.
        require Fcntl;
        require File::Copy;
        my ($tmp, $tfh);
        for my $i (0 .. 999) {
            my $cand = "$dst.pbcf.$$.$i";
            if (sysopen($tfh, $cand, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600)) {
                $tmp = $cand;
                last;
            }
        }
        return 0 unless defined $tmp;    # errno from the last sysopen attempt
        # Save errno BEFORE the cleanup unlink: every caller interpolates $! into
        # its croak, and the unlink overwrote the real cause (a read-only
        # destination was reported as "No such file or directory").
        File::Copy::copy($src, $tfh)
            or do { my $e = $!; close($tfh); unlink $tmp; $! = $e; return 0 };
        close($tfh)        or do { my $e = $!; unlink $tmp; $! = $e; return 0 };
        # The O_EXCL claim above deliberately creates the scratch file 0600 so that a
        # half-copied result is never briefly world-readable. Restore the staged
        # file's own mode before publishing, or a cross-device run would hand the
        # user a 0600 output where both serial bcftools and the same-filesystem path
        # give 0644 — an exit-0 metadata difference between the two publish routes.
        my $smode = (stat($src))[2];
        chmod(($smode & 07777), $tmp) if defined $smode;
        # RE-CHECK. The copy above can run for minutes on a whole-genome result, and
        # the destination has not been touched yet, so a signal that arrived during it
        # must stop us here rather than be honoured only after we have replaced the
        # user's previous output. Remove our own scratch file on the way out.
        if ($abort && $abort->()) { unlink $tmp; return 'ABORTED' }
        rename($tmp, $dst) or do { my $e = $!; unlink $tmp; $! = $e; return 0 };
        unlink($src);
    }
    if ($drop_index) {
        unlink("$dst.csi") if -e "$dst.csi";    # stale index of the replaced output
        unlink("$dst.tbi") if -e "$dst.tbi";
    }
    return 1;
}



# Timing for the end-of-run summary. times() reports CUMULATIVE child CPU in the
# parent, so a delta across the dispatch step costs nothing and covers every worker
# whichever backend ran them.
my ($t_index_begin, $t_index, $t_assemble);
my $t_jobs_begin = time();
my @cpu_begin    = times();
$backend->run_jobs($jobs, $on_complete);
my @cpu_end      = times();
my $t_jobs_end   = time();
my $jobs_wall    = $t_jobs_end - $t_jobs_begin;
my $jobs_cpu     = ($cpu_end[2] + $cpu_end[3]) - ($cpu_begin[2] + $cpu_begin[3]);


#=================================================================================================
# Step 3b. Fail closed: never assemble partial output.
#=================================================================================================
# If any chunk did not complete (failed, or never dispatched under fail-stop),
# abort without writing a merged result. Partial genomic output would silently
# omit whole regions — a scientific hazard worse than a hard failure. The temp
# dir is preserved so the user can inspect per-chunk .err logs and rerun.
{
    my @incomplete = grep { ($_->{status} // '') ne 'completed' } @{$jobs};
    if (@incomplete) {
        my $nfail = scalar @incomplete;
        # NOTE: $ofile is deliberately NOT removed. This unlink dated from when
        # the text path appended straight to the destination; text now assembles
        # in $pdir, so nothing partial can be there. Keeping it meant a failed run
        # DESTROYED the user's previous valid result and wrote nothing in its
        # place. A failure must leave the prior output exactly as it was.

        show_message(sprintf("\nERROR: %d of %d chunks did not complete successfully.\n", $nfail, $n));
        show_message("No output written — partial results would silently omit genomic regions.\n");
        show_message("Chunk outputs and per-chunk .err logs preserved in:\n  $pdir\n");
        my $show = $nfail < 8 ? $nfail : 8;
        show_message("Failed / not-run chunks:\n");
        for my $j (@incomplete[0 .. $show - 1]) {
            show_message(sprintf("  %-10s %-24s [%s]\n",
                $j->{name} // '?', $j->{region} // '?', ($j->{status} || 'not-run')));
        }
        show_message(sprintf("  ... and %d more\n", $nfail - $show)) if $nfail > $show;
        croak("Aborting: incomplete parallel run. Fix the cause and rerun (temp dir: $pdir).");
    }
}

# Assembly-stage messages carry the same "[HH:MM:SS] " prefix as the progress line,
# so the whole run reads as one timeline rather than a progress bar followed by
# untimed prose.
sub _stamp { return "[" . strftime("%H:%M:%S", localtime()) . "] " }

#=================================================================================================
# Step 4. Concatenate VCF/BCF files
#=================================================================================================

if ($cmd_mode eq 'aggregate') {
    # Aggregate mode: merge per-region results (e.g., bcftools stats)
    show_message(_stamp() . "Merging $n aggregate results...\n");

    if ($command eq 'stats') {
        # bcftools stats emits a .vchk table whose per-section counters must be
        # SUMMED across regions. `plot-vcfstats -m` is the only correct merger.
        # There is NO safe textual fallback: plain concatenation would emit
        # duplicate/unsummed rows and present them as merged statistics, which is
        # scientifically wrong. So fail closed if plot-vcfstats is unavailable.
        # A single-chunk run never reaches here: `$n == 1` is handled upstream by a
        # plain-bcftools passthrough (before this parallel path), so `stats` merges
        # only ever see >= 2 chunks — which is exactly what `plot-vcfstats -m` needs
        # (it rejects a lone input with "Nothing to merge").
        my @chunk_files = map { $_->{file} } @{$jobs};
        my $efile = File::Spec->catfile($pdir, 'para_statsmerge.err');
        my $merge_cmd = "plot-vcfstats -m " . join(" ", map { shq($_) } @chunk_files)
            . " > " . shq($publish_stage) . " 2>" . shq($efile);
        my $rc = system($merge_cmd);
        if ($rc != 0 || !-s $publish_stage) {
            unlink($publish_stage) if -e $publish_stage;   # do not leave a wrong/empty stats file
            my $emsg = _slurp($efile);
            croak("Cannot merge per-region 'stats' output: plot-vcfstats -m failed"
                . " (exit " . wait_status_exit($rc) . ").\n"
                . ($emsg ? "  $emsg\n" : "")
                . "  plot-vcfstats (ships with bcftools; needs python + matplotlib for\n"
                . "  plots, but -m merging needs only python) must be on \$PATH.\n"
                . "  There is no safe textual merge for stats — run 'bcftools stats'\n"
                . "  serially, or install plot-vcfstats, then rerun.");
        }
    } else {
        croak("Internal error: aggregate mode reached for unsupported command '$command'.");
    }
    _with_signals_deferred(sub {
        my ($signal_pending) = @_;
        my $r = _publish_output($publish_stage, $ofile, 0, $signal_pending);
        $r or croak("Cannot publish stats output to '$ofile': $!");
        if ($r eq 'ABORTED') {
            show_message("\nSignal received during publication — '$ofile' left unchanged.\n"
                       . "Merged stats kept in: $pdir\n");
            return;
        }
        $pdir_publishable = 1;
    });

} elsif ($is_vcf) {
    show_message(_stamp() . "Concatenating $n VCF/BCF chunks...\n");

    # Record the real user command as a ##pbcftools_command provenance line. We
    # inject it into the FIRST chunk's header *before* concat: both `concat
    # --naive` and plain `concat` carry the first file's header into the output,
    # so this recompresses only one chunk (~1/N of the data) instead of rewriting
    # the whole concatenated output — avoiding a full extra I/O pass over the
    # (potentially tens-of-GB) result.
    # The command a DIRECT bcftools run would have recorded. bcftools parses with
    # getopt_long, which PERMUTES argv: options keep their given order but
    # positional operands are moved to the END. So `view in.vcf -Oz -o out` is
    # recorded as `view -Oz -o out in.vcf`. Replicate that permutation, or the
    # line would differ from serial by argument order alone. Joined raw — bcftools
    # does not quote its header line either.
    my $bcf_equiv;
    {
        # NOTE: _collect_positional_files() skips index 0 (the subcommand), so it
        # must be handed the array WITH the subcommand still at the front. Shifting
        # first made it skip the first real argument instead, leaving e.g.
        # `view IN.vcf -Oz -o OUT` unpermuted while serial bcftools records
        # `view -Oz -o OUT IN.vcf`.
        # Start from the argv the USER typed, with pbcftools' own options removed.
        # That keeps their output spelling (--output vs -o vs --output=PATH) and its
        # position among the other options, both of which serial bcftools records.
        my %ours_arity = (
            p_mode=>1, p_jobs=>1, p_len=>1, p_dir=>1, p_pre=>1, p_ref=>1, p_fai=>1,
            p_index=>1, p_wal=>1, p_mem=>1, p_cpu=>1, p_int=>1, p_try=>1, p_mem_inc=>1,
            p_wal_inc=>1, p_queue=>1, p_account=>1, p_yes=>0,
        );
        my @a;
        for (my $i = 0; $i <= $#argv_before_getopt; $i++) {
            my $t = $argv_before_getopt[$i];
            if ($t =~ /^--([A-Za-z0-9_-]+)(=.*)?$/s && exists $ours_arity{$1}) {
                $i++ if $ours_arity{$1} && !defined $2;
                next;
            }
            push @a, $t;
        }
        my $sub = @a ? $a[0] : lc($command);
        # serial bcftools records a plugin as TWO tokens, `plugin NAME`, not `+NAME`.
        # They must stay separate: joined into one token the quoting rule below sees
        # an embedded space and wraps the pair in single quotes.
        my @subtok = ($sub =~ /^\+(.+)$/) ? ('plugin', $1) : ($sub);
        my %is_pos = map { $_ => 1 }
                     _collect_positional_files(\@a, $short_arity, $long_arity);
        my (@opts, @pos);
        for my $tok (@a[1 .. $#a]) {
            if ($is_pos{$tok}) { push @pos, $tok } else { push @opts, $tok }
        }
        # If the user gave no output option at all (they must, on the parallel path),
        # fall back to naming it explicitly rather than recording a command that
        # would write to stdout.
        my $has_out = grep { /^-o$/ || /^-o./ || /^--output(?:-dir)?(?:=|$)/ } @opts;
        # Quote exactly as bcftools does when it writes its own provenance line, or
        # the recorded command differs from serial for a reason that has nothing to
        # do with parallelism -- and, worse, stops being re-runnable: an unquoted
        # `-i INFO/AF>0.05 && INFO/AF<0.95` is a shell AND of two commands with a
        # redirect. The rule (htslib bcf_hdr_append_version) is: wrap an argument in
        # single quotes if and only if it contains a SPACE. Not tab, not '>', not
        # '&&', and an embedded quote is NOT escaped. Matching it exactly is the
        # point; being "better" here would differ from serial just the same.
        my $q = sub { my ($t) = @_;
                      return (defined $t && index($t, ' ') >= 0) ? "'$t'" : $t; };
        $bcf_equiv = $has_out
            ? join(" ", map { $q->($_) } @subtok, @opts, @pos)
            : join(" ", map { $q->($_) } @subtok, @opts, "-o", $ofile, @pos);
    }
    _add_provenance_to_chunk($jobs->[0]{file}, $orig_cmdline, $pdir,
                             $command, $bcf_equiv, $run_start_date);

    # Write file list. CHECK every write and the close: a truncated list (e.g. the
    # FS filled) would make `concat` merge only a prefix and silently drop the
    # remaining genomic regions while still exiting 0.
    my $list_file = File::Spec->catfile($pdir, 'para_files.lst');
    open(my $lst_fh, ">", $list_file) or croak("Cannot open '$list_file': $!");
    for my $job (@{$jobs}) {
        say $lst_fh $job->{file} or croak("Write to concat list '$list_file' failed: $!");
    }
    close($lst_fh) or croak("Close of concat list '$list_file' failed (output would be incomplete): $!");

    # Concat. --naive is a fast block-level copy but only works for BGZF-
    # compressed VCF/BCF; fall back to a full concat for uncompressed VCF (-Ov,
    # the bcftools default output type), which --naive refuses.
    my $efile = File::Spec->catfile($pdir, 'para_concat.err');
    my $concat_cmd = "bcftools concat -f " . shq($list_file) . " --naive -o " . shq($publish_stage) . " 2>" . shq($efile);
    my $err = system($concat_cmd);
    if ($err != 0) {
        show_message("  --naive concat failed (uncompressed output?); retrying with a full concat...\n");
        # --no-version: plain concat (unlike --naive) appends
        # ##bcftools_concatVersion/Command describing THIS internal assembly step,
        # including the temp file-list path — two header lines serial never has.
        $err = system("bcftools concat -f " . shq($list_file) . " --no-version -o " . shq($publish_stage) . " 2>" . shq($efile));
        if ($err != 0) {
            my $emsg = _slurp($efile);
            # Fail-closed: discard the STAGED partial. The user's previous output
            # at $ofile is deliberately left untouched — a failed run must not
            # destroy a valid earlier result.
            unlink($publish_stage) if -e $publish_stage;
            croak("Concat failed (exit " . wait_status_exit($err) . "): $emsg");
        }
    }

    # INDEX FIRST, while the result is still staged in $pdir. Indexing used to run
    # AFTER the destination had been replaced, so an index failure unlinked both the
    # new output and the user's previous one, leaving nothing at all — and a signal
    # during indexing left new data at $ofile carrying the OLD index. Building the
    # index on the stage means every failure below is survivable: $ofile still holds
    # whatever it held before this run.
    #
    # Only BGZF-compressed VCF / BCF can be indexed (plain -Ov cannot). A FAILED
    # index is fatal: it can mean the merged result is unsorted (e.g. a
    # coordinate-changing operation whose records crossed a boundary), which must
    # not be reported as success.
    my $stage_index;
    if ($pindex && _is_bgzf_or_bcf($publish_stage)) {
        # One index over the assembled file, in the format the user asked for
        # (-W=tbi) or bcftools' default CSI. The per-chunk -W was removed above.
        my $ifmt = (defined $index_fmt && $index_fmt =~ /^tbi$/i) ? ' -t' : '';
        $t_assemble //= time() - $t_jobs_end;   # assembly ends where indexing begins
        show_message(_stamp() . "Indexing output...\n");
        $t_index_begin = time();
        my $ierr = File::Spec->catfile($pdir, 'para_index.err');
        if (system("bcftools index$ifmt " . shq($publish_stage) . " 2>" . shq($ierr)) != 0) {
            my $emsg = _slurp($ierr);
            # UNSORTED is a property of the data, not evidence of mis-assembly.
            # `norm -f REF` doing extreme left-alignment on a repetitive reference
            # genuinely emits unsorted records, and serial bcftools writes that file
            # and exits 0 — so refusing it made pbcftools reject a valid workflow that
            # bcftools supports. Publish the data, say clearly that it is unsorted and
            # unindexed, and let the user decide. Every OTHER index failure stays
            # fatal, because those do suggest the merged file is malformed.
            if ($emsg =~ /unsorted positions/i) {
                show_message("\nWARNING: the output is not coordinate-sorted, so no index "
                    . "was written.\n"
                    . "  This matches what serial bcftools produces for this command "
                    . "(some\n  normalisations legitimately reorder records). Sort it "
                    . "with 'bcftools sort'\n  if you need an index.\n");
                undef $stage_index;
            } else {
                unlink($publish_stage) if -e $publish_stage;   # discard the STAGE only
                croak("Indexing the merged output failed: $emsg\n"
                    . "  The output may be malformed — not reporting success.\n"
                    . "  '$ofile' was left unchanged.\n"
                    . "  Per-chunk outputs kept for inspection in: $pdir");
            }
        }
        # Sidecar extension follows the format actually written: `bcftools index -t`
        # produces .tbi, the default produces .csi. Hard-coding .csi meant a
        # user-requested -W=tbi index was built and then silently left behind in the
        # staging directory, so the published output had no index at all.
        $t_index = time() - $t_index_begin;
        for my $ext (qw(csi tbi)) {
            if (-e "$publish_stage.$ext") { $stage_index = "$publish_stage.$ext"; last }
        }

        # ACQUIRE BEFORE MUTATING. Data and index are two renames, so they cannot be
        # one transaction — which meant an index destination we could not write left
        # the user's previous output already REPLACED and the run exited non-zero: a
        # failed rerun that changed pre-existing data. Nothing below can undo that,
        # so the only fix is to reject the run BEFORE the data are published. The
        # reported case was an index path that is a non-empty DIRECTORY.
        if (defined $stage_index) {
            for my $sidecar ("$ofile.csi", "$ofile.tbi") {
                next unless -e $sidecar;
                next if -f $sidecar;      # a plain file is replaceable
                croak("Cannot install the output index: '$sidecar' exists and is not "
                    . "a regular file.\n"
                    . "  Refusing to publish, so '$ofile' is left unchanged — "
                    . "publishing first\n"
                    . "  and failing here would replace your previous result and "
                    . "still leave no index.\n"
                    . "  Remove or rename '$sidecar' and rerun. Chunks kept in: $pdir");
            }
        }
    } else {
        show_message("Uncompressed VCF output — not indexed.\n");
    }

    # PUBLISH: the staged, fully-assembled result replaces $ofile. Only now does
    # the user's path change — an interrupt before this leaves any previous valid
    # output untouched. The stale index of the replaced output is dropped as part
    # of publication, then the freshly built one (if any) is moved into place.
    _with_signals_deferred(sub {
        my ($signal_pending) = @_;
        # Give up BEFORE the destination is touched. Everything expensive (assembly,
        # indexing, any cross-device copy) is already done and staged, so aborting
        # here costs the user nothing but leaves their previous result intact.
        if ($signal_pending->()) {
            show_message("\nSignal received before publication — '$ofile' left unchanged.\n"
                       . "Assembled result kept in: $pdir\n");
            return;
        }
        my $r = _publish_output($publish_stage, $ofile, 1, $signal_pending);
        $r or croak("Cannot publish assembled output to '$ofile': $!");
        if ($r eq 'ABORTED') {
            show_message("\nSignal received during publication — '$ofile' left unchanged.\n"
                       . "Assembled result kept in: $pdir\n");
            return;
        }
        if (defined $stage_index) {
            # The data are valid and staying put, but exit 0 would promise an index
            # that is not there — and _publish_output() has already removed the
            # replaced output's stale index, so downstream indexed access breaks.
            # Report failure while RETAINING the published data for recovery.
            my ($sidecar_ext) = $stage_index =~ /\.(csi|tbi)$/;
            _publish_output($stage_index, "$ofile.$sidecar_ext")
                or croak("Output was published to '$ofile', but its index could not "
                       . "be installed as '$ofile.csi': $!\n"
                       . "  The data are correct and complete — only the index is missing.\n"
                       . "  Recover with: bcftools index " . shq($ofile));
        }
        $pdir_publishable = 1;   # published: staging is now disposable
    });

} elsif (lc($command) eq 'roh' && -s $text_stage) {
    # The assembled file kept the FIRST chunk's header, whose "# The command line
    # was:" echoes that chunk's -r — misleading for a whole-genome result. Rewrite
    # it to the user's actual command. Non-fatal: on any failure the (correct)
    # data is left untouched and only the provenance line is stale.
    my $tmp = "$text_stage.prov.$$";
    if (open(my $in, '<', $text_stage)) {
        if (open(my $out, '>', $tmp)) {
            (my $prov = $orig_cmdline) =~ s/[\r\n]+/ /g;
            my ($ok, $done) = (1, 0);
            while (my $l = <$in>) {
                $l = "# The command line was:\t$prov\n" if !$done && $l =~ /^#\s*The command line was:/ && ($done = 1);
                print $out $l or do { $ok = 0; last };
            }
            $ok &&= close($out); close($in);
            if ($ok) { move($tmp, $text_stage) or unlink($tmp); } else { unlink($tmp); }
        } else { close($in); }
    }
    _with_signals_deferred(sub {
        my ($signal_pending) = @_;
        my $r = _publish_output($text_stage, $ofile, 0, $signal_pending);
        $r or croak("Cannot publish text output to '$ofile': $!");
        if ($r eq 'ABORTED') {
            show_message("\nSignal received during publication — '$ofile' left unchanged.\n"
                       . "Assembled text kept in: $pdir\n");
            return;
        }
        $pdir_publishable = 1;
    });

} else {
    # Text mode: append_tab_file() unlinks zero-byte chunks, so if EVERY chunk was
    # empty (region hit no records, or a filter excluded all) no staging file was
    # ever created. Serial bcftools would still produce the file, so create an
    # empty one to keep the success contract (a present, correct-but-empty output).
    unless (-e $text_stage) {
        open(my $eh, '>', $text_stage) or croak("Cannot create output '$text_stage': $!");
        close($eh) or croak("Cannot finalize output '$text_stage': $!");
    }
    # PUBLISH: only now, with every chunk verified, does the user's -o appear.
    # Use the shared publisher: its cross-device path copies to a SIBLING of the
    # destination and then renames, so an interrupt or a full disk cannot leave a
    # half-written file at the user's path. The inline copy this replaced wrote
    # straight to $ofile and could.
    # Wrapped like every other family: the cross-device copy here is just as long,
    # and leaving it outside the deferral left an orphaned sibling scratch file on an
    # ordinary SIGTERM (not only on SIGKILL, as the ledger's L7 assumed).
    _with_signals_deferred(sub {
        my ($signal_pending) = @_;
        my $r = _publish_output($text_stage, $ofile, 0, $signal_pending);
        $r or croak("Cannot publish text output to '$ofile': $!");
        if ($r eq 'ABORTED') {
            show_message("\nSignal received during publication — '$ofile' left unchanged.\n"
                       . "Assembled text kept in: $pdir\n");
            return;
        }
        $pdir_publishable = 1;
    });
}

# Clean up intermediate chunk files. Only remove a temp dir we created
# ourselves; a user-supplied --p_dir is left untouched. This runs only on the
# success path — the fail-closed guard above preserves the dir for inspection.
#=================================================================================================
# Step 5. Timing summary
# One closing line for every output family, then the end-of-run marker. `End` used
# to print as soon as the workers finished, before assembly and indexing, so it
# claimed the run had ended while the output file did not yet exist.
show_message("Output written to: $ofile\n") if defined $ofile && !_is_stdout_dest($ofile);
my $time2 = strftime("%Y-%m-%d %H:%M:%S", localtime());
show_message("=========== End: $time2 ===========\n");

#=================================================================================================
# Printed once, after every stage has finished, so the numbers are final. The three
# stages are reported separately because they have different remedies: the dispatch
# step responds to more workers, assembly is largely fixed, and the index is a
# single-core tail that no amount of parallelism shortens.
{
    $t_assemble //= time() - $t_jobs_end;
    my $njobs = scalar @{$jobs};
    my ($wait_tot, $run_tot, $counted) = (0, 0, 0);
    for my $j (@{$jobs}) {
        next unless defined $j->{t1};
        $wait_tot += $j->{t1} - $t_jobs_begin;
        $run_tot  += ($j->{t2} // $t_jobs_end) - $j->{t1};
        $counted++;
    }
    my $fmt = sub { my $v = shift; $v >= 60 ? sprintf("%dm%02ds", int($v/60), $v%60)
                                            : sprintf("%.1fs", $v) };
    show_message("\n==================== Timing ====================\n");
    show_message(sprintf("jobs       %d chunk%s, %d concurrent   wall %s\n",
                         $njobs, ($njobs == 1 ? '' : 's'), $pjobs, $fmt->($jobs_wall)));
    if ($counted) {
        show_message(sprintf("           run   total %s   mean %s/chunk\n",
                             $fmt->($run_tot),  $fmt->($run_tot  / $counted)));
        show_message(sprintf("           wait  total %s   mean %s/chunk\n",
                             $fmt->($wait_tot), $fmt->($wait_tot / $counted)));
    }
    show_message(sprintf("           cpu   total %s   mean %s/chunk\n",
                         $fmt->($jobs_cpu), $fmt->($njobs ? $jobs_cpu / $njobs : 0)));
    show_message(sprintf("assembly   %s\n", $fmt->($t_assemble)));
    show_message(sprintf("index      %s\n", $fmt->($t_index))) if defined $t_index;
    # Close the block at the same width as the Start/End banners, so the run reads
    # as three delimited sections rather than trailing off.
    show_message("================================================\n");
}

if ($auto_tmp && -d $pdir) {
    remove_tree($pdir);
}

exit(0);

#=================================================================================================
# Subroutines
#=================================================================================================

# Insert a ##pbcftools_command provenance line into ONE chunk's header (the first
# file in the concat list), in place, via bcftools reheader. Because concat
# carries the first file's header into the merged output, this adds provenance
# without a full-file pass over the final result. reheader preserves the chunk's
# own format (VCF.gz/BCF). Non-fatal: on any failure the chunk is left intact and
# the run proceeds without the provenance line.
sub _add_provenance_to_chunk {
    my ($chunk, $cmdline, $pdir, $command, $bcf_equiv, $date_str) = @_;
    return unless defined $chunk && -e $chunk;
    # --no-version is REQUIRED here: without it bcftools appends
    # ##bcftools_viewVersion / ##bcftools_viewCommand describing THIS internal
    # `view -h` call (including the temp chunk path) to the header it prints, and
    # we would then write that artifact into the user's output via reheader.
    my @hdr = `bcftools view -h --no-version @{[ shq($chunk) ]} 2>/dev/null`;
    return if $? != 0 || !@hdr;   # an incomplete header read must not be reheadered
    (my $prov = $cmdline) =~ s/[\r\n]+/ /g;
    my $hdr_file = File::Spec->catfile($pdir, 'para_provenance.hdr');
    open(my $hf, '>', $hdr_file) or return;
    # Normalize the inherited bcftools provenance line. `concat --naive` carries
    # the FIRST chunk's header, whose ##bcftools_<cmd>Command records that chunk's
    # injected -r and its temp -o — so verbatim it would advertise a fraction of
    # the file and a path that no longer exists. Rewrite it to the command a
    # DIRECT bcftools run would have recorded, so downstream tools that parse
    # bcftools provenance see the same thing either way. The adjacent
    # ##pbcftools_command discloses that pbcftools produced it, so nothing is
    # hidden. The Version line is left untouched (it is already true).
    my $key = lc($command // '');
    # A plugin is invoked as `+NAME` (or `plugin NAME`, normalized to `+NAME`
    # upstream), but bcftools records it as ##bcftools_pluginCommand -- the KEY is
    # "plugin", never the plugin's name. Deriving the key from $command gave
    # "filltags", which matched nothing, so the first chunk's line survived into the
    # published output naming that CHUNK's region and its since-deleted temp path.
    # It looked correct for attached spellings like `-Oz` only because those fall
    # back to passthrough, where bcftools writes the line itself.
    $key = 'plugin' if $key =~ /^\+/;
    $key =~ s/[^A-Za-z0-9_]//g;
    # NOTE the separator. Most subcommands write ##bcftools_<cmd>Command, but `csq`
    # writes ##bcftools/csqCommand with a SLASH. Matching only the underscore meant
    # csq's header was never rewritten, so a parallel run published a header naming
    # the FIRST CHUNK's region and a temp path that had already been deleted.
    my ($last_cmd_idx, $sep);
    if (length $key && defined $bcf_equiv) {
        for my $i (0 .. $#hdr) {
            if ($hdr[$i] =~ m{^\#\#bcftools([_/])\Q$key\ECommand=}) {
                $last_cmd_idx = $i;
                $sep = $1;
            }
        }
    }
    if (defined $last_cmd_idx) {
        (my $eq = $bcf_equiv) =~ s/[\r\n]+/ /g;
        $hdr[$last_cmd_idx] = "##bcftools" . ($sep // '_') . "${key}Command=$eq"
            . (defined $date_str ? "; Date=$date_str" : "") . "\n";
    }

    my $write_ok = 1;
    for my $line (@hdr) {
        $write_ok &&= print $hf "##pbcftools_command=$prov\n" if $line =~ /^#CHROM/;
        $write_ok &&= print $hf $line;
    }
    $write_ok &&= close($hf);
    unless ($write_ok) {          # a truncated temp header must never reach reheader
        unlink $hdr_file if -e $hdr_file;
        warn "Note: could not write provenance header (non-fatal); output left intact.\n";
        return;
    }
    my $tmp = "$chunk.prov.tmp";
    if (system("bcftools reheader -h " . shq($hdr_file) . " -o " . shq($tmp) . " " . shq($chunk) . " 2>/dev/null") == 0 && -s $tmp) {
        rename($tmp, $chunk) or do {
            unlink $tmp if -e $tmp;
            warn "Provenance: cannot replace chunk '$chunk': $!\n";
        };
    } else {
        unlink $tmp if -e $tmp;
        warn "Note: could not add ##pbcftools_command provenance header (non-fatal).\n";
    }
}

# Refuse an output path that resolves to any input file — by absolute path, and
# by (device,inode) when both exist (catches symlinks/hardlinks). In-place
# overwrite is unsafe: both the passthrough (bcftools truncates the input) and
# the parallel path (region discovery reads a vanished file) corrupt data. Called
# early, before ANY passthrough or output unlink.
# Read a bcftools file-of-filenames once, FAIL CLOSED on any I/O trouble. A silent
# partial read (open/read/close failure) could omit a later member that aliases the
# output, so the guard would miss it and the pre-run unlink could destroy it.
sub _read_list_members {
    my ($lf) = @_;
    open(my $fh, '<', $lf)
        or croak("Cannot open file list '$lf' to check for an output-alias: $!");
    my @members;
    while (my $line = <$fh>) { chomp $line; push @members, $line if length $line; }
    my $read_ok = !$fh->error;
    my $closed  = close($fh);
    croak("Read error on file list '$lf' (a partial read could hide an output-alias).")
        unless $read_ok && $closed;
    return @members;
}

# Destructive-alias candidate set for the output guard: every REGULAR file named in
# argv that overwriting the output could destroy — positional operands AND option
# values (e.g. `annotate -a ann.vcf.gz`, bundled `view -GSsamples.txt`). Two
# deliberate bounds keep it both safe and non-disruptive:
#   * Only REGULAR files count. A non-regular target (/dev/null, /dev/stdout, a FIFO,
#     a device) is neither a destroyable input nor a real overwrite, so a legitimate
#     `-o /dev/null` discard is never mis-flagged as an alias.
#   * Short bundles are scanned by EVERY suffix of the tail, so a file glued after
#     any number of no-arg flags (`-GSfile`) is found without knowing arities. This
#     also applies AFTER a plugin '--' boundary, so `+fill-tags ... -- -Sfile` and
#     `-- --samples-file=FILE` cannot hide a side input.
# The heuristic in general cannot tell a string option-value that merely spells an
# existing regular file from a real file input; such a coincidence collides with the
# guard only when the output IS that path, and refusing there is the safe direction.
# The ONE confirmed real false-positive — `query -f <format>`, whose value is always
# a format STRING, never a file — is carved out below by command+option so a format
# that happens to name a file (reused as -o) is not mis-flagged. This is a narrow,
# explicit exception, not a general option-role model. The output's own -o/--output
# value is always excluded. For a file-of-filenames the container and every checked
# member are included; a non-regular list source (stdin '-', FIFO, device) cannot be
# vetted and is refused when an -o output is present.
sub _alias_candidate_paths {
    my ($args, $command, $ofile) = @_;
    my $cmd = lc($command // '');
    my @cand;
    my $skip_next  = 0;                        # previous token was a separated -o/--output
    my $after_ddash = 0;                       # past a '--' end-of-options marker
    for my $i (1 .. $#$args) {
        my $arg = $args->[$i];
        if ($skip_next) { $skip_next = 0; next; }              # the OUTPUT path itself
        if (!$after_ddash && $arg eq '--') { $after_ddash = 1; next; }
        # -o/--output is a WRAPPER option only BEFORE the plugin '--' boundary. After
        # '--', options belong to the plugin (e.g. +fill-tags `-Sfile`) and may carry
        # file inputs, so they get the same scanning as before '--'.
        unless ($after_ddash) {
            if ($arg eq '-o' || $arg eq '--output') { $skip_next = 1; next; }
            next if $arg =~ /^--output=/ || $arg =~ /^-o./;    # attached output value
        }
        # NARROW carve-out: `query -f/--format <fmt>` is a format string, never a file.
        # Skip its value in every common form so a format that spells an existing file
        # (and is reused as -o) is not a false alias. (Bundled `-Hf FMT` is left to the
        # general scan — a rare residual per the accepted narrow scope.)
        if ($cmd eq 'query' && !$after_ddash) {
            if ($arg eq '-f' || $arg eq '--format') { $skip_next = 1; next; }
            next if $arg =~ /^--format=/ || $arg =~ /^-f./;     # attached format value
        }
        if ($arg =~ /^--[^=]+=(.*)$/s) {                       # --opt=payload / --samples-file=FILE
            push @cand, $1 if length $1 && -f $1;
            next;
        }
        if ($arg =~ /^-[^-]/ && $arg ne '-') {                 # short/bundled option token
            my $tail = substr($arg, 1);
            for (my $j = 0; $j < length $tail; $j++) {         # a value may be glued after
                my $suffix = substr($tail, $j);                # any run of no-arg flags (-GSfile)
                push @cand, $suffix if -f $suffix;
            }
            next;
        }
        push @cand, $arg if -f $arg;          # positional, separated value, or post-'--' operand
    }
    # The file-of-filenames bcftools will actually read (last-occurrence-wins).
    my $scan  = scan_command_argv($args, $command);
    my $lists = $scan ? ($scan->{roles}{file_list} // []) : [];
    my $lf    = @$lists ? $lists->[-1]{value} : undef;
    # `query -v/--vcf-list` is ALSO a file-of-filenames, but query has no bounded
    # ArgParser schema, so the scan above never reports it. Without this, naming the
    # output after one of the listed VCFs destroyed that input: the guard protected
    # the LIST but not its MEMBERS.
    if (!defined $lf && lc($command) eq 'query') {
        # bcftools uses the LAST -v/--vcf-list; _opt_value returns the FIRST, so
        # walk the whole argv. Args here are bundle-EXPANDED, so `-uvLIST` has
        # already become `-u -v LIST` and is visible.
        for my $i (1 .. $#$args) {
            last if $args->[$i] eq '--';
            if ($args->[$i] =~ /^--vcf-list=(.*)$/s)                   { $lf = $1 }
            elsif ($args->[$i] =~ /^(?:-v|--vcf-list)$/ && defined $args->[$i+1]) { $lf = $args->[$i+1] }
            elsif ($args->[$i] =~ /^-v(.+)$/s)                          { $lf = $1 }
        }
        undef $lf unless defined $lf && length $lf;
    }
    if (defined $lf && length $lf) {
        if ($lf eq '-' || (-e $lf && ! -f $lf)) {              # stdin / FIFO / device / fd
            croak("Refusing '$command' with a non-regular file list ('$lf') AND an "
                . "output: its members cannot be checked against the output path. "
                . "Provide the list as a named regular file instead.")
                if defined $ofile && length $ofile;
        } elsif (-f $lf) {
            push @cand, $lf;                  # the list container is itself an input
            push @cand, _read_list_members($lf);
        }
    }
    return @cand;
}

# True if the output path is the process's STDOUT stream, not a real file to
# assemble: the '-' convention, the standard /dev fd aliases, or ANY existing path
# whose (device,inode) is fd 1 right now (so `-o /dev/stdout` resolves to stdout even
# when stdout is itself redirected to a regular file). Such a destination is written
# by ONE bcftools process — never pre-cleaned, unlinked, or multi-chunk assembled.
sub _is_stdout_dest {
    my ($path) = @_;
    return 0 unless defined $path;
    return 1 if $path eq '-';
    return 1 if $path eq '/dev/stdout' || $path eq '/dev/fd/1' || $path eq '/proc/self/fd/1';
    if (-e $path) {
        my @ps = stat($path);
        my @os = stat(\*STDOUT);
        return 1 if @ps >= 2 && @os >= 2 && $ps[0] == $os[0] && $ps[1] == $os[1];
    }
    return 0;
}

sub _refuse_io_alias {
    my ($ofile, @inputs) = @_;
    return unless defined $ofile;
    my $oabs = File::Spec->rel2abs($ofile);
    my @ost  = (-e $ofile) ? stat($ofile) : ();
    for my $in (@inputs) {
        next unless defined $in && length $in;
        my $same = (File::Spec->rel2abs($in) eq $oabs);
        if (!$same && @ost >= 2 && -e $in) {
            my @ist = stat($in);
            $same = 1 if @ist >= 2 && $ist[0] == $ost[0] && $ist[1] == $ost[1];
        }
        croak("Refusing to run: output '$ofile' is the same file as input '$in'. "
            . "Write to a different path (in-place overwrite is unsafe).") if $same;
    }
}

# True if $f exists and carries a companion .csi/.tbi index (i.e. is region-
# seekable). Extension-agnostic: any indexed bgzipped file qualifies, not only
# .vcf/.bcf. This is the precondition for region-parallel execution.
sub _is_indexed {
    my ($f) = @_;
    return 0 unless defined $f && -e $f;
    return (-e "$f.csi" || -e "$f.tbi") ? 1 : 0;
}

# Contigs of an indexed VCF/BCF as a { name => length } hash (from the index —
# fast, index-only). Length is 0 if the index reports it unknown ('.').
sub _file_contigs {
    my ($f) = @_;
    my %len;
    open(my $fh, '-|', 'bcftools', 'index', '-s', $f)
        or croak("Cannot run 'bcftools index -s' on '$f' (need a valid index): $!");
    while (<$fh>) {
        chomp;
        my ($name, $length) = split /\t/;
        next unless defined $name && length $name;
        $len{$name} = (defined $length && $length =~ /^\d+$/) ? $length : 0;
    }
    # FAIL CLOSED: a read error or a nonzero `index -s` can emit a valid PREFIX of
    # the contigs then stop. A partial set has FEWER contigs, so it slips through
    # the mismatch guard above and its records would be silently omitted from
    # region discovery. Require a clean read, a clean close (pipe child exit 0),
    # and at least one contig before trusting the set.
    my $read_ok = !$fh->error;
    my $closed  = close($fh);   # sets $? from the `bcftools index -s` child
    croak("Read error while listing contigs of '$f' (a partial contig set is unsafe).")
        unless $read_ok;
    croak("'bcftools index -s' on '$f' failed (exit @{[ $? >> 8 ]}); its contig set "
        . "cannot be trusted. Re-index the file (bcftools index -f).")
        unless $closed && $? == 0;
    croak("'bcftools index -s' on '$f' returned no contigs; the index is missing or corrupt.")
        unless %len;
    return \%len;
}

# True if $f is BGZF-compressed (VCF.gz) or BCF — i.e. can be coordinate-indexed.
# Plain uncompressed VCF (-Ov) cannot. Detected by magic bytes so it is robust to
# whatever -O inference produced.
sub _is_bgzf_or_bcf {
    my ($f) = @_;
    open(my $fh, '<:raw', $f) or return 0;
    my $n = read($fh, my $buf, 4);
    close $fh;
    return 0 unless defined $n && $n >= 2;
    return 1 if $buf =~ /^\x1f\x8b/;   # gzip / BGZF
    return 1 if $buf =~ /^BCF/;        # BCF
    return 0;
}

# True if the bcftools option section contains any of the named options. Names
# are given WITHOUT leading dashes: single-char = short (`-g`, `-g5` attached),
# longer = long (`--gvcf`, `--gvcf=...`). Case-sensitive (so `-g` != `-G`).
# Stops at the plugin `--` boundary. Structural, not a regex over the whole
# command string — used for parallel-safety mode decisions, so accuracy matters.
sub _has_opt {
    my ($args, @names) = @_;
    my %short = map { $_ => 1 } grep { length($_) == 1 } @names;
    my @long  = grep { length($_) > 1 } @names;
    for my $a (@$args) {
        last if $a eq '--';
        if ($a =~ /^--([^=]+)/) {
            my $opt = $1;
            # bcftools accepts UNIQUE long-option abbreviations (--gvc = --gvcf,
            # --SnpG = --SnpGap). Match exact or any nonempty prefix of a target.
            # Over-matching only routes to a stricter/safer mode -> fail-closed.
            for my $t (@long) {
                return 1 if $opt eq $t || index($t, $opt) == 0;
            }
        }
        elsif ($a =~ /^-([A-Za-z]+)/) {
            # Short option token — possibly a BUNDLE (`-mg5,10` = `-m -g5,10`) or a
            # short with an attached value (`-g5,10`). We can't know which letters
            # are options vs value without a per-command schema, so we check EVERY
            # leading letter. A false match (a value letter) only over-routes to a
            # safer mode, never misses a gated option -> fail-closed. NB: only use
            # this for mode-TIGHTENING gates; for mode-relaxing flags (-N, -l) use
            # _has_flag, which does not scan into attached values.
            my $letters = $1;
            for my $c (keys %short) { return 1 if index($letters, $c) >= 0; }
        }
    }
    return 0;
}

# Conservative detector for a value-LESS flag: an EXACT short token (`-N`) or a
# long option (exact or abbreviation prefix). Unlike _has_opt it never scans
# bundled/attached-value letters, so it cannot be fooled by a filename value
# (e.g. `csq -flocal.fa` must NOT be read as `-l`). Use for mode-RELAXING flags
# (norm -N, csq/query -l) where a false positive would pick a LESS-safe mode.
sub _has_flag {
    my ($args, $short, @long) = @_;
    for my $a (@$args) {
        last if $a eq '--';
        return 1 if defined $short && $a eq "-$short";
        if ($a =~ /^--([^=]+)/) {
            my $o = $1;
            for my $t (@long) { return 1 if $o eq $t || index($t, $o) == 0; }
        }
    }
    return 0;
}

# Return the value of the first matching option, or undef. Handles -f VAL, -fVAL,
# --format VAL, --format=VAL, and long-option abbreviations (as in _has_opt).
sub _opt_value {
    my ($args, @names) = @_;
    my %short = map { $_ => 1 } grep { length($_) == 1 } @names;
    my @long  = grep { length($_) > 1 } @names;
    my $long_match = sub { my $o = shift; for my $t (@long) { return 1 if $o eq $t || (length($o) >= 2 && index($t, $o) == 0); } 0 };
    for my $i (0 .. $#$args) {
        my $a = $args->[$i];
        last if $a eq '--';
        if ($a =~ /^--([^=]+)=(.*)$/s) { return $2 if $long_match->($1); }
        elsif ($a =~ /^--([^=]+)$/)    { return $args->[$i+1] if $long_match->($1) && defined $args->[$i+1]; }
        elsif ($a =~ /^-([A-Za-z])(.*)$/s) { if ($short{$1}) { return length($2) ? $2 : $args->[$i+1]; } }
    }
    return undef;
}

# _shq (robust POSIX shell-quote) now lives in PBCFTools::Helpers as shq(), shared
# by the main script and every backend so quoting is consistent across all shell
# calls (worker commands, assembly/concat/index/provenance, and scheduler paths).

# Run a command with plain (unparallelized) bcftools; return its exit code.
# Places -o before any plugin `--`; handles stdout-only / no-output commands
# (`head` and `query -l` redirect stdout to $ofile; `index` takes no -o). Pass
# $ofile=undef for informational invocations that must not be given -o.
sub _bcftools_passthrough {
    my ($args, $ofile, $command, $why) = @_;
    # Standardized passthrough notice. Callers pass a short reason phrase (no
    # trailing period); a caller that has already shown its own explanation (e.g.
    # the confirmation-gated 'incompatible' path) passes undef to suppress this.
    show_message("NOTE: $why — running bcftools directly.\n") if defined $why && length $why;
    my @a = @$args;
    my $cmd_lc = lc($command);
    # stdout-only commands (no -o): head; query -l; and stats/roh (write their
    # table/text to stdout). `cnv` is NOT here — it needs its own `-o OUTPUT_DIR`.
    my $to_stdout = ($cmd_lc eq 'head' || $cmd_lc eq 'stats' || $cmd_lc eq 'roh');
    $to_stdout = 1 if $cmd_lc eq 'query' && _has_flag(\@a, 'l', 'list-samples');

    my $ddash;
    for my $i (0 .. $#a) { if ($a[$i] eq '--') { $ddash = $i; last; } }
    my @pre  = defined $ddash ? @a[0 .. $ddash - 1] : @a;
    my @post = defined $ddash ? @a[$ddash .. $#a] : ();

    # -o handling is command-role aware, because "write to stdout" is expressed
    # differently per command:
    #   * cnv     — -o is an OUTPUT DIRECTORY, never a stream: pass it verbatim.
    #   * index   — writes the index itself; to stdout it needs an explicit `-o -`
    #               (CSI/TBI stream), else omitting -o silently writes a sidecar file.
    #   * stdout_only / normal data commands — both default to stdout when -o is
    #               omitted, and pbcftools inherits that stdout. So for a stdout
    #               destination we omit -o entirely: NOT `-o -` (bcftools `query`
    #               treats `-` as a LITERAL filename) and NOT a `> '-'` redirect.
    #   * a real file path keeps the prior behaviour (redirect for stdout-only
    #               commands, explicit -o otherwise).
    my $redirect = '';
    my $stage_out;
    my $stage_nonatomic = 0;   # staged outside the destination dir; copy, cannot rename
    if (defined $ofile) {
        my $stdout_dest = _is_stdout_dest($ofile);
        if ($cmd_lc eq 'cnv') {
            push @pre, '-o', $ofile;
        } elsif ($cmd_lc eq 'index') {
            push @pre, '-o', ($stdout_dest ? '-' : $ofile);
        } elsif ($stdout_dest) {
            # inherit stdout: add nothing
        } elsif ($to_stdout) {
            # STAGE, do not redirect straight at the user's path. A shell `>` truncates
            # the destination the instant it is set up — before bcftools has run, let
            # alone succeeded. So a passthrough that then FAILED left a pre-existing
            # result destroyed, where serial `bcftools stats -o FILE` validates first
            # and leaves it untouched: pbcftools was strictly worse than the tool it
            # wraps, on the one path where it is meant to be indistinguishable.
            # Write to a sibling and publish only on success (Invariant P).
            # A SYMLINK (or any existing non-regular destination) must be written
            # THROUGH, not replaced. `bcftools head IN > link` follows the link and
            # updates its target, leaving the link in place; staging and renaming
            # would put a regular file where the link was and leave the real target
            # stale. Same reasoning as the -/\/dev/stdout cases above, one step
            # further out. These take the copy path below, which opens the
            # destination and therefore follows the link exactly as the shell does.
            my $indirect_dest = (-l $ofile) || (-e $ofile && ! -f $ofile);
            $stage_out = $indirect_dest ? undef : _claim_sibling($ofile);
            if (defined $stage_out) {
                $redirect = " > " . shq($stage_out);
            } else {
                # Either the destination must be written through (symlink / non-
                # regular), or a sibling could not be claimed: the directory is not
                # writable, or every candidate name is taken. Do NOT redirect at $ofile -- a shell
                # `>` truncates it the instant the redirect is set up, before the
                # command runs, so a run that then failed destroyed the user's result
                # and left zero bytes. That is the loss the staging exists to prevent.
                #
                # Nor refuse outright: `bcftools stats > FILE` succeeds when the FILE
                # is writable even though its DIRECTORY is not, and pbcftools must not
                # fail where the tool it wraps works. Refusing was a real regression.
                #
                # So stage OUTSIDE the destination directory and copy in only after the
                # command has succeeded. Publication is not atomic here -- a read-only
                # directory cannot accept a new file, so there is no rename to make it
                # atomic -- but the destination is not touched at all unless the result
                # is known good, which is the property that matters.
                my ($tmp_fh, $tmp_name) = eval {
                    require File::Temp;
                    File::Temp::tempfile("pbcf_stage_XXXXXX",
                                         DIR => File::Spec->tmpdir(), UNLINK => 0);
                };
                if (defined $tmp_name) {
                    close($tmp_fh) if $tmp_fh;
                    $stage_out    = $tmp_name;
                    $stage_nonatomic = 1;
                    $redirect     = " > " . shq($tmp_name);
                } else {
                    croak("Cannot create a staging file next to '$ofile' "
                        . "(directory not writable, or 1000 candidates like "
                        . "'$ofile.pbcf.pt.$$.N' are taken), and no temporary "
                        . "directory is usable either.\n"
                        . "Refusing to write directly to '$ofile': doing so would "
                        . "truncate it before the command runs, destroying it if "
                        . "the command then fails.");
                }
            }
        } else {
            push @pre, '-o', $ofile;
        }
    }
    my $cmd = "bcftools " . join(" ", map { shq($_) } @pre, @post) . $redirect;
    show_message("Running: $cmd\n");
    # Decode the full wait status: a signal-killed passthrough (e.g. OOM) must not
    # report exit 0. This is the process's final exit code, so it must be honest.
    my $rc = wait_status_exit(system($cmd));
    if (defined $stage_out) {
        if ($rc == 0) {
            if ($stage_nonatomic) {
                # No rename is possible into a directory we cannot write, so copy the
                # bytes into the existing file. This is the only step that touches the
                # destination, and it runs only after the command succeeded.
                require File::Copy;
                File::Copy::copy($stage_out, $ofile)
                    or croak("Cannot copy the result into '$ofile': $!\n"
                           . "  The result is complete and kept at: $stage_out");
                unlink($stage_out);
            } else {
                _publish_output($stage_out, $ofile)
                    or croak("Cannot publish output to '$ofile': $!\n"
                           . "  The result is complete and kept at: $stage_out");
            }
        } else {
            unlink($stage_out);          # failed: the user's previous result stands
        }
    }
    return $rc;
}

# Claim an unused scratch name beside $dst, atomically. Same reasoning as the
# publishers: a name that merely does not exist yet can be taken between the test
# and the open.
sub _claim_sibling {
    my ($dst) = @_;
    require Fcntl;
    for my $i (0 .. 999) {
        my $cand = "$dst.pbcf.pt.$$.$i";
        if (sysopen(my $fh, $cand, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600)) {
            close($fh);
            return $cand;
        }
    }
    return undef;
}

# Fallback for commands not covered by the bounded structural parser: collect
# existing files that appear as positional (non-option) arguments.
# Skips the command name (index 0) and the values consumed by known
# value-taking bcftools options, so an option argument like `-a annots.vcf.gz`
# or `-h header.txt` is not mistaken for an input file. Callers additionally
# prefer VCF/BCF-looking names, so this heuristic only needs to be good enough
# to avoid the common collisions.
# ---------------------------------------------------------------------------
# Short-option bundle expansion.
#
# bcftools accepts GNU-style bundles: `-aOb` is `-a -O b`, `-ur1:1-50000` is
# `-u -r 1:1-50000`. pbcftools classifies arguments by token PREFIX, so an -r/-R
# or -O hidden inside a bundle was invisible: it then injected its own -r (and
# bcftools' last-region-wins silently discarded the user's restriction), or missed
# -O b and pushed BCF through the TEXT assembler. Both produced wrong output with
# exit 0.
#
# Arity is read from `bcftools <cmd> --help` at RUNTIME rather than hardcoded, so
# it tracks whatever bcftools the user actually has. Format:
#     "  -r, --regions REGION   Restrict ..."   <- single space then arg => takes a value
#     "  -H, --no-header        Suppress ..."   <- 2+ spaces => flag
# If arity cannot be determined, or a bundle contains a letter we do not know,
# expansion FAILS CLOSED (returns undef) and the caller runs bcftools directly
# rather than guessing.
sub _short_opt_arity {
    my ($command) = @_;
    return undef unless defined $command && $command =~ /^[A-Za-z0-9_+-]+$/;
    my @help = `bcftools @{[ shq($command) ]} --help 2>&1`;
    return undef unless @help;
    my (%known, %file_opt, %long_arity, %all_long, %optarg_short, %optarg_long);
    for my $line (@help) {
        # (1) AMBIGUITY SET: every long-looking name anywhere in the help text.
        # Deliberately over-inclusive (it also picks names out of description
        # prose). An extra name can only make the abbreviation resolver MORE
        # conservative — never less — and the structured parse below cannot see
        # every shape bcftools uses. Missing names here is what let `--w` resolve
        # to `--write` when bcftools itself calls it ambiguous.
        while ($line =~ /--([A-Za-z0-9][A-Za-z0-9-]*)/g) { $all_long{$1} = 1 }

        # (2) STRUCTURED ARITY. Shapes seen in bcftools --help:
        #     "  -r, --regions REGION"        short + long, one space => takes a value
        #     "  -H, --no-header"             2+ spaces => flag
        #     "  -f,   --apply-filters LIST"  several spaces after the comma
        #     "  -c/C, --min-ac/--max-ac INT" two shorts, two longs
        #     "      --threads INT"           long only
        #     "  -W, --write-index[=FMT]"     OPTIONAL argument (see below)
        next unless $line =~ m{
            ^\s+
            (?: -([A-Za-z0-9]) (?: / ([A-Za-z0-9]) )? ,? \s+ )?  # -x,  -c/C,  or `-b  --long`
            --([A-Za-z0-9-]+) (?: /--([A-Za-z0-9-]+) )?          # --long or --min-ac/--max-ac
            (\[=[^\]]*\])?                                       # optional-argument suffix
            (\s+) (\S*)
        }x;
        my ($s1, $s2, $l1, $l2, $optarg, $gap, $ph) = ($1, $2, $3, $4, $5, $6, $7);

        # An OPTIONAL-argument option (`-W[=FMT]`) cannot be expressed as a simple
        # arity: `-W` alone is valid and `-Wz` means `--write-index=z`. Leave it out
        # of the short map so any bundle containing it FAILS CLOSED, and treat the
        # long form as value-less (getopt_long requires `=` for optional args, so it
        # never consumes the following argv token).
        if ($optarg) {
            # An OPTIONAL-argument option (`-W[=FMT]`). It stays OUT of %known so any
            # bundle containing it fails closed — `-Wz` is genuinely ambiguous. But it
            # is recorded here, because for VALUE-POSITION purposes it is arity 0:
            # getopt_long requires `=` for an optional argument, so a bare -W can
            # never consume the following token. Conflating "absent from the arity
            # map" with "might take a value" made `view ... -W --p_jobs 2` — an
            # ordinary command — be refused.
            $optarg_short{$s1} = 1 if defined $s1;
            $optarg_short{$s2} = 1 if defined $s2;
            for my $l (grep { defined } ($l1, $l2)) { $long_arity{$l} = 0; $optarg_long{$l} = 1 }
            next;
        }

        # one space followed by non-space => an argument placeholder follows
        my $takes = (length($gap) == 1 && length($ph)) ? 1 : 0;
        # Only a FILE-valued option reads stdin when given '-'. `stats -s -` means
        # "all samples" (placeholder LIST); `view -S -` means stdin (placeholder
        # FILE). Mark the distinction so the stdin check does not over-refuse.
        $takes = 2 if $takes && $ph =~ /FILE/i;
        for my $s (grep { defined } ($s1, $s2)) { $known{$s} = $takes }
        for my $l (grep { defined } ($l1, $l2)) {
            $long_arity{$l} = $takes;
            $file_opt{$l}   = 1 if $takes == 2;
        }
    }
    return %known
        ? { short => \%known, file_long => \%file_opt,
            long  => \%long_arity, all_long => \%all_long,
            optarg_short => \%optarg_short, optarg_long => \%optarg_long }
        : undef;
}

# Resolve a GNU getopt_long ABBREVIATION to its canonical long-option name.
# bcftools uses getopt_long, which accepts any UNAMBIGUOUS prefix: `--vcf-l` is
# `--vcf-list`, `--samples-f` is `--samples-file`. Every pbcftools guard compares
# option SPELLINGS, so an abbreviation slipped past all of them — `query
# --vcf-l=LIST -o MEMBER` truncated a list member to 0 bytes, and `--samples-f=-`
# silently produced the wrong sample set. Canonicalizing once, up front, is the
# only place this has to be handled; every later consumer then sees real names.
# Exact match wins even when it is a prefix of a longer option (getopt_long rule).
# Ambiguous or unknown prefixes are left untouched — bcftools rejects them itself.

# The long option names that designate an output destination, restricted to those the
# running subcommand actually has. `cnv` uses --output-dir; most commands --output.
# Every pbcftools option is --p_<name>, which is why it can never collide with a
# bcftools option (no bcftools long option contains an underscore, so none can have
# "p_..." as a prefix either). A --p<name> spelling without the underscore therefore
# belongs to neither tool: catch the plausible near-misses and name the right option,
# rather than letting bcftools report an opaque "unrecognized option". Only fires for
# tokens bcftools has no option for, so a genuine bcftools option is never
# intercepted.
sub _warn_renamed_wrapper_opts {
    my ($args, $info) = @_;
    my $names = ($info && $info->{all_long} && %{$info->{all_long}})
              ? $info->{all_long} : ($info ? $info->{long} : undef);
    return unless $names && %$names;
    my %renamed = (
        pmode => 'p_mode', pjobs => 'p_jobs', plen => 'p_len', pdir  => 'p_dir',
        ppre  => 'p_pre',  pref  => 'p_ref',  pfai => 'p_fai', pyes  => 'p_yes',
        pwal => 'p_wal', pmem => 'p_mem', pcpu => 'p_cpu',
        pint  => 'p_int',  ptry  => 'p_try',  pqueue => 'p_queue',
        paccount => 'p_account', 'pmem-inc' => 'p_mem_inc', 'pwal-inc' => 'p_wal_inc',
    );
    # $args has already had output options stripped and abbreviations canonicalised,
    # but it still contains bcftools option VALUES. Skip them: `query -f --pjobs FILE`
    # uses --pjobs as the format string, and serial bcftools prints it literally.
    my $expect = 0;
    my $long  = ($info && $info->{long})  ? $info->{long}  : {};
    my $short = ($info && $info->{short}) ? $info->{short} : {};
    for my $tok (@$args) {
        last if $tok eq '--';
        if ($expect) { $expect = 0; next }
        if ($tok =~ /^-([A-Za-z])$/) { $expect = 1 if $short->{$1}; next }
        unless ($tok =~ /^--([A-Za-z0-9-]+)(?:=|$)/) { next }
        my $name = $1;
        unless (exists $renamed{$name}) {
            my $canon = _resolve_long_name($name, $info);
            $expect = 1 if $tok !~ /=/ && defined $canon && ($long->{$canon} || 0);
            next;
        }
        # If bcftools has this option (exactly, or as an unambiguous abbreviation),
        # it is the user's and we must not interfere.
        next if exists $names->{$name};
        my @m = grep { index($_, $name) == 0 } keys %$names;
        next if @m;
        croak("Unknown option '--$name'.\n"
            . "  pbcftools options are spelled --p_<name>: use '--$renamed{$name}'.\n"
            . "  The --p_ prefix keeps them from ever colliding with a bcftools option,\n"
            . "  or with an abbreviation of one.");
    }
}

# A --p_<name> token is unmistakably ours by SPELLING, but spelling is only half the
# story: argv also has ROLES. `bcftools isec -f --p_len A PASS C` uses --p_len as the
# value of isec's -f, and GetOptions — which runs before the subcommand's option
# arity is known — cannot tell. It captured --p_len and then took the next token, the
# input file A, as our chunk length. The run continued with one input missing:
#   * it exited 0 with a wrong result, and
#   * the input/output alias guard never saw A, so `-o A` overwrote that very input.
# Renaming into the --p_ namespace fixed name collisions; it cannot fix role
# confusion, because a valid bcftools VALUE may legitimately look like anything.
#
# Detect it and stop. Making these commands actually WORK needs argv to be classified
# by position before GetOptions runs at all (see the ledger's Pattern B); until then
# refusing is the fail-closed answer, and it costs only commands that pass a
# pbcftools option name as a bcftools option's value.
sub _refuse_wrapper_opt_in_value_position {
    my ($argv, $info, $command) = @_;
    my $long  = ($info && $info->{long})  ? $info->{long}  : undef;
    my $short = ($info && $info->{short}) ? $info->{short} : undef;
    my $oshort = ($info && $info->{optarg_short}) ? $info->{optarg_short} : {};
    return unless $long && $short;

    # Our own options and whether they take a value — enough, on its own, to find the
    # bcftools subcommand without needing bcftools' arity first.
    my %ours = (
        p_mode=>1, p_jobs=>1, p_len=>1, p_dir=>1, p_pre=>1, p_ref=>1, p_fai=>1,
        p_index=>1, p_wal=>1, p_mem=>1, p_cpu=>1, p_int=>1, p_try=>1, p_mem_inc=>1,
        p_wal_inc=>1, p_queue=>1, p_account=>1,
        p_yes=>0,
    );

    # Locate the subcommand: the first non-option token that is not one of OUR values.
    my $start;
    for (my $i = 0; $i <= $#$argv; $i++) {
        my $t = $argv->[$i];
        if ($t =~ /^--([A-Za-z0-9_-]+)(?:=|$)/ && exists $ours{$1}) {
            $i++ if $ours{$1} && $t !~ /=/;      # skip a separated value
            next;
        }
        if ($t eq '-o' || $t eq '--output') { $i++; next }
        next if $t =~ /^-/;                      # some bcftools option; keep looking
        $start = $i; last;                       # the subcommand
    }
    return unless defined $start;

    # From the subcommand on, walk with BCFTOOLS' arity and flag any of our options
    # that lands where a value was expected.
    my $expect = 0;
    for my $i ($start + 1 .. $#$argv) {
        my $t = $argv->[$i];
        last if $t eq '--';                      # plugin arguments: not ours
        if ($expect) {
            if ($t =~ /^--([A-Za-z0-9_-]+)(?:=|$)/ && exists $ours{$1}) {
                croak("'--$1' appears where 'bcftools $command' expects an option "
                    . "VALUE.\n"
                    . "  pbcftools would consume it as its own option — and then take "
                    . "the\n  following argument as its value, silently removing that "
                    . "argument from\n  the bcftools command. Refusing, because the "
                    . "removed argument may be an\n  input file.\n"
                    . "  Rename the value, or run this command with bcftools directly.");
            }
            $expect = 0; next;
        }
        if ($t =~ /^--([A-Za-z0-9_-]+)(?:=(.*))?$/s) {
            my ($n, $eq) = ($1, $2);
            next if exists $ours{$n};            # ours, in an option position: fine
            my $canon = _resolve_long_name($n, $info);
            $expect = 1 if !defined $eq && defined $canon && ($long->{$canon} || 0);
            next;
        }
        # Short options, INCLUDING BUNDLES. `-Cf` is `-C -f`, and it is the LAST
        # letter that decides whether the next token is a value: `isec -Cf --p_len A`
        # makes --p_len the value of -f. Recognising only a standalone `-x` missed
        # that entirely and the bundle walked straight past this check.
        if ($t =~ /^-([A-Za-z].*)$/s && $t !~ /^--/) {
            my $rest = $1;
            while (length $rest) {
                my $c = substr($rest, 0, 1, '');
                if ($oshort->{$c}) {
                    # optional-argument option: takes only an ATTACHED value, so it
                    # cannot consume the following token
                    $rest = '';
                    last;
                }
                unless (exists $short->{$c}) {
                    # An unresolvable bundle: we cannot tell whether the next token is
                    # a value, so assume it may be. Being conservative here can only
                    # cost a refusal; guessing wrong the other way costs an input file.
                    # But an ATTACHED value settles it — `-W=tbi` carries its own, so
                    # it cannot consume what follows, and refusing there was a false
                    # positive on a perfectly ordinary command.
                    $expect = 1 unless length $rest;
                    $rest   = '';
                    last;
                }
                if ($short->{$c}) {              # takes a value
                    $expect = 1 unless length $rest;   # ...the NEXT token
                    $rest   = '';                      # ...or the attached remainder
                }
            }
            next;
        }
    }
}

sub _output_opt_names {
    my ($info) = @_;
    my $long = ($info && $info->{long}) ? $info->{long} : {};
    return grep { exists $long->{$_} } qw(output output-dir);
}

# Resolve a long option name that may be an abbreviation, using the same
# unique-prefix rule as getopt_long. Returns undef when unknown or ambiguous.
sub _resolve_long_name {
    my ($name, $info) = @_;
    my $names = ($info && $info->{all_long} && %{$info->{all_long}})
              ? $info->{all_long} : ($info ? $info->{long} : undef);
    return undef unless $names && %$names;
    return $name if exists $names->{$name};
    my @m = grep { index($_, $name) == 0 } keys %$names;
    return @m == 1 ? $m[0] : undef;
}

# Walk the ORIGINAL argv and return the value of the LAST output option, in any
# spelling (-o, -oVALUE, --output, --output=, --output-dir, or an unambiguous
# abbreviation of either). undef if there is none.
sub _resolve_output_dest {
    my ($argv, $info) = @_;
    my %out = map { $_ => 1 } _output_opt_names($info);
    return undef unless %out;
    my $found;
    for (my $i = 0; $i <= $#$argv; $i++) {
        my $t = $argv->[$i];
        last if $t eq '--';
        if    ($t eq '-o')            { $found = $argv->[$i + 1]; $i++; next }
        elsif ($t =~ /^-o(.+)$/s)     { $found = $1; next }
        next unless $t =~ /^--([A-Za-z0-9-]+)(?:=(.*))?$/s;
        my ($name, $attached) = ($1, $2);
        my $canon = _resolve_long_name($name, $info);
        next unless defined $canon && $out{$canon};
        if (defined $attached) { $found = $attached }
        else                   { $found = $argv->[$i + 1]; $i++ }
    }
    return $found;
}

# Remove every output option (and its value) from the worker argv. pbcftools writes
# each chunk to a path it chooses, so any surviving -o/--output/--output-dir would
# either be overridden confusingly or, worse, override the staging path and send all
# workers into the same directory.
sub _strip_output_opts {
    my ($args, $info) = @_;
    my %out = map { $_ => 1 } _output_opt_names($info);
    return unless %out;
    my @keep;
    my $after_ddash = 0;
    for (my $i = 0; $i <= $#$args; $i++) {
        my $t = $args->[$i];
        if ($t eq '--') { $after_ddash = 1; push @keep, $t; next }
        if ($after_ddash) { push @keep, $t; next }
        if ($t eq '-o')        { $i++; next }        # drop it and its value
        if ($t =~ /^-o(.+)$/s) { next }
        if ($t =~ /^--([A-Za-z0-9-]+)(?:=(.*))?$/s) {
            my ($name, $attached) = ($1, $2);
            my $canon = _resolve_long_name($name, $info);
            if (defined $canon && $out{$canon}) {
                $i++ unless defined $attached;        # separated value
                next;
            }
        }
        push @keep, $t;
    }
    @$args = @keep;
}

sub _canonicalize_long_opts {
    my ($args, $info) = @_;
    my $long  = $info && $info->{long}  ? $info->{long}  : undef;
    my $short = $info && $info->{short} ? $info->{short} : {};
    # Ambiguity is judged against the FULL name set, not the (necessarily partial)
    # structured arity map: resolving a prefix that bcftools would reject as
    # ambiguous made pbcftools succeed where a serial run errors out — and, for a
    # value-taking winner, silently swallow the next argv token (an input file).
    my $names = ($info && $info->{all_long} && %{$info->{all_long}})
              ? $info->{all_long} : $long;
    return [@$args] unless $long && %$long && $names;

    my @out;
    my ($after_ddash, $expect_value) = (0, 0);
    for my $tok (@$args) {
        if ($tok eq '--') { $after_ddash = 1; $expect_value = 0; push @out, $tok; next }
        # An option VALUE is never itself an option, even if it looks like one.
        if ($expect_value) { $expect_value = 0; push @out, $tok; next }
        if ($after_ddash)  { push @out, $tok; next }

        if ($tok =~ /^--([A-Za-z0-9-]+)(=.*)?$/s) {
            my ($name, $eq) = ($1, $2);
            my $canon = $name;
            unless (exists $names->{$name}) {          # exact spelling wins
                my @m = grep { index($_, $name) == 0 } keys %$names;
                $canon = $m[0] if @m == 1;             # UNIQUE prefix => canonical
            }                                          # 0 or 2+ matches => untouched
            $expect_value = 1 if !defined $eq && ($long->{$canon} || 0);
            push @out, "--$canon" . (defined $eq ? $eq : '');
            next;
        }
        if ($tok =~ /^-([A-Za-z])$/) { $expect_value = 1 if $short->{$1}; push @out, $tok; next }
        push @out, $tok;
    }
    return \@out;
}

# Expand short-option bundles in-place. Returns a NEW arrayref, or undef if any
# bundle cannot be resolved (caller must then fail closed / passthrough).
sub _expand_short_bundles {
    my ($args, $command) = @_;
    # Nothing that looks like a bundle -> no work, no bcftools call.
    my $needs = 0;
    for my $t (@$args) {
        last if $t eq '--';
        $needs = 1, last if $t =~ /^-[A-Za-z][^-]/ && $t !~ /^--/;
    }
    return [@$args] unless $needs;

    my $info = _short_opt_arity($command);
    return undef unless $info;
    my $arity = $info->{short};

    my @out;
    my $after_ddash = 0;
    my $expect_value = 0;      # previous token was an option awaiting its value
    for my $tok (@$args) {
        if ($tok eq '--') { $after_ddash = 1; $expect_value = 0; push @out, $tok; next }
        # A VALUE is never an option, even when it starts with '-' (e.g. the
        # `-both` of `norm -m -both`, or a negative number). Expanding it as a
        # bundle would fabricate options the user never wrote.
        if ($expect_value) { $expect_value = 0; push @out, $tok; next }
        if ($after_ddash || $tok !~ /^-[A-Za-z]/ || $tok =~ /^--/) { push @out, $tok; next }
        if (length($tok) == 2) {                       # plain -x: may take the NEXT token
            my $c = substr($tok, 1, 1);
            $expect_value = 1 if $arity->{$c};
            push @out, $tok; next;
        }
        my $rest = substr($tok, 1);          # drop the leading '-'
        my @exp;
        while (length $rest) {
            my $c = substr($rest, 0, 1, '');
            return undef unless exists $arity->{$c};   # unknown letter -> fail closed
            push @exp, "-$c";
            if ($arity->{$c}) {                        # takes a value
                if (length $rest) { push @exp, $rest }  # attached
                else              { $expect_value = 1 } # value is the NEXT argv token
                $rest = '';
            }
        }
        push @out, @exp;
    }
    return \@out;
}

sub _collect_positional_files {
    my ($args, $arity, $long_arity) = @_;
    # $arity (letter => takes-a-value), read from `bcftools <cmd> --help`, is
    # AUTHORITATIVE when supplied. The regex fallback below is a fixed guess that
    # is wrong for some commands — e.g. it lists 'a' as value-taking, but
    # `norm -a/--atomize` is a FLAG, so it would swallow the positional input.
    my @files;
    my $skip_next = 0;
    my $after_ddash = 0;
    for my $i (1 .. $#$args) {
        if ($skip_next) { $skip_next = 0; next; }
        my $arg = $args->[$i];
        if (!$after_ddash && $arg eq '--') { $after_ddash = 1; next; }
        # After '--', every existing token is an operand candidate — even one whose
        # basename starts with '-'. A conservative extra candidate only trips the
        # >1-primary passthrough (losing parallelism), which fails safe.
        if ($after_ddash) {
            push @files, $arg if -e $arg;
            next;
        }
        if ($arg =~ /^-/) {
            # `--opt=value` carries its own value; a bare value-taking option
            # consumes the following argument. NOTE: -W/--write-index is EXCLUDED —
            # it is optional-attached (bare `-W` takes no value), so consuming the
            # next token here would hide a positional input from the alias guard.
            # (Commands whose inputs must be identified exactly use the structural
            # ArgParser; this is the conservative fallback for the rest.)
            next if $arg =~ /=/;
            if ($arity && $arg =~ /^-([A-Za-z])$/ && exists $arity->{$1}) {
                $skip_next = 1 if $arity->{$1};       # authoritative: real arity
                next;
            }
            # Long options, from the runtime help map — including ABBREVIATIONS,
            # resolved by unique prefix exactly as getopt_long does. Without this,
            # `--samples-f s.txt` left `s.txt` looking like a positional input, and
            # the provenance permutation moved it to the end of the recorded
            # command (producing a header a direct bcftools run never writes).
            if ($long_arity && $arg =~ /^--([A-Za-z0-9-]+)$/) {
                my $n = $1;
                my $a2 = $long_arity->{$n};
                unless (defined $a2) {
                    my @m = grep { index($_, $n) == 0 } keys %$long_arity;
                    $a2 = $long_arity->{$m[0]} if @m == 1;
                }
                if (defined $a2) { $skip_next = 1 if $a2; next }
            }
            $skip_next = 1 if $arg =~ /^(?:-[rRtTsSifFhoOaeGgwmMdDxk]
                |--regions|--regions-file|--targets|--targets-file|--samples
                |--samples-file|--include|--exclude|--fasta-ref|--output-type
                |--threads|--annotations|--header-lines|--use-header
                |--rename-chrs|--collapse|--apply-filters|--ploidy-file)$/x;
            next;
        }
        push @files, $arg if -e $arg;
    }
    return @files;
}

# Split bcftools command into per-region jobs
# $multi_files: arrayref of input file paths (for multi_input mode like merge/isec)
sub bcftools_split_jobs {
    my ($command, $bcftools_cmd, $ifile, $ofile, $pdir, $ppre, $plen, $regions, $multi_files, $whole_chrom,
        $user_region_jobs, $first_overlap) = @_;
    $first_overlap = '' unless defined $first_overlap;   # '' = bcftools default (record)

    my (undef, undef, $bname) = File::Spec->splitpath($ofile);

    # For multi_input mode the caller already removed EVERY -l/--file-list
    # occurrence from the args (structurally, by argv index via the ArgParser
    # scan) before building $bcftools_cmd, so no fragile regex strip of the
    # serialized string is needed — each chunk gets its own generated `-l chunk_list`.
    my $cmd_str = $bcftools_cmd;

    my $jobs = [];
    my $i = 0;
    my $job_list_file = File::Spec->catfile($pdir, 'para_job.lst');
    open(my $job_fh, ">", $job_list_file) or croak("Cannot open '$job_list_file': $!");

    # $overlap: the --regions-overlap value for this chunk ('pos', 'record', or ''
    # = bcftools default = record). Callers pass $first_overlap for the FIRST
    # chunk of a region unit (its outer-left edge — captures records spanning in
    # from before, as serial -r does) and 'pos' for every internal chunk (so a
    # record spanning an internal boundary lands in exactly one chunk, no dup).
    # Per-run nonce (this process's PID) folded into the *scheduler* job name so
    # it is unique across concurrent runs and retries. The steady-state poll keys
    # jobs by this name and the timeout-recovery lookup (squeue --name / bjobs -J)
    # must not match a same-prefix job from another run. Chunk *filenames* keep the
    # short $job_name (they are already unique within this run's private $pdir).
    my $run_nonce = $$;
    my $make_job = sub {
        my ($region, $overlap) = @_;
        my $overlap_opt = (defined $overlap && length $overlap) ? "--regions-overlap $overlap " : "";
        $i++;
        my $job_name = sprintf("%s%04d", $ppre, $i);
        my $sched_name = sprintf("%s%d_%04d", $ppre, $run_nonce, $i);
        # Build a safe, unique per-job filename. Sanitize region punctuation (":",
        # ",", "-") so multi-interval per-contig user regions still yield a valid
        # name (e.g. "1:50-60,1:100-110").
        (my $suf = $region) =~ s/[^\w.\-]+/_/g;
        my $fname = File::Spec->catfile($pdir, "$job_name.$suf.$bname");
        my $rq = shq($region);   # region may contain braces/commas -> quote it
        # -o goes in the bcftools-option section (before any plugin `--`); stdout
        # commands (stats/roh/cnv) use a shell redirect that must stay at the end.
        # cnv used to need a per-contig subdirectory here, because its -o is a
        # DIRECTORY of sample-named files that carry no contig. It now runs serially
        # (see %CMD_MODE), so the parallel path has exactly one shape again.
        my ($out_opt, $redir);
        $out_opt = $STDOUT_CMD{$command} ? "" : "-o " . shq($fname);
        $redir   = $STDOUT_CMD{$command} ? " > " . shq($fname) : "";

        my $cmd;
        if ($multi_files) {
            # Multi-input mode: write a per-chunk file list and pass via -l
            my $chunk_list = File::Spec->catfile($pdir, "$job_name.filelist");
            open(my $cl_fh, '>', $chunk_list) or croak("Cannot open '$chunk_list': $!");
            # CHECK writes: a truncated per-chunk input list would silently make the
            # chunk merge/isec only a PREFIX of the inputs (dropping samples/files).
            say $cl_fh $_ or croak("Write to '$chunk_list' failed: $!") for @$multi_files;
            close($cl_fh) or croak("Close of '$chunk_list' failed: $!");
            $cmd = "bcftools $command -r $rq $overlap_opt-l " . shq($chunk_list) . " $out_opt $cmd_str$redir";
        } else {
            $cmd = "bcftools $command -r $rq $overlap_opt$out_opt $cmd_str$redir";
        }

        push @{$jobs}, {
            name   => $sched_name,   # scheduler/poll key — run-unique
            region => $region,
            cmd    => $cmd,
            file   => $fname,
            status => '',
            t0     => time(),
        };
        say $job_fh "$cmd  # $job_name";
    };

    # User -r (boundary-sensitive) path: one job per contig; the region string
    # carries all of that contig's intervals. Single chunk -> default overlap
    # ($use_pos=0), matching serial for that contig.
    # Coalesced per-contig user workers (multi-interval contigs, or boundary-
    # sensitive): one worker each, single chunk -> outer-edge overlap. Then fall
    # through to sub-split any single-interval region-safe contigs in @regions.
    if ($user_region_jobs) {
        $make_job->($_, $first_overlap) for @$user_region_jobs;
    }

    for my $rtuple (@{$regions}) {
        my ($chr, $reg_start, $reg_end) = @{$rtuple};
        my $reg_size = $reg_end - $reg_start + 1;

        # Chromosome mode: one worker per region unit, NEVER sub-split — so
        # sequential/whole-contig algorithms (roh HMM, and — once routed here —
        # csq transcripts, norm -f left-align, filter gaps, gVCF blocks) see each
        # unit whole in one process. A unit is a full contig (genome-wide) or a
        # user-supplied region (which the user chose as the boundary).
        # Otherwise: don't split regions smaller than 1.5x chunk size.
        if ($whole_chrom || $reg_size <= $plen * 1.5) {
            # Single chunk of this region unit -> outer-edge overlap.
            $make_job->("$chr:$reg_start-$reg_end", $first_overlap);
        } else {
            # Sub-split into chunks of $plen. FIRST chunk -> outer-edge overlap
            # (captures records spanning in from before the region); the rest ->
            # --regions-overlap pos (POS ownership, exactly one chunk per record).
            my ($s, $e) = ($reg_start, $reg_start);
            my $first = 1;
            while ($e < $reg_end) {
                $e = $s + $plen - 1;
                $e = $reg_end if ($e > $reg_end);
                $make_job->("$chr:$s-$e", $first ? $first_overlap : 'pos');
                $s = $e + 1;
                $first = 0;
            }
        }
    }
    close $job_fh;

    return $jobs;
}

# Get chromosome names and lengths
# Priority: 1) VCF header contigs  2) Reference genome fallback  3) bcftools index -s LENGTH
# Built-in human chromosome lengths for --p_ref (GRCh37/38, hg19/hg38 aliases).
# SINGLE source of truth shared by the single-input get_chr_sizes() and the
# multi-input merge length guard, so --p_ref behaves identically in both and needs
# no external .fai. Returns { contig => length } with names matching the caller's
# prefix convention (chr1 vs 1); {} when $ref is not a recognized human build.
# Reference lengths are fixed constants, so rebuilding per call is negligible.
sub _builtin_ref_lengths {
    my ($ref, $has_chr_prefix) = @_;
    return {} unless defined $ref && length $ref;
    my %REF_LENGTH = (
        '37' => {
            '1' => 249250621, '2' => 243199373, '3' => 198022430, '4' => 191154276, '5' => 180915260,
            '6' => 171115067, '7' => 159138663, '8' => 146364022, '9' => 141213431, '10' => 135534747,
            '11' => 135006516, '12' => 133851895, '13' => 115169878, '14' => 107349540, '15' => 102531392,
            '16' => 90354753, '17' => 81195210, '18' => 78077248, '19' => 59128983, '20' => 63025520,
            '21' => 48129895, '22' => 51304566, 'X' => 155270560, 'Y' => 59373566, 'M' => 16569,
        },
        '38' => {
            '1' => 248956422, '2' => 242193529, '3' => 198295559, '4' => 190214555, '5' => 181538259,
            '6' => 170805979, '7' => 159345973, '8' => 145138636, '9' => 138394717, '10' => 133797422,
            '11' => 135086622, '12' => 133275309, '13' => 114364328, '14' => 107043718, '15' => 101991189,
            '16' => 90338345, '17' => 83257441, '18' => 80373285, '19' => 58617616, '20' => 64444167,
            '21' => 46709983, '22' => 50818468, 'X' => 156040895, 'Y' => 57227415, 'M' => 16569,
        },
    );
    $ref = "GRCh37" if uc($ref) eq "HG19";
    $ref = "GRCh38" if uc($ref) eq "HG38";
    return {} unless $ref =~ /(37|38)/;
    my $raw = $REF_LENGTH{$1} or return {};
    my %map;
    for my $bare (keys %$raw) {
        my $name = $has_chr_prefix ? "chr$bare" : $bare;
        $map{$name} = $raw->{$bare};
    }
    return \%map;
}

sub get_chr_sizes {
    my ($vfile, $ref, $fai) = @_;   # $fai: optional fasta index (.fai) path

    # --- Step 1: Get contigs from index (always available for indexed files) ---
    my $bcf_index_cmd = "bcftools index -s " . shq($vfile) . " 2>/dev/null";
    my $index_output = `$bcf_index_cmd`;
    if ($? != 0) {
        # Retry with stderr to get the actual error message
        my $err = `bcftools index -s @{[ shq($vfile) ]} 2>&1 1>/dev/null`;
        croak("Error: bcftools index -s failed.\n$err\n"
            . "Is the file indexed? Run: bcftools index " . shq($vfile));
    }

    my @index_chrs;
    my %index_nvar;
    my %index_len;

    foreach my $line (split /\n/, $index_output) {
        next unless $line =~ /\S/;
        my ($chr, $len, $nvar) = split /\t/, $line;
        next unless defined $chr && $chr ne '' && $chr !~ /^\[/;  # skip warning lines
        push @index_chrs, $chr;
        $index_nvar{$chr} = (defined $nvar && $nvar =~ /^\d+$/) ? $nvar : 0;
        # bcftools index -s reports '.' when length is unknown
        $index_len{$chr}  = (defined $len && $len =~ /^\d+$/ && $len > 0) ? $len : 0;
    }
    croak("No contigs found in index for '$vfile'.") unless @index_chrs;

    # Detect chr-prefix convention from data
    my $has_chr_prefix = ($index_chrs[0] =~ /^chr/i) ? 1 : 0;

    # --- Step 2: Get contig lengths from VCF header ---
    my $contigs_from_vcf = {};
    if ($vfile) {
        my $meta = parse_vcf_meta($vfile);
        # parse_vcf_meta stores a repeated header key as an arrayref but a
        # single occurrence as a plain hashref. Normalize so a VCF with exactly
        # one ##contig line (e.g. a per-chromosome file) doesn't crash.
        my @contigs;
        if (defined $meta->{'contig'}) {
            @contigs = ref($meta->{'contig'}) eq 'ARRAY'
                     ? @{$meta->{'contig'}} : ($meta->{'contig'});
        }
        for my $c (@contigs) {
            next unless ref($c) eq 'HASH';
            $contigs_from_vcf->{$c->{'ID'}} = $c->{'length'} if defined $c->{'length'};
        }
        $ref = $ref || $meta->{'reference'} ||
               (@contigs && ref($contigs[0]) eq 'HASH' ? $contigs[0]->{'assembly'} : '');
    }

    # --- Step 3a: Lengths from a user-supplied fasta index (.fai), any organism ---
    # .fai columns: name<TAB>length<TAB>offset<TAB>linebases<TAB>linewidth.
    # Names are literal and matched directly against contig names (no prefix munging).
    my $fai_len = {};
    if (defined $fai && length $fai) {
        open(my $fh, '<', $fai) or croak("Cannot open --p_fai file '$fai': $!");
        while (my $line = <$fh>) {
            next unless $line =~ /\S/;
            my ($name, $len) = split /\t/, $line;
            $fai_len->{$name} = $len if defined $name && defined $len && $len =~ /^\d+$/ && $len > 0;
        }
        close $fh;
        croak("--p_fai file '$fai' has no usable 'name<TAB>length' lines.") unless %$fai_len;
    }

    # --- Step 3b: Built-in human reference length map (fallback only) ---
    # UCSC/GRCh aliases: hg19 == GRCh37, hg38 == GRCh38 (they differ only in the
    # mitochondrion by 2 bp, immaterial for region splitting; use --p_fai for exact
    # chrM bounds if that ever matters). Shared table lives in
    # _builtin_ref_lengths() so single-input and multi-input merge agree.
    my $ref_len_map = _builtin_ref_lengths($ref, $has_chr_prefix);

    # --- Step 4: Resolve lengths for each contig ---
    # Priority: VCF header > user .fai > built-in human table > index-derived.
    my $chr_len_final = {};
    my $used_index_fallback = 0;

    foreach my $chr (@index_chrs) {
        if (defined $contigs_from_vcf->{$chr} && $contigs_from_vcf->{$chr} > 0) {
            $chr_len_final->{$chr} = $contigs_from_vcf->{$chr};
        } elsif (defined $fai_len->{$chr} && $fai_len->{$chr} > 0) {
            $chr_len_final->{$chr} = $fai_len->{$chr};
        } elsif (defined $ref_len_map->{$chr} && $ref_len_map->{$chr} > 0) {
            $chr_len_final->{$chr} = $ref_len_map->{$chr};
        } elsif ($index_len{$chr} && $index_len{$chr} > 0) {
            $chr_len_final->{$chr} = $index_len{$chr};
            $used_index_fallback = 1;
        } else {
            croak("Cannot determine length for contig '$chr'.\n"
                . "VCF header has no ##contig=<ID=$chr,length=...>, and no length was\n"
                . "found from --p_fai / --p_ref / the index.\n"
                . "Fix: pass --p_fai ref.fa.fai (any organism), or --p_ref 37|38 for human,\n"
                . "or add contig headers: bcftools reheader -f ref.fa.fai \"$vfile\".");
        }
    }

    if ($used_index_fallback) {
        warn "Note: some contigs lack a ##contig length header; using the "
            . "index-derived length (safe for splitting — it bounds where records exist).\n";
    }

    # --- Step 5: Preserve the file's own contig order ---
    # `bcftools index -s` lists contigs in header order; keep that so the
    # concatenated output matches the input's contig ordering. Organism-agnostic:
    # the old human-karyotype re-sort mis-ordered non-human / odd-named contigs
    # and could produce an out-of-order concatenation.
    my @final_chrs = @index_chrs;

    show_message(sprintf("\nFound %d contigs (%s-prefixed), %d total variants\n",
        scalar @final_chrs,
        $has_chr_prefix ? "chr" : "bare",
        List::Util::sum(values %index_nvar) // 0));

    # Contigs the caller may legitimately reference with an explicit -r region even
    # though THIS file carries no records for them: declared in the header, or a
    # known reference contig via --p_fai/--p_ref. Region validation uses this so a
    # valid-but-empty contig (a chromosome present in the reference but with no
    # variants here, or one that only appears in a LATER merge input) is not
    # mistaken for a typo. Length priority mirrors Step 4: header > --p_fai > --p_ref.
    my %region_len;
    for my $c (keys %$contigs_from_vcf) { $region_len{$c} = $contigs_from_vcf->{$c} if $contigs_from_vcf->{$c} && $contigs_from_vcf->{$c} > 0; }
    for my $c (keys %$fai_len)          { $region_len{$c} ||= $fai_len->{$c}; }
    for my $c (keys %$ref_len_map)      { $region_len{$c} ||= $ref_len_map->{$c}; }

    return (\@final_chrs, $chr_len_final, \%index_nvar, \%region_len);
}

# Parse VCF meta/header lines
sub parse_vcf_meta {
    my $file = shift;

    # Read the header via `bcftools view -h` so this works for VCF, VCF.gz, AND
    # BCF (gzip -dc would produce binary garbage on a BCF). view -h stops at the
    # header, so this does not stream the records.
    open(my $vcf_fh, '-|', 'bcftools', 'view', '-h', $file)
        or croak("Cannot read header of '$file' via bcftools: $!");

    my $meta;
    while (my $line = <$vcf_fh>) {
        chomp $line;
        if ($line =~ /^##(\w+)=(.*)$/) {
            my $key = $1;
            my $val = $2;
            my $item;

            if ($val =~ /^<(.*)>$/) {
                my @els = quotewords(',', 1, $1);
                foreach my $el (@els) {
                    if ($el =~ /^(\w+)=(.*)/) {
                        $item->{$1} = $2;
                        if (($2 =~ /^"([^']+): '([^']+)'\s*"$/) || ($2 =~ /^"([^:]+ Format): ([^"]+)\s*"$/)) {
                            $item->{'vdesc'} = $1;
                            $item->{'vkeys'} = [split /\s*\|\s*/, $2];
                        }
                    }
                }
            } else {
                $item = $val;
            }

            if (defined $meta->{$key}) {
                $meta->{$key} = [$meta->{$key}] unless (ref $meta->{$key} eq 'ARRAY');
                push @{$meta->{$key}}, $item;
            } else {
                $meta->{$key} = $item;
            }
        } elsif ($line =~ /^#CHROM/) {
            last;
        } elsif ($line !~ /^#/) {
            last;
        }
    }
    close $vcf_fh;
    return($meta);
}

# Append plain tabular text file with header consistency check
# Header lines that legitimately DIFFER between chunks and must not be treated as
# a header mismatch. `bcftools roh` echoes its own invocation, which carries this
# chunk's -r; every other header line must still match exactly (a real column or
# output-type difference is still a hard error).
sub _norm_tab_header {
    my ($h) = @_;
    return $h unless defined $h;
    return join("", grep { !/^#\s*The command line was:/ } split(/^/, $h));
}

sub append_tab_file {
    my ($ofile, $ifile, $header, $nhdr) = @_;
    my $h = "";

    if (-z $ifile) {
        unlink($ifile) or warn "Failed to unlink '$ifile': $!";
        return $header;
    }

    # Fixed-header text (query, $nhdr defined): keep the first chunk whole; for
    # later chunks drop exactly $nhdr leading header lines (0, or 1 with -H/-HH)
    # and append the rest verbatim. Data lines may start with '#', so content is
    # never inspected — this is what prevents dropping real '#'-prefixed rows.
    if (defined $nhdr) {
        if (! -e $ofile) {
            move($ifile, $ofile) or croak("Failed to move '$ifile' to '$ofile': $!");
        } else {
            open(my $in_fh, "<", $ifile) or croak("Cannot open $ifile: $!");
            open(my $out_fh, ">>", $ofile) or croak("Cannot open $ofile for append: $!");
            my $ln = 0;
            my $io_error = '';
            while (my $line = <$in_fh>) {
                next unless ++$ln > $nhdr;
                unless (print $out_fh $line) {
                    $io_error = "Append to '$ofile' failed: $!";
                    last;
                }
            }
            # A read error mid-chunk looks like EOF and would silently append only a
            # PREFIX of the chunk's rows. Require a clean read before trusting it.
            $io_error ||= "Read error on chunk '$ifile' (partial text is unsafe): $!"
                if $in_fh->error;
            unless (close($in_fh)) {
                $io_error ||= "Close of input chunk '$ifile' failed: $!";
            }
            # Buffered writes are committed here; close failure is a failed run,
            # not success with a truncated query result.
            unless (close($out_fh)) {
                $io_error ||= "Close of '$ofile' failed (text output may be truncated): $!";
            }
            if ($io_error) {
                if (-e $ofile && !unlink($ofile)) {
                    $io_error .= "; cannot remove partial output '$ofile': $!";
                }
                croak($io_error);                  # chunk remains for diagnosis/retry
            }
            unlink($ifile) or warn "Failed to unlink '$ifile': $!";
        }
        return $header;
    }

    if (! -e $ofile) {
        # First file: move directly
        move($ifile, $ofile) or croak("Failed to move '$ifile' to '$ofile': $!");
        open(my $in_fh, "<", $ofile) or croak("Cannot open $ofile: $!");
        while (my $line = <$in_fh>) {
            if ($line =~ /^#/) {
                $header .= $line;
            } else {
                $header = scalar(split /\t/, $line) if $header eq '';
                last;
            }
        }
        close $in_fh;
    } else {
        # Append subsequent files
        open(my $in_fh, "<", $ifile) or croak("Cannot open $ifile: $!");
        open(my $out_fh, ">>", $ofile) or croak("Cannot open $ofile for append: $!");
        while (my $line = <$in_fh>) {
            if ($h eq '-1') {
                print $out_fh $line or croak("Append to '$ofile' failed: $!");
            } elsif ($line =~ /^#/) {
                $h .= $line;
            } else {
                $h = scalar(split /\t/, $line) if $h eq '';
                if (_norm_tab_header($h) ne _norm_tab_header($header)) {
                    croak("Header/column mismatch. Expected: $header, Got: $h");
                }
                print $out_fh $line or croak("Append to '$ofile' failed: $!");
                $h = '-1';
            }
        }
        # A read error mid-chunk looks like EOF and would silently append only a
        # PREFIX of the chunk's rows — fail closed (F7, generic text branch).
        if ($in_fh->error) {
            close($in_fh); close($out_fh);
            unlink($ofile) if -e $ofile;   # don't leave a truncated TSV as "success"
            croak("Read error on chunk '$ifile' (partial text is unsafe): $!");
        }
        close $in_fh;
        # CHECK close: buffered appended data is flushed here — a silent failure
        # would truncate the TSV while the run still reported success.
        close($out_fh) or croak("Close of '$ofile' failed (text output may be truncated): $!");
        unlink($ifile) or warn "Failed to unlink '$ifile': $!";
    }
    return $header;
}

# Format base pairs for display
sub _format_bp {
    my ($bp) = @_;
    if ($bp >= 1_000_000) {
        return sprintf("%.1fMB", $bp / 1_000_000);
    } elsif ($bp >= 1_000) {
        return sprintf("%.1fKB", $bp / 1_000);
    }
    return "${bp}bp";
}

# Read entire file contents
sub _slurp {
    my ($path) = @_;
    return '' unless defined $path && -e $path && -s $path;
    open my $fh, '<', $path or return '';
    binmode $fh;
    local $/;
    my $s = <$fh>;
    close $fh;
    return defined $s ? $s : '';
}

__END__

=head1 NAME

pbcftools - Parallelized BCFtools wrapper

=head1 SYNOPSIS

    pbcftools [bcftools_command] [bcftools_options] -o output_file [pbcftools_options]

=head1 PBCFTOOLS OPTIONS

    --p_mode <local|lsf|slurm>  Execution mode (default: local)
    --p_jobs <int>        Number of parallel jobs (auto = 80% of logical cores,
                          capped at the chunk count, for local;
                          required for lsf/slurm)
    --p_len  <str>        Region chunk size (default: 10MB)
    --p_dir  <dir>        Temp directory (default: system temp)
    --p_pre  <str>        Job name prefix (default: pbcf)

    --p_ref  <37|38|hg19|hg38>  Built-in human chromosome sizes (fallback)
    --p_fai  <ref.fa.fai> Fasta index for contig sizes (any organism; fallback)

    --p_index <0|1>       Index the final output (default: 1, CSI). A user-supplied
                          -W/--write-index overrides this and selects the format;
                          it is never passed to the individual chunk jobs, which
                          have no use for an index.

    --p_yes               Skip confirmation prompts (for scripting); also disables fail-stop

    LSF/Slurm options:
    --p_wal    <str>      Wall time per job (default: 1hr; e.g. 2h, 90m, 1:30)
    --p_mem    <str>      Memory per job (default: 8GB)
    --p_cpu    <int>      CPUs per job (default: 1)
    --p_int    <int>      Poll interval in seconds (default: 10)
    --p_try    <int>      Max retries per job (default: 3)

    --p_queue  <str>      Queue/partition (LSF bsub -q; Slurm --partition)
    --p_account <str>     Project/account (LSF bsub -P; Slurm --account)

=head1 EXAMPLES

    # Local: 12 workers, 10MB chunks
    pbcftools query -f '%CHROM\t%POS\n' input.vcf.gz -o out.tsv --p_jobs 12 --p_len 10MB

    # Plugin (options after --); `plugin fill-tags` also works. Runs unparallelized
    # in v1.0 -- see KNOWN_ISSUES KI-8.
    pbcftools +fill-tags input.vcf.gz -o out.vcf.gz -Oz --p_jobs 8 -- -t AN,AC,AF

    # LSF cluster: 500 concurrent jobs, 5MB chunks
    pbcftools view -S samples.txt input.vcf.gz -o out.vcf.gz \
        --p_mode lsf --p_jobs 500 --p_len 5MB --p_wal 2h --p_mem 16GB [--p_queue Q --p_account P]

    # Slurm cluster
    pbcftools norm -m -both input.vcf.gz -o out.vcf.gz \
        --p_mode slurm --p_jobs 100 --p_len 5MB --p_wal 2h --p_mem 16GB

=cut
