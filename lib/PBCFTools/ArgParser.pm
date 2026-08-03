package PBCFTools::ArgParser;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(scan_command_argv);

# Bounded bcftools argv schemas.  These are intentionally limited to commands
# for which pbcftools must know every primary input (multi-input splitting,
# two-file stats gating, or multi-input alias protection).  A command/version
# option not described here makes the scan ambiguous; callers must then keep the
# original argv and run plain bcftools rather than infer an unsafe split.
#
# Arity is one of:
#   none      option takes no argument
#   required  argument is attached or consumes the next argv element
#   optional  argument is accepted only when attached (`-Wc`, `--write-index=c`)
# A [arity, role] entry additionally records occurrences used by the caller.
my %SCHEMA = (
    merge => {
        short => {
            '0' => 'none',
            (map { $_ => 'required' } qw(f F g i L m M o O r R v)),
            l => ['required', 'file_list'],
            W => 'optional',
        },
        long => {
            (map { $_ => 'none' } qw(
                force-no-index force-samples force-single print-header
                missing-to-ref no-index no-version
            )),
            (map { $_ => 'required' } qw(
                use-header apply-filters filter-logic gvcf info-rules
                local-alleles merge missing-rules output output-type regions
                regions-file regions-overlap threads verbosity
            )),
            'file-list'  => ['required', 'file_list'],
            'write-index' => 'optional',
        },
    },
    isec => {
        short => {
            C => 'none',
            (map { $_ => 'required' } qw(c e f i n o O p r R t T v w)),
            l => ['required', 'file_list'],
            W => 'optional',
        },
        long => {
            (map { $_ => 'none' } qw(complement no-version)),
            (map { $_ => 'required' } qw(
                collapse exclude apply-filters include nfiles output
                output-type prefix regions regions-file regions-overlap targets
                targets-file targets-overlap threads verbosity write
            )),
            'file-list'   => ['required', 'file_list'],
            'write-index' => 'optional',
        },
    },
    stats => {
        short => {
            '1' => 'none',
            I   => 'none',
            (map { $_ => 'required' } qw(c d e E f F i r R s S t T u v)),
        },
        long => {
            (map { $_ => 'none' } qw(1st-allele-only split-by-ID)),
            (map { $_ => 'required' } qw(
                af-bins af-tag collapse depth exclude exons apply-filters
                fasta-ref include regions regions-file regions-overlap samples
                samples-file targets targets-file targets-overlap user-tstv
                threads verbosity
            )),
        },
    },
    concat => {
        short => {
            (map { $_ => 'none' } qw(a c D G l n)),
            (map { $_ => 'required' } qw(d o O q r R v)),
            f => ['required', 'file_list'],
            W => 'optional',
        },
        long => {
            (map { $_ => 'none' } qw(
                allow-overlaps compact-PS remove-duplicates drop-genotypes
                ligate ligate-force ligate-warn no-version naive naive-force
            )),
            (map { $_ => 'required' } qw(
                rm-dups output output-type min-PQ regions regions-file
                regions-overlap threads verbosity
            )),
            'file-list'   => ['required', 'file_list'],
            'write-index' => 'optional',
        },
    },
);

sub _spec_parts {
    my ($spec) = @_;
    return ref($spec) eq 'ARRAY' ? @$spec : ($spec, undef);
}

sub _record_role {
    my ($roles, $role, $value, @indices) = @_;
    return unless defined $role;
    push @{$roles->{$role}}, { value => $value, indices => \@indices };
}

sub _resolve_long {
    my ($long, $name) = @_;
    return $name if exists $long->{$name};       # exact match wins over prefixes
    my @matches = grep { index($_, $name) == 0 } keys %$long;
    return @matches == 1 ? $matches[0] : undef;  # getopt_long unique abbreviation
}

sub scan_command_argv {
    my ($args, $command) = @_;
    return undef unless ref($args) eq 'ARRAY';
    my $schema = $SCHEMA{lc($command // '')};
    return undef unless $schema;

    my (@operands, %roles, @ambiguities);
    for (my $i = 1; $i <= $#$args; $i++) {
        my $arg = $args->[$i];

        if ($arg eq '--') {
            for my $j ($i + 1 .. $#$args) {
                push @operands, { index => $j, value => $args->[$j] };
            }
            last;
        }

        # A lone '-' is stdin/a positional operand, not a short option.
        if ($arg eq '-' || $arg !~ /^-/) {
            push @operands, { index => $i, value => $arg };
            next;
        }

        if ($arg =~ /^--/) {
            my ($spelling, $attached) = $arg =~ /^--([^=]+)(?:=(.*))?$/;
            unless (defined $spelling) {
                push @ambiguities, "unrecognized long-option syntax '$arg'";
                next;
            }
            my $name = _resolve_long($schema->{long}, $spelling);
            unless (defined $name) {
                push @ambiguities, "unknown or ambiguous option '--$spelling'";
                next;
            }
            my ($arity, $role) = _spec_parts($schema->{long}{$name});
            if ($arity eq 'none') {
                push @ambiguities, "option '--$name' does not take a value"
                    if defined $attached;
                _record_role(\%roles, $role, undef, $i);
            } elsif ($arity eq 'optional') {
                _record_role(\%roles, $role, $attached, $i);
            } elsif (defined $attached) {
                _record_role(\%roles, $role, $attached, $i);
            } elsif ($i < $#$args) {
                my $opt_i = $i;
                $i++;
                _record_role(\%roles, $role, $args->[$i], $opt_i, $i);
            } else {
                push @ambiguities, "option '--$name' requires a value";
            }
            next;
        }

        # Parse bundled short options structurally.  A required/optional option
        # consumes the token remainder as its value and terminates the bundle.
        my $body = substr($arg, 1);
        while (length $body) {
            my $name = substr($body, 0, 1, '');
            my $spec = $schema->{short}{$name};
            unless (defined $spec) {
                push @ambiguities, "unknown short option '-$name' in '$arg'";
                last;
            }
            my ($arity, $role) = _spec_parts($spec);
            next if $arity eq 'none';

            if (length $body) {
                _record_role(\%roles, $role, $body, $i);
            } elsif ($arity eq 'optional') {
                _record_role(\%roles, $role, undef, $i);
            } elsif ($i < $#$args) {
                my $opt_i = $i;
                $i++;
                _record_role(\%roles, $role, $args->[$i], $opt_i, $i);
            } else {
                push @ambiguities, "option '-$name' requires a value";
            }
            last;
        }
    }

    return {
        command     => lc($command // ''),
        operands    => \@operands,
        roles       => \%roles,
        ambiguous   => @ambiguities ? 1 : 0,
        ambiguities => \@ambiguities,
    };
}

1;
