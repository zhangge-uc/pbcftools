#!/bin/bash
#=============================================================================
# run_tests.sh — run every command in tests.cmd serially and in parallel, and
#                check that the two agree.
#
#   bash tests/run_tests.sh [--label NAME] [options]
#
# NO DOWNLOAD IS NEEDED to check correctness. Every tier except `benchmark` runs
# against small SYNTHETIC fixtures this script builds itself, so a fresh install
# can be verified with nothing but bcftools on the PATH. Only --benchmark needs the
# real 1000 Genomes files, because a speedup measured on a toy file means nothing.
#
# Add your own commands to tests.cmd under any tier; they are picked up here with
# no change to this script.
#
# Script-specific option:
#   --p_dir DIR          where to put outputs (default: a temp dir, removed at exit)
#
# For the shared options, run with --help.
#=============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PBCF="$SCRIPT_DIR/../bin/pbcftools.pl"
MANIFEST="$SCRIPT_DIR/tests.cmd"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

# default benchmark data locations; consulted only when --benchmark is given
PBCF_SITES="$SCRIPT_DIR/data/ALL.wgs.phase3_shapeit2_mvncall_integrated_v5c.20130502.sites.vcf.gz"
PBCF_GENO="$SCRIPT_DIR/data/ALL.chr1.phase3_shapeit2_mvncall_integrated_v5b.20130502.genotypes.vcf.gz"

while [ $# -gt 0 ]; do
    if [ "$1" = -h ] || [ "$1" = --help ]; then
        sed -n '2,20p' "$0"; echo; pbcf_common_usage; exit 0
    fi
    pbcf_parse_common_arg "$1" "${2:-}"
    if [ "$PBCF_SHIFT" -gt 0 ]; then shift "$PBCF_SHIFT"; continue; fi
    case "$1" in
        --*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)   PBCF_LABEL="$1"; shift ;;          # a bare word is the label
    esac
done

[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 2; }
command -v bcftools >/dev/null 2>&1 || { echo "ERROR: bcftools not on PATH" >&2; exit 2; }

#-----------------------------------------------------------------------------
# Parse the manifest. `## name` opens a tier; `# text` describes the NEXT
# command; a line starting with `bcftools` is a test.
#-----------------------------------------------------------------------------
T_TIER=(); T_DESC=(); T_CMD=()
cur_tier=""; pending=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '##'*)     cur_tier=$(printf '%s' "${line#\#\#}" | sed 's/^ *//; s/ *$//; s/ .*//'); pending="" ;;
        '#'*)      pending=$(printf '%s' "${line#\#}" | sed 's/^ *//; s/ *$//') ;;
        bcftools*) T_TIER+=("$cur_tier"); T_CMD+=("$line")
                   T_DESC+=("${pending:-$cur_tier test}"); pending="" ;;
        *)         : ;;
    esac
done < "$MANIFEST"
[ "${#T_CMD[@]}" -gt 0 ] || { echo "ERROR: no tests found in $MANIFEST" >&2; exit 2; }

ALL_TIERS=$(printf '%s\n' "${T_TIER[@]}" | awk '!s[$0]++' | tr '\n' ',' | sed 's/,$//')
if [ -z "$PBCF_TIERS" ]; then
    if [ "$PBCF_BENCH" = 1 ]; then
        # --benchmark is a MODE, not an addition. Timing a machine is a separate job
        # from checking correctness, it wants the real data, and interleaving 21
        # correctness checks with it only makes the numbers harder to read. Use
        # --tier explicitly if you really want both in one run.
        PBCF_TIERS="benchmark"
    else
        PBCF_TIERS=$(printf '%s\n' "${T_TIER[@]}" | awk '!s[$0]++' \
            | grep -v '^benchmark$' | tr '\n' ',' | sed 's/,$//')
    fi
fi
_selected() { case ",$PBCF_TIERS," in *",$1,"*) return 0 ;; esac; return 1; }
WORK_FREE_GB=0

if [ "$PBCF_LIST" = 1 ]; then
    echo "manifest:  $MANIFEST"
    echo "all tiers: $ALL_TIERS"
    echo "selected:  $PBCF_TIERS"
    echo
    for i in "${!T_CMD[@]}"; do
        _selected "${T_TIER[$i]}" || continue
        printf '  [%-11s] %s\n                %s\n' "${T_TIER[$i]}" "${T_DESC[$i]}" "${T_CMD[$i]}"
    done
    exit 0
