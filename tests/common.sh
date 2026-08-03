#!/bin/bash
#=============================================================================
# common.sh — shared by every pbcftools test script.
#
#   . "$(dirname "$0")/common.sh"
#
# Provides two things:
#
#   pbcf_validate <serial_output> <parallel_output>
#       0  outputs are equivalent;  1  they differ, with a reason on stdout
#
#   pbcf_parse_common_arg <arg> [value]
#       Handles one shared option, sets the PBCF_* variables below, and sets
#       PBCF_SHIFT to the number of argv slots consumed (0 = not a shared option,
#       so the caller should handle it). It must be called DIRECTLY, never through
#       $(...) — a command substitution runs it in a subshell, where every
#       assignment it makes is discarded.
#
# The point of the second is HARMONY: the same option means the same thing in
# run_tests.sh, run_tests_hpc.sh and run_tests_merge.sh, because they all parse
# it here rather than each keeping its own copy.
#
# Naming convention, applied throughout:
#   --p_<name>    passed straight through to pbcftools, spelled exactly as
#                 pbcftools spells it (--p_jobs, --p_len, --p_mem, ...)
#   --other-name  belongs to the harness itself (hyphenated)
#=============================================================================

# ---- shared defaults -------------------------------------------------------
PBCF_LABEL="local"
PBCF_TIERS=""
PBCF_LIST=0
PBCF_JOBS="4,8,16,32"        # worker counts / concurrent jobs to test at
PBCF_BENCH=0
PBCF_KEEP=0
PBCF_SITES=""                # benchmark data only
PBCF_GENO=""                 # benchmark data only
# The two benchmark datasets are not comparable, so they get separate defaults.
#
#   SITES  operations read a sites-only file (no GT columns): the per-record work is
#          tiny, so the whole genome is the honest default -- restricting to one
#          chromosome leaves a workload dominated by fixed per-chunk cost.
#   GENO   operations read/format GT columns for 2504 samples, which is ~three orders
#          of magnitude more work per record. One chromosome is already plenty.
#
# Empty means "no -r at all" = whole genome.
PBCF_REGION_SITES=""
PBCF_REGION_GENO="1"
# pbcftools passthroughs, empty unless the user sets them
PBCF_P_MODE=""; PBCF_P_LEN="10MB"; PBCF_P_DIR=""; PBCF_P_REF=""; PBCF_P_FAI=""
# --p_len given on the command line is the GENO chunk size. Sites operations use
# PBCF_P_LEN_SITES_FACTOR times that, because a sites chunk of the same span carries
# far less work: measured across five machines, a 1 MB sites chunk cost ~1 s of fixed
# overhead (process start, open, index seek on a 1.9 GB file) against ~25 ms of actual
# work, so parallel time scaled as 1/jobs with a constant product and never beat
# serial. Scaling the span is the structural fix -- it raises work-per-chunk without
# touching anything else.
PBCF_P_LEN_SITES_FACTOR=10
PBCF_P_CPU=""; PBCF_P_MEM=""; PBCF_P_WAL=""; PBCF_P_QUEUE=""; PBCF_P_ACCOUNT=""