fi

if _selected benchmark; then
    miss=""
    [ -f "$PBCF_SITES" ] || miss="$miss\n  --sites  $PBCF_SITES"
    [ -f "$PBCF_GENO"  ] || miss="$miss\n  --geno   $PBCF_GENO"
    if [ -n "$miss" ]; then
        printf 'ERROR: the benchmark tier needs the 1000 Genomes files:%b\n' "$miss" >&2
        echo "See tests/README.md for the download links. Drop --benchmark to run the" >&2
        echo "correctness tiers, which need no downloaded data at all." >&2
        exit 2
    fi
fi

# An explicit --p_dir is a user-owned PARENT, not the artifact directory itself: a
# nonce-named child is created inside it and only that child is ever removed. Using
# the given directory directly meant the exit trap did `rm -rf` on a path the user
# named -- so `--p_dir /shared/scratch` deleted the scratch directory and everything
# already in it. This is the same invariant pbcftools applies to its own --p_dir, and
# it matters most exactly where --p_dir is mandatory: cluster runs, where the work
# directory has to be on a shared filesystem.
if [ -n "$PBCF_P_DIR" ]; then
    mkdir -p "$PBCF_P_DIR" || { echo "ERROR: cannot create --p_dir '$PBCF_P_DIR'" >&2; exit 2; }
    ROOT=$(mktemp -d "$PBCF_P_DIR/pbcf_tests.XXXXXX") \
        || { echo "ERROR: cannot create a work directory under '$PBCF_P_DIR'" >&2; exit 2; }
else
    ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pbcf_tests.XXXXXX") \
        || { echo "ERROR: cannot create a work directory in ${TMPDIR:-/tmp}" >&2; exit 2; }
fi
# The serial reference lives under ref/, OUTSIDE the "$OUT".* namespace. It used to
# be "$OUT.serial" -- which that glob matches -- so the per-level cleanup deleted the
# reference before the first comparison. With nothing to compare, the loop body never
# ran and the verdict stayed PASS: every benchmark row was passing vacuously.
mkdir -p "$ROOT" "$ROOT/logs" "$ROOT/ref"

_root_cleanup() {
    [ "$PBCF_KEEP" = 1 ] && return 0
    # Keep the evidence when something failed. Every failure message points at a log
    # under $ROOT, and wiping it here made those paths dangle exactly when they were
    # needed -- a cross-platform failure arrived with its diagnosis already deleted.
    if [ "${FAIL:-0}" != 0 ]; then
        printf '\nWorking directory kept for diagnosis: %s\n' "$ROOT" >&2
        printf '  logs/  stdout+stderr of both sides, per workload\n' >&2
        return 0
    fi
    rm -rf "$ROOT"
}
trap _root_cleanup EXIT

# Why a failing command failed, short enough for a report table. Without this a
# platform failure reads only as "serial failed", which is untraceable once the
# working directory is gone.
_logreason() {
    [ -s "$1" ] || { printf 'no output captured'; return; }
    tail -n 40 "$1" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-160
}
_logtail() {
    [ -s "$1" ] || return 0
    tail -n 4 "$1" | sed 's/^/        | /'
}

# Free space on the working filesystem, in GB. Reported in the header of every run
# and every report, because a cross-platform failure that turns out to be "the disk
# filled up" is otherwise indistinguishable from a pbcftools defect -- the serial
# command just fails, eight workloads in a row get skipped, and the reason is gone
# with the working directory.
_free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}'; }
WORK_FREE_GB=$(_free_gb "$ROOT")

# Free a workload's artifacts once it has been judged. Without this the working
# directory grew monotonically: eleven benchmark workloads each retaining a full
# serial copy AND a full parallel copy. Over all of chr1 the two genotype-query
# workloads alone are ~64 GB each, so a run needed hundreds of GB that it never
# handed back. Distros that put /tmp on RAM-backed tmpfs (recent Ubuntu and Fedora
# default it to ~50% of RAM) run out partway through, and every later workload then
# fails for a reason that has nothing to do with pbcftools. Peak usage is now one
# workload, not the whole tier.
CUR_SLUG=""   # set -u: the release wrapper reads this before the first workload runs
_release() {
    [ "$PBCF_KEEP" = 1 ] && return 0
    [ -n "${1:-}" ] || return 0
    rm -rf "$ROOT/ref/$1" "$ROOT/$1".* "$ROOT"/stg_"$1"_* 2>/dev/null
    return 0
}