# ---- shared option parsing -------------------------------------------------
# Sets PBCF_SHIFT to 0, 1 or 2. Call directly; NOT inside $(...).
PBCF_SHIFT=0
pbcf_parse_common_arg() {
    PBCF_SHIFT=0
    case "$1" in
        --label)          PBCF_LABEL="$2";                                 PBCF_SHIFT=2 ;;
        --tier)           PBCF_TIERS="$2";                                 PBCF_SHIFT=2 ;;
        --list)           PBCF_LIST=1;                                     PBCF_SHIFT=1 ;;
        --benchmark)      PBCF_BENCH=1;                                    PBCF_SHIFT=1 ;;
        --keep)           PBCF_KEEP=1;                                     PBCF_SHIFT=1 ;;
        # worker count. --cpus is accepted because that is what the local script
        # used before these options were harmonised; --jobs is the canonical name,
        # matching pbcftools' own --p_jobs, and it is correct for both the local
        # backend (fork workers) and a scheduler (concurrent jobs).
        --jobs|--cpus)    PBCF_JOBS="$2";                                  PBCF_SHIFT=2 ;;
        --sites)          PBCF_SITES="$2";                                 PBCF_SHIFT=2 ;;
        --geno)           PBCF_GENO="$2";                                  PBCF_SHIFT=2 ;;
        --sites-region)   PBCF_REGION_SITES="$2";                          PBCF_SHIFT=2 ;;
        --geno-region)    PBCF_REGION_GENO="$2";                           PBCF_SHIFT=2 ;;
        # the two datasets have very different densities, so a single --region is a
        # convenience that sets both, never the only way to say it
        --region)         PBCF_REGION_SITES="$2"; PBCF_REGION_GENO="$2";   PBCF_SHIFT=2 ;;
        --p_mode)         PBCF_P_MODE="$2";                                PBCF_SHIFT=2 ;;
        --p_len)          PBCF_P_LEN="$2";                                 PBCF_SHIFT=2 ;;
        --p_dir)          PBCF_P_DIR="$2";                                 PBCF_SHIFT=2 ;;
        --p_ref)          PBCF_P_REF="$2";                                 PBCF_SHIFT=2 ;;
        --p_fai)          PBCF_P_FAI="$2";                                 PBCF_SHIFT=2 ;;
        --p_cpu)          PBCF_P_CPU="$2";                                 PBCF_SHIFT=2 ;;
        --p_mem)          PBCF_P_MEM="$2";                                 PBCF_SHIFT=2 ;;
        --p_wal)          PBCF_P_WAL="$2";                                 PBCF_SHIFT=2 ;;
        --p_queue)        PBCF_P_QUEUE="$2";                               PBCF_SHIFT=2 ;;
        --p_account)      PBCF_P_ACCOUNT="$2";                             PBCF_SHIFT=2 ;;
        *)                                                                 PBCF_SHIFT=0 ;;
    esac
}

# Build the pbcftools option string for one run. $1 = job count, $2 = staging dir.
# Multiply a chunk length by an integer factor, using EXACTLY the grammar
# pbcftools' own convert_length_to_integer() accepts: optional whitespace, a decimal
# or exponent-form number, and a unit of ''|bp|k|kb|m|mb (case-insensitive). The
# result is emitted as a plain integer count of bases, which that same parser
# accepts.
#
# Matching the real grammar matters. A stricter pattern here (integer + letters)
# silently failed to scale '1e6', '1.5MB' and '1 MB' -- all of which pbcftools
# accepts -- so a sites workload would quietly run at the GENOTYPE chunk size, which
# is the exact measurement error this scaling exists to prevent. Unscalable input is
# reported loudly rather than passed through as if it had been handled.
pbcf_scale_plen() {
    local v="$1" f="$2" norm num unit mult
    norm=$(printf '%s' "$v" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
    if [[ "$norm" =~ ^([0-9]+\.?[0-9]*(e[0-9]+)?)(bp|kb|mb|k|m)?$ ]]; then
        num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3]}"
        case "$unit" in
            ''|bp) mult=1 ;;
            k|kb)  mult=1000 ;;
            m|mb)  mult=1000000 ;;
        esac
        # Guard the multiply: awk floating point overflows to "+inf" for absurd
        # inputs (--p_len 1e308), and pbcftools then rejects "+inf" and silently
        # falls back to its 10MB default -- so the run would not use the chunk size
        # the report claims. Refuse to invent a number instead.
        awk -v n="$num" -v m="$mult" -v f="$f" 'BEGIN{
            v = n * m * f
            if (v != v || v > 9007199254740992 || v < 1) { print "OVERFLOW"; exit }
            printf "%d", v
        }'
    else
        echo "WARNING: cannot scale --p_len '$v'; using it unchanged for sites workloads" >&2
        printf '%s' "$v"
        return
    fi
}

# The chunk length for a workload, given its data type ('sites' or 'geno').
pbcf_plen_for() {
    local scaled
    case "${1:-geno}" in
        sites)
            scaled=$(pbcf_scale_plen "$PBCF_P_LEN" "$PBCF_P_LEN_SITES_FACTOR")
            if [ "$scaled" = OVERFLOW ]; then
                echo "WARNING: --p_len '$PBCF_P_LEN' scaled by $PBCF_P_LEN_SITES_FACTOR" \
                     "is out of range; using it unchanged for sites workloads" >&2
                printf '%s' "$PBCF_P_LEN"
            else
                printf '%s' "$scaled"
            fi
            ;;
        *) printf '%s' "$PBCF_P_LEN" ;;
    esac
}