#-----------------------------------------------------------------------------
# Synthetic fixtures: a sites-only file and a genotype file over two contigs.
# Instant to build, but structured enough to exercise the real code paths —
# several contigs, an INFO field to filter on, samples to subset.
#-----------------------------------------------------------------------------
SYN_SITES="$ROOT/syn_sites.vcf.gz"
SYN_GENO="$ROOT/syn_geno.vcf.gz"
_hdr_common() {
    echo '##fileformat=VCFv4.2'
    echo '##contig=<ID=1,length=2000000>'
    echo '##contig=<ID=2,length=1000000>'
    echo '##INFO=<ID=AF,Number=A,Type=Float,Description="af">'
}
{ _hdr_common
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  for p in $(seq 1 1500); do printf '1\t%d\t.\tA\tG\t100\tPASS\tAF=0.1\n' $((p*1000)); done
  for p in $(seq 1 800);  do printf '2\t%d\t.\tC\tT\t100\tPASS\tAF=0.3\n' $((p*1000)); done
} > "${SYN_SITES%.gz}"
bgzip -f "${SYN_SITES%.gz}" && bcftools index -f "$SYN_SITES"
{ _hdr_common
  echo '##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\n'
  for p in $(seq 1 1500); do printf '1\t%d\t.\tA\tG\t100\tPASS\tAF=0.1\tGT\t0|1\t1|1\n' $((p*1000)); done
  for p in $(seq 1 800);  do printf '2\t%d\t.\tC\tT\t100\tPASS\tAF=0.3\tGT\t1|1\t0|1\n' $((p*1000)); done
} > "${SYN_GENO%.gz}"
bgzip -f "${SYN_GENO%.gz}" && bcftools index -f "$SYN_GENO"
if [ ! -s "$SYN_SITES" ] || [ ! -s "$SYN_GENO" ]; then
    echo "ERROR: could not build the synthetic fixtures — see the errors above." >&2
    exit 2
fi

# a second, smaller input for the multi-input tier
SUBSET="$ROOT/subset.vcf.gz"
bcftools view -r 1:1-500000 "$SYN_GENO" -Oz -o "$SUBSET" 2>/dev/null
bcftools index -f "$SUBSET" 2>/dev/null

# Bind the manifest's data variables for a tier: synthetic for correctness (the
# whole file — it is tiny), the real data plus its regions for the benchmark.
# Which dataset does this command read? The manifest names it explicitly ($GENO /
# $R_GENO vs $SITES / $R_SITES), so the classification is declarative rather than
# guessed: a command that touches the genotype file processes GT columns and is a
# 'geno' workload; everything else is 'sites'. This drives BOTH the region default
# and the chunk size.
_data_kind() {
    case "$1" in
        *'$GENO'*|*'$R_GENO'*|*'$SUBSET'*) printf 'geno' ;;
        *)                                 printf 'sites' ;;
    esac
}

_bind_data() {
    if [ "$1" = benchmark ]; then
        SITES="$PBCF_SITES"; GENO="$PBCF_GENO"
        R_SITES=""; [ -n "$PBCF_REGION_SITES" ] && R_SITES="-r $PBCF_REGION_SITES"
        R_GENO="";  [ -n "$PBCF_REGION_GENO"  ] && R_GENO="-r $PBCF_REGION_GENO"
    else
        SITES="$SYN_SITES"; GENO="$SYN_GENO"; R_SITES=""; R_GENO=""
    fi
    # Sample names must come from whichever genotype file is bound. Hardcoding the
    # synthetic "S1" meant `view -s S1` on the real 1000G file (samples HG00096, ...)
    # failed serially, and the workload was silently reported as skipped rather than
    # measured — a benchmark quietly missing one of its cases.
    SAMPLE1=$(bcftools query -l "$GENO" 2>/dev/null | head -1)
    SAMPLES=$(bcftools query -l "$GENO" 2>/dev/null | head -3 | paste -sd, -)
    export SITES GENO R_SITES R_GENO SUBSET SAMPLE1 SAMPLES
}

# Turn a manifest line into its pbcftools equivalent.
#
# `bcftools stats`, `roh` and `cnv` have no -o: they write to stdout, so the manifest
# states the SERIAL-correct form with a redirect. pbcftools DOES take -o for them (it
# supplies the redirect itself), so `> path` becomes `-o path` on the parallel side.
#
# This lives in one function because it did not: run_one had the conversion and
# run_bench did not, so both stats workloads failed the moment the benchmark tier
# grew beyond commands that use -o directly.
_par_command() {
    local body="${1/#bcftools/perl $PBCF}"
    if printf '%s' "$body" | grep -qE '>[[:space:]]*[^[:space:]]+[[:space:]]*$'; then
        local redir
        redir=$(printf '%s' "$body" | sed -E 's/.*>[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/')
        body=$(printf '%s' "$body" | sed -E 's/>[[:space:]]*[^[:space:]]+[[:space:]]*$//')
        body="$body -o $redir"
    fi
    printf '%s' "$body"
}

PASS=0; FAIL=0; SKIP=0; RESULTS=(); BENCH_ROWS=(); BENCH_TOOSMALL=0
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS|$1"); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1 -- $2"); printf '  \033[31mFAIL\033[0m  %s  -- %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); RESULTS+=("SKIP|$1"); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

echo "pbcftools test suite  [$PBCF_LABEL]"
echo "  manifest : $MANIFEST"
echo "  tiers    : $PBCF_TIERS"
echo "  bcftools : $(bcftools --version 2>/dev/null | head -1)"
if _selected benchmark; then
    echo "  jobs     : $PBCF_JOBS  (swept per workload)"
else
    echo "  jobs     : $(printf '%s' "$PBCF_JOBS" | tr ',' '\n' | sort -n | head -1)  (concurrency only; --p_len sets the chunking, so this does not affect the result)"
fi
if _selected benchmark; then
    echo "  benchmark sites     : $PBCF_SITES (region ${PBCF_REGION_SITES:-whole genome})"
    echo "  benchmark genotypes : $PBCF_GENO (region ${PBCF_REGION_GENO:-whole genome})"
    echo "  chunk (geno/sites)  : $PBCF_P_LEN / $(pbcf_plen_for sites)"
    echo "  work dir            : $ROOT (${WORK_FREE_GB} GB free)"
    # A whole-chromosome genotype query is ~64 GB of TSV, and the reference copy and
    # the parallel copy exist at the same time. Saying so BEFORE a four-hour run is
    # the difference between one actionable line and eight "serial failed" skips
    # whose cause is unrecoverable. 150 GB is the whole-chr1 figure; smaller regions
    # need proportionally less, so this warns rather than refuses.
    if [ "${WORK_FREE_GB:-0}" -lt 150 ]; then
        echo
        echo "  NOTE: a whole-chromosome benchmark needs ~150 GB here; $WORK_FREE_GB GB is free."
        echo "        Recent Ubuntu/Fedora put /tmp on RAM-backed tmpfs (~50% of RAM), which is"
        echo "        usually too small. Either point the work dir at a real disk:"
        echo "            TMPDIR=/path/with/space bash tests/run_tests.sh ... --benchmark"
        echo "        or benchmark a smaller region, e.g. --geno-region 1:1-20000000."
    fi
else
    echo "  data     : synthetic fixtures (no download required)"
fi
echo