pbcf_par_opts() {
    local jobs="$1" stage="$2" out="" plen="${3:-$PBCF_P_LEN}"
    # --p_index 0: serial `bcftools` does NOT write an index unless asked, but
    # pbcftools does by default. Leaving it on charged the parallel side work the
    # serial side never did -- on a whole-chromosome merge that is a single-core
    # step worth a third of the run -- so every speedup was understated. Timing
    # comparisons switch it off; correctness comparisons are unaffected either way
    # because index sidecars are excluded from the diff.
    out="--p_jobs $jobs --p_len $plen --p_index 0"
    [ -n "$stage" ]            && out="$out --p_dir $stage"
    [ -n "$PBCF_P_MODE" ]      && out="$out --p_mode $PBCF_P_MODE"
    [ -n "$PBCF_P_REF" ]       && out="$out --p_ref $PBCF_P_REF"
    [ -n "$PBCF_P_FAI" ]       && out="$out --p_fai $PBCF_P_FAI"
    [ -n "$PBCF_P_CPU" ]       && out="$out --p_cpu $PBCF_P_CPU"
    [ -n "$PBCF_P_MEM" ]       && out="$out --p_mem $PBCF_P_MEM"
    [ -n "$PBCF_P_WAL" ]       && out="$out --p_wal $PBCF_P_WAL"
    [ -n "$PBCF_P_QUEUE" ]     && out="$out --p_queue $PBCF_P_QUEUE"
    [ -n "$PBCF_P_ACCOUNT" ]   && out="$out --p_account $PBCF_P_ACCOUNT"
    printf '%s --p_yes' "$out"
}

# Print the shared options, for each script's --help.
pbcf_common_usage() {
    cat <<'USAGE'
  Shared options (identical in every pbcftools test script):
    --label NAME         name for the report file
    --tier LIST          comma-separated tiers to run
    --list               print the selected tests and exit
    --jobs N[,N,...]     worker counts / concurrent jobs   (alias: --cpus)
    --benchmark          also run the benchmark tier, with timings
    --keep               keep outputs for inspection
    --sites FILE         1000G sites-only VCF      (BENCHMARK TIER ONLY)
    --geno FILE          1000G chr1 genotypes VCF  (BENCHMARK TIER ONLY)
    --sites-region REG   benchmark region for the sites file  (default: whole genome)
    --geno-region REG    benchmark region for the genotypes file (default: 1)
    --region REG         set both benchmark regions at once
    --p_len LEN          chunk size for GENO operations; SITES use 10x this
    --p_mode --p_len --p_dir --p_ref --p_fai --p_cpu --p_mem --p_wal
    --p_queue --p_account
                         passed straight through to pbcftools
USAGE
}

#=============================================================================
# Validation.
#
# "Equivalent" is not "byte-identical", because two differences are CORRECT and
# expected. Both are narrow and both are checked, not skipped:
#
#   1. `##bcftools_<cmd>Command=...; Date=...` (and `##bcftools/csqCommand`, which
#      csq spells with a SLASH where every other subcommand uses an underscore)
#      bcftools stamps the wall-clock time it ran, and the parallel run happens a
#      moment later. Only the Date= element may differ; the command text itself
#      must match exactly, because a difference there means pbcftools rewrote the
#      user's command.
#
#   2. `##pbcftools_command=...`
#      Present only in the parallel output, by design. Exactly one, and only there.
#
#   3. PROVENANCE COMMENTS in text output.
#      `bcftools roh` writes `# The command line was: ...`, and pbcftools rewrites it
#      to name the pbcftools invocation — that line is SUPPOSED to differ. Only
#      comment lines that record a command line or producing tool are excluded; every
#      other comment, and every data line, must match.
#
#   4. `bcftools stats` section ORDER and commentary.
#      Per-region stats are merged by `plot-vcfstats -m`, which rewrites the preamble,
#      drops bcftools' explanatory comment blocks, and emits sections in a different
#      order. Counters are compared as a SET; each row is self-labelled (SN, QUAL,
#      IDD, ST, ...), so a changed, missing or extra counter still fails.
#
# Anything else — a record, a header line, a byte of a text table — must match.
#
# Callers must run serial and parallel to the SAME -o path (moving the serial
# result aside afterwards), because bcftools records that path in the header.
#=============================================================================

_pbcf_is_vcf() {
    [ -f "$1" ] || return 1
    local magic
    magic=$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$magic" in
        1f8b*)   return 0 ;;   # gzip / BGZF
        424346*) return 0 ;;   # BCF
    esac
    head -c13 "$1" 2>/dev/null | grep -q '^##fileformat' && return 0
    return 1
}

# Headers are read with `view -h --no-version`. WITHOUT --no-version bcftools
# appends a ##bcftools_viewCommand line describing THE READ ITSELF, naming the file
# being read — so the extraction step would inject a path-dependent difference and
# any comparison of two differently-named files would fail for no real reason.
_pbcf_hdr() { bcftools view -h --no-version "$1" 2>/dev/null; }
_pbcf_norm_header() {
    sed -E -e 's/(^##bcftools[_/][A-Za-z]*Command=.*); Date=.*$/\1/' \
        -e '/^##pbcftools_command=/d'
}

_pbcf_validate_vcf() {
    local a="$1" b="$2"
    if ! cmp -s <(bcftools view -H "$a" 2>/dev/null) <(bcftools view -H "$b" 2>/dev/null); then
        local na nb
        na=$(bcftools view -H "$a" 2>/dev/null | wc -l | tr -d ' ')
        nb=$(bcftools view -H "$b" 2>/dev/null | wc -l | tr -d ' ')
        echo "body differs (serial $na records, parallel $nb)"
        return 1
    fi
    # Compare the header as a SET of lines, not as a sequence. VCF/BCF give meta
    # lines no meaningful order beyond ##fileformat coming first, and bcftools does
    # not preserve their order across formats: a parallel -Ob output carries the
    # provenance lines BEFORE ##contig where serial has them after. Requiring an
    # identical sequence would fail every BCF comparison for no real reason. The
    # set must still match exactly, so a missing or extra line is still caught.
    if ! cmp -s <(_pbcf_hdr "$a" | _pbcf_norm_header | sort) \
                <(_pbcf_hdr "$b" | _pbcf_norm_header | sort); then
        echo "header lines differ beyond Date= and ##pbcftools_command: $(
            diff <(_pbcf_hdr "$a" | _pbcf_norm_header | sort) \
                 <(_pbcf_hdr "$b" | _pbcf_norm_header | sort) | head -4 | tr '\n' ' ')"
        return 1
    fi
    local fa fb
    fa=$(_pbcf_hdr "$a" | head -1); fb=$(_pbcf_hdr "$b" | head -1)
    if [ "$fa" != "$fb" ]; then
        echo "first header line differs: '$fa' vs '$fb'"
        return 1
    fi
    # The provenance line must never appear in a serial output. In the parallel one
    # it appears once when pbcftools actually parallelised, and NOT AT ALL when the
    # command was passed through to a single bcftools process — which is the correct
    # behaviour for the passthrough tier, not a defect.
    local pa pb
    pa=$(_pbcf_hdr "$a" | grep -c '^##pbcftools_command=')
    pb=$(_pbcf_hdr "$b" | grep -c '^##pbcftools_command=')
    if [ "$pa" != 0 ] || [ "$pb" -gt 1 ]; then
        echo "##pbcftools_command count wrong (serial $pa want 0; parallel $pb want 0 or 1)"
        return 1
    fi
    return 0
}

# Directory outputs (cnv). Compare the file SETS, then each file. Files that embed
# their own location legitimately differ: `bcftools cnv` writes plot.<sample>.py
# holding absolute paths to its own .tab inputs, and pbcftools re-binds those to the
# published directory. Normalise each side's own directory away, then the rest must
# still match exactly.
_pbcf_validate_dir() {
    local a="$1" b="$2" la lb f
    la=$(cd "$a" && find . -type f | sort)
    lb=$(cd "$b" && find . -type f | sort)
    if [ "$la" != "$lb" ]; then
        echo "directory contents differ: $(diff <(printf '%s\n' "$la") <(printf '%s\n' "$lb") | head -4 | tr '\n' ' ')"
        return 1
    fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! cmp -s <(sed "s#$a#@DIR@#g" "$a/$f") <(sed "s#$b#@DIR@#g" "$b/$f"); then
            echo "file differs inside the directory: $f"
            return 1
        fi
    done <<< "$la"
    return 0
}