#-----------------------------------------------------------------------------
# Run one manifest command serially, then in parallel, then compare.
#
# BOTH runs write to the SAME -o path. bcftools records that path inside
# ##bcftools_<cmd>Command, so writing to two different paths would make every
# header differ for a reason unrelated to correctness. The serial result is moved
# aside afterwards; moving a file does not change its contents, so the path
# recorded inside it still matches the parallel run's.
#-----------------------------------------------------------------------------
run_one() { _run_one "$@"; local rc=$?; _release "$CUR_SLUG"; return $rc; }
_run_one() {
    local idx="$1" jobs="$2"
    local tier="${T_TIER[$idx]}" desc="${T_DESC[$idx]}" cmd="${T_CMD[$idx]}"
    local slug name stash stage f
    slug=$(printf 't%03d_%s' "$idx" "$(printf '%s' "$desc" | tr -cs 'A-Za-z0-9' '_' | cut -c1-36)")
    name="[$tier] $desc"
    _bind_data "$tier"

    OUT="$ROOT/$slug"; OUTDIR="$OUT.dir"; export OUT OUTDIR
    CUR_SLUG="$slug"
    stash="$ROOT/ref/$slug"; stage="$ROOT/stg_${slug}_$jobs"
    rm -rf "$stash" "$stage" "$OUT".* "$OUTDIR"; mkdir -p "$stash" "$stage"

    local t0 t1 ser_ms par_ms
    t0=$(date +%s%N 2>/dev/null || echo 0)
    if ! eval "$cmd" >"$ROOT/logs/$slug.ser.log" 2>&1; then
        skip "$name (serial bcftools failed: $(_logreason "$ROOT/logs/$slug.ser.log"))"
        _logtail "$ROOT/logs/$slug.ser.log"; return
    fi
    t1=$(date +%s%N 2>/dev/null || echo 0); ser_ms=$(( (t1 - t0) / 1000000 ))
    for f in "$OUT".* "$OUTDIR"; do [ -e "$f" ] && mv "$f" "$stash/" 2>/dev/null; done

    local par_cmd="$(_par_command "$cmd") $(pbcf_par_opts "$jobs" "$stage" "$(pbcf_plen_for "$(_data_kind "$cmd")")")"
    t0=$(date +%s%N 2>/dev/null || echo 0)
    if ! eval "$par_cmd" >"$ROOT/logs/$slug.par.log" 2>&1; then
        bad "$name" "parallel exited non-zero: $(_logreason "$ROOT/logs/$slug.par.log")"
        _logtail "$ROOT/logs/$slug.par.log"; return
    fi
    t1=$(date +%s%N 2>/dev/null || echo 0); par_ms=$(( (t1 - t0) / 1000000 ))

    # Compare every artifact the SERIAL run produced. The parallel run may add an
    # index the serial one did not (pbcftools auto-indexes), which is expected — so
    # serial's outputs drive the comparison. Index sidecars are not compared: BGZF
    # re-blocking makes them legitimately byte-different.
    local base pf reason found=0
    for f in "$stash"/*; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        case "$base" in *.csi|*.tbi) continue ;; esac
        pf="$ROOT/$base"; found=1
        if ! reason=$(pbcf_validate "$f" "$pf"); then
            bad "$name @${jobs}j" "$reason"; return
        fi
    done
    [ "$found" = 1 ] || { skip "$name (serial produced nothing to compare)"; return; }

    if [ "$tier" = benchmark ]; then
        local sp; sp=$(perl -e 'printf "%.2f", $ARGV[0]/($ARGV[1]||1)' "$ser_ms" "$par_ms")
        ok "$name @${jobs}j  serial ${ser_ms}ms / parallel ${par_ms}ms = ${sp}x"
    else
        ok "$name @${jobs}j"
    fi
}

# Benchmark: run the SERIAL side once, then every job level against it. Timing the
# same serial command once per level wastes minutes on the real datasets and tells
# you nothing new — the serial time is a property of the machine, not of --jobs.
_secs() { perl -e 'printf "%.2f", $ARGV[0]/1000' "$1"; }
run_bench() { _run_bench "$@"; local rc=$?; _release "$CUR_SLUG"; return $rc; }
_run_bench() {
    local idx="$1"
    local tier="${T_TIER[$idx]}" desc="${T_DESC[$idx]}" cmd="${T_CMD[$idx]}"
    local slug stash f
    slug=$(printf 'b%03d_%s' "$idx" "$(printf '%s' "$desc" | tr -cs 'A-Za-z0-9' '_' | cut -c1-36)")
    _bind_data "$tier"

    CUR_SLUG="$slug"
    local wl_kind wl_plen
    wl_kind=$(_data_kind "$cmd"); wl_plen=$(pbcf_plen_for "$wl_kind")
    OUT="$ROOT/$slug"; OUTDIR="$OUT.dir"; export OUT OUTDIR
    stash="$ROOT/ref/$slug"
    rm -rf "$stash" "$OUT".* "$OUTDIR"; mkdir -p "$stash"

    printf '  \033[1m%s\033[0m\n' "$desc"
    # Show what is actually being timed. Textual substitution rather than eval: the
    # line is displayed, never re-executed, so nothing here can change what ran.
    local disp="$cmd"
    disp=${disp//\$R_SITES/$R_SITES}; disp=${disp//\$R_GENO/$R_GENO}
    disp=${disp//\$SITES/$SITES};     disp=${disp//\$GENO/$GENO}
    disp=${disp//\$SUBSET/$SUBSET};   disp=${disp//\$SAMPLES/$SAMPLES}
    disp=${disp//\$SAMPLE1/$SAMPLE1}
    disp=${disp//\$OUTDIR/$OUTDIR};   disp=${disp//\$OUT/$OUT}
    printf '    \033[2m%s\033[0m\n' "$(printf '%s' "$disp" | tr -s ' ')"
    printf '    \033[2m(%s workload — chunk %s)\033[0m\n' "$wl_kind" "$wl_plen"
    printf '    %-14s' "serial"
    local t0 t1 ser_ms
    t0=$(date +%s%N 2>/dev/null || echo 0)
    if ! eval "$cmd" >"$ROOT/logs/$slug.ser.log" 2>&1; then
        printf '\033[33mSKIP\033[0m  (the serial bcftools command itself failed)\n'
        _logtail "$ROOT/logs/$slug.ser.log"
        skip "[benchmark] $desc (serial bcftools failed: $(_logreason "$ROOT/logs/$slug.ser.log"))"
        return
    fi
    t1=$(date +%s%N 2>/dev/null || echo 0); ser_ms=$(( (t1 - t0) / 1000000 ))
    printf '%9ss' "$(_secs "$ser_ms")"
    # A workload the serial run finishes in under a second cannot produce a
    # meaningful ratio: pbcftools' fixed cost — forking workers, per-chunk bcftools
    # startup, reassembly — dominates entirely, and the "speedup" printed below is
    # measuring that overhead rather than any parallel gain. Say so, so the number is
    # not quoted as a result.
    if [ "$ser_ms" -lt 1000 ]; then
        printf '   \033[33m(too small to benchmark — ratios below are startup overhead)\033[0m'
        BENCH_TOOSMALL=1
    fi
    printf '\n'
    for f in "$OUT".* "$OUTDIR"; do [ -e "$f" ] && mv "$f" "$stash/" 2>/dev/null; done

    local j stage par_ms sp base pf reason verdict found
    for j in $(printf '%s' "$PBCF_JOBS" | tr ',' ' '); do
        printf '    %-14s' "@${j} jobs"
        stage="$ROOT/stg_${slug}_$j"; rm -rf "$stage" "$OUT".* "$OUTDIR"; mkdir -p "$stage"
        t0=$(date +%s%N 2>/dev/null || echo 0)
        if ! eval "$(_par_command "$cmd") $(pbcf_par_opts "$j" "$stage" "$wl_plen")" \
                >"$ROOT/logs/$slug.par$j.log" 2>&1; then
            printf '\033[31mFAIL\033[0m  (exited non-zero)\n'
            _logtail "$ROOT/logs/$slug.par$j.log"
            bad "[benchmark] $desc @${j}j" "parallel exited non-zero: $(_logreason "$ROOT/logs/$slug.par$j.log")"
            continue
        fi
        t1=$(date +%s%N 2>/dev/null || echo 0); par_ms=$(( (t1 - t0) / 1000000 ))
        verdict=PASS; reason=""; found=0
        for f in "$stash"/*; do
            [ -e "$f" ] || continue
            base=$(basename "$f")
            case "$base" in *.csi|*.tbi) continue ;; esac
            pf="$ROOT/$base"; found=1
            if ! reason=$(pbcf_validate "$f" "$pf"); then verdict=FAIL; break; fi
        done
        # Comparing zero artifacts is not a pass. run_one has always had this guard;
        # run_bench did not, which is what let the deleted reference go unnoticed.
        if [ "$found" = 0 ]; then
            verdict=FAIL; reason="no serial artifact to compare against (harness error)"
        fi
        sp=$(perl -e 'printf "%.2f", $ARGV[0]/($ARGV[1]||1)' "$ser_ms" "$par_ms")
        if [ "$verdict" = PASS ]; then
            printf '%9ss   speedup %6sx   \033[32mPASS\033[0m\n' "$(_secs "$par_ms")" "$sp"
            PASS=$((PASS+1)); RESULTS+=("PASS|[benchmark] $desc @${j}j  ${sp}x (serial $(_secs "$ser_ms")s / par $(_secs "$par_ms")s)")
            BENCH_ROWS+=("$desc|$j|$(_secs "$ser_ms")|$(_secs "$par_ms")|$sp|PASS")
        else
            printf '%9ss   speedup %6sx   \033[31mFAIL\033[0m  %s\n' "$(_secs "$par_ms")" "$sp" "$reason"
            FAIL=$((FAIL+1)); RESULTS+=("FAIL|[benchmark] $desc @${j}j -- $reason")
            BENCH_ROWS+=("$desc|$j|$(_secs "$ser_ms")|$(_secs "$par_ms")|$sp|FAIL")
        fi
    done
    echo
}

# The number of CHUNKS is set by --p_len; --jobs only decides how many run at once.
# Correctness therefore does not depend on it — the same chunks are produced and
# reassembled either way — so the correctness tiers run at the SMALLEST requested
# level rather than the largest. Running them at 32 just adds contention on a shared
# host and slows the suite down for no extra coverage. --jobs is what the benchmark
# sweeps; for everything else it is effectively a don't-care.
CORRJOBS=$(printf '%s' "$PBCF_JOBS" | tr ',' '\n' | sort -n | head -1)
for i in "${!T_CMD[@]}"; do
    _selected "${T_TIER[$i]}" || continue
    if [ "${T_TIER[$i]}" = benchmark ]; then
        run_bench "$i"
    else
        run_one "$i" "$CORRJOBS"
    fi
done

echo
echo "-------------------------------------------"
printf '%s: %d passed, %d failed%s\n' "$PBCF_LABEL" "$PASS" "$FAIL" \
    "$([ "$SKIP" -gt 0 ] && echo ", $SKIP skipped")"
# A benchmark run and a correctness run must not write the SAME file. The guide asks
# for both on zlab2 and one HPC, and with one name the second silently overwrote the
# first — losing the correctness report the tester was asked to send back. The naming
# now matches the other scripts: <kind>_report_<label>.md.
if _selected benchmark; then
    REPORT="$SCRIPT_DIR/benchmark_report_${PBCF_LABEL}.md"
else
    REPORT="$SCRIPT_DIR/test_report_${PBCF_LABEL}.md"
fi
{
    echo "# pbcftools test report — $PBCF_LABEL"
    echo
    echo "- bcftools: $(bcftools --version 2>/dev/null | head -1)"
    echo "- tiers: $PBCF_TIERS"
    echo "- jobs: $PBCF_JOBS"
    if _selected benchmark; then
        echo "- benchmark sites: $PBCF_SITES (region ${PBCF_REGION_SITES:-whole genome})"
        echo "- benchmark genotypes: $PBCF_GENO (region ${PBCF_REGION_GENO:-whole genome})"
        echo "- work dir free space at start: ${WORK_FREE_GB} GB"
        echo "- chunk size: $PBCF_P_LEN (geno) / $(pbcf_plen_for sites) (sites)"
    else
        echo "- data: synthetic fixtures (no download required)"
    fi
    echo "- result: $PASS passed, $FAIL failed${SKIP:+, $SKIP skipped}"
    echo
    if [ "${#BENCH_ROWS[@]}" -gt 0 ]; then
        echo "## Speedup"
        echo
        echo "Serial time is measured ONCE per workload; each row is one job level"
        echo "against that same serial run."
        echo
        if [ "$BENCH_TOOSMALL" = 1 ]; then
            echo "> **These numbers are not a benchmark.** At least one workload ran"
            echo "> serially in under a second, so the ratios measure pbcftools'"
            echo "> fixed startup cost rather than any parallel gain. Use the real"
            echo "> 1000 Genomes files (see tests/README.md) for figures worth quoting."
            echo
        fi
        echo "| workload | jobs | serial (s) | parallel (s) | speedup | output |"
        echo "|---|--:|--:|--:|--:|---|"
        for b in "${BENCH_ROWS[@]}"; do
            IFS='|' read -r d j sr pr sp st <<< "$b"
            printf '| %s | %s | %s | %s | **%sx** | %s |\n' "$d" "$j" "$sr" "$pr" "$sp" "$st"
        done
        echo
    fi
    echo "## All checks"
    echo
    echo "| result | test |"
    echo "|---|---|"
    for r in "${RESULTS[@]}"; do printf '| %s | %s |\n' "${r%%|*}" "${r#*|}"; done
} > "$REPORT"
echo "Report: $REPORT"
if [ "$PBCF_KEEP" = 1 ]; then
    # --keep is useless without this: the working directory is an mktemp name, so a
    # user who asked to keep the outputs previously had to guess which
    # /tmp/pbcf_tests.* was theirs.
    echo "Outputs: $ROOT"
    echo "         ref/<test>/      what bcftools produced"
    echo "         <test>.*         what pbcftools produced, same name"
    echo "         logs/            stdout+stderr of both sides, per test"
fi
[ "$FAIL" = 0 ] || exit 1