# Comment lines other than provenance. `# The command line was:` and
# `# This file was produced by ...` are expected to differ between a serial run and a
# pbcftools run; anything else in the commentary is real content and must match.
_pbcf_real_comments() {
    grep '^#' "$1" 2>/dev/null | grep -vE 'command line was|produced by'
}

# `bcftools stats` output, recognisable from its own first line or the merge tool's.
# Stats rows, normalised for comparison. The two producers format numbers
# differently for identical values: `bcftools stats` prints percentages with %f
# ("0.001881", "0.000000") while `plot-vcfstats -m`, which pbcftools uses to merge
# per-region chunks, re-emits them at full precision ("0.00188072445506009", "0").
# Comparing the text made every real-data stats workload look wrong when the counts
# were in fact identical. Numeric fields are compared as NUMBERS at SIX decimal
# places -- the precision `bcftools stats` itself prints with %f -- so the two
# spellings of one value agree while two genuinely different values do not. Four
# places was too coarse: 0.00001 and 0.00004 both collapsed to 0.0000 and compared
# EQUAL, which is the vacuous-pass class this suite exists to catch. Everything else
# (labels, ">500", ranges) is left exactly as-is, so a changed, missing or extra
# counter still fails.
_pbcf_stats_rows() {
    grep -v '^#' "$1" | awk -F'\t' -v OFS='\t' '{
        for (i = 1; i <= NF; i++)
            if ($i ~ /^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/)
                $i = sprintf("%.6f", $i)
        print
    }' | sort
}

_pbcf_is_stats() {
    head -2 "$1" 2>/dev/null | grep -qE 'produced by (bcftools stats|plot-vcfstats)'
}

pbcf_validate() {
    local a="$1" b="$2"
    [ -e "$a" ] || { echo "serial output missing: $a";   return 1; }
    [ -e "$b" ] || { echo "parallel output missing: $b"; return 1; }
    if [ -d "$a" ] || [ -d "$b" ]; then
        { [ -d "$a" ] && [ -d "$b" ]; } || { echo "one output is a directory, the other is not"; return 1; }
        _pbcf_validate_dir "$a" "$b"; return $?
    fi
    if _pbcf_is_vcf "$a" || _pbcf_is_vcf "$b"; then
        _pbcf_validate_vcf "$a" "$b"; return $?
    fi
    # stats: compare the counters, not the commentary, and as a SET. plot-vcfstats -m
    # regenerates the preamble, omits bcftools' explanatory comment blocks, and emits
    # the sections in a different order — so neither '#' lines nor line positions can
    # match. Every data row is self-labelled (SN, QUAL, IDD, ST, ...), so set equality
    # is exactly the right test: a changed, missing or extra counter still fails.
    if _pbcf_is_stats "$a" || _pbcf_is_stats "$b"; then
        if ! cmp -s <(_pbcf_stats_rows "$a") <(_pbcf_stats_rows "$b"); then
            echo "stats counters differ: $(diff <(_pbcf_stats_rows "$a") \
                 <(_pbcf_stats_rows "$b") | head -4 | tr '\n' ' ')"
            return 1
        fi
        return 0
    fi
    # General text output. Data lines must match exactly. Comment lines must match
    # too, EXCEPT the ones that record a command line or producing tool: pbcftools
    # deliberately rewrites `# The command line was:` in roh output to name its own
    # invocation, and that is the documented behaviour, not a defect.
    if ! cmp -s <(grep -v '^#' "$a") <(grep -v '^#' "$b"); then
        echo "text data lines differ ($(grep -cv '^#' "$a") vs $(grep -cv '^#' "$b") lines): $(
            diff <(grep -v '^#' "$a") <(grep -v '^#' "$b") | head -3 | tr '\n' ' ')"
        return 1
    fi
    if ! cmp -s <(_pbcf_real_comments "$a") <(_pbcf_real_comments "$b"); then
        echo "text comment lines differ beyond provenance: $(
            diff <(_pbcf_real_comments "$a") <(_pbcf_real_comments "$b") | head -3 | tr '\n' ' ')"
        return 1
    fi
    return 0
}
