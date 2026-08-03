#!/usr/bin/env bash
#=============================================================================
# run_all.sh — every pbcftools test on ONE MACHINE, in order, using the local
#              backend. For a cluster use tests/run_tests_hpc.sh, which submits
#              through LSF or Slurm and needs scheduler options this script does
#              not take.
#
#   bash tests/run_all.sh <label> [jobs] [region] [p_len] [nfiles]
#
#   <label>   host name for the reports        (required, e.g. zlab2)
#   [jobs]    concurrency levels to sweep      (default 4,8,16,32)
#   [region]  override BOTH benchmark regions   (default: per-type — sites use the
#                                               whole genome, genotypes use chr1).
#                                               Pass "" or - to keep the per-type
#                                               defaults while still setting the
#                                               arguments after it.
#   [p_len]   chunk size for GENO operations   (default 10M; sites use 10x this)
#   [nfiles]  files for the merge test         (default 100; must not
#                                               exceed the fixture — see
#                                               make_merge_fixture.sh)
#
#   bash tests/run_all.sh zlab2
#   bash tests/run_all.sh macos 4,8
#   bash tests/run_all.sh zlab2 4,8,16,32,64 1:1-50000000 5MB 50
#   bash tests/run_all.sh zlab2 4,8,16,32,64,128 - 1M 100   # per-type regions, 1M chunk
#
# Runs four steps and writes one report each:
#
#   1. correctness   tests/test_report_<label>.md         no data needed
#   2. safety        tests/regression_report_<label>.md   no data needed
#   3. benchmark     tests/benchmark_report_<label>.md    needs 1000G data
#   4. merge         tests/merge_report_<label>.md        needs a merge fixture
#
# Steps 3 and 4 are SKIPPED with a clear note if their data is absent, so this
# script is safe to run anywhere: on a laptop you get steps 1-2, on a machine with
# the 1000G files you get all four. See tests/README.md for the download links.
#
# SCRATCH SPACE: steps 3-4 need ~150 GB. Check `df -h /tmp` first -- recent distros
# mount /tmp as a tmpfs sized at ~50% of RAM, which is usually too small, and a
# whole-chromosome genotype query alone writes a ~64 GB TSV. Redirect it with
#     TMPDIR=/path/with/space bash tests/run_all.sh <label>
# Steps 1-2 use small synthetic fixtures and need no space.
#=============================================================================

# macOS ships bash 3.2, which is too old for the arrays these scripts use. Re-exec
# under a newer bash if one is installed rather than failing halfway through.
if [ -z "${PBCF_REEXEC:-}" ] && [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
        if [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO:-0}')" -ge 4 ]; then
            echo "NOTE: bash ${BASH_VERSION} is too old; re-running under $b"
            PBCF_REEXEC=1 exec "$b" "$0" "$@"
        fi
    done
    echo "ERROR: these tests need bash >= 4; you have ${BASH_VERSION}." >&2
    echo "       On macOS:  brew install bash" >&2
    exit 2
fi

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

LABEL="${1:-}"
JOBS="${2:-4,8,16,32}"
# Empty means "let each data type use its own default" -- sites operations read a
# sites-only file where per-record work is tiny, so they want the whole genome and a
# larger chunk; genotype operations carry 2504 sample columns and chr1 is plenty.
# Forcing one region onto both made the sites workloads measure per-chunk overhead
# rather than parallel speedup.
REGION="${3:-}"
# "-" and "default" mean "leave the regions alone", so the arguments AFTER region can
# be set without also pinning both datasets to one region. Passing a region here sets
# BOTH via --region, which is rarely what you want for a benchmark: the sites file is
# genome-wide and the genotype file is chr1, and their densities differ by more than
# an order of magnitude.
case "$REGION" in -|default) REGION="" ;; esac
PLEN="${4:-10M}"
NFILES="${5:-100}"

if [ -z "$LABEL" ]; then
    sed -n '3,25p' "$0"
    exit 2
fi

command -v bcftools >/dev/null 2>&1 || { echo "ERROR: bcftools not on PATH" >&2; exit 2; }
perl -c "$HERE/../bin/pbcftools.pl" >/dev/null 2>&1 \
    || { echo "ERROR: pbcftools does not compile:" >&2
         perl -c "$HERE/../bin/pbcftools.pl" 2>&1 | sed 's/^/       /' >&2; exit 2; }

# The benchmark's two datasets, and the merge fixture. Only steps 3 and 4 need them.
SITES="$HERE/data/ALL.wgs.phase3_shapeit2_mvncall_integrated_v5b.20130502.sites.vcf.gz"
GENO="$HERE/data/ALL.chr1.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz"
MERGELIST="$HERE/data/vcfs.lst"

STEP=0
declare -a DONE SKIPPED FAILED
_banner() {
    STEP=$((STEP+1))
    echo
    echo "==============================================================="
    printf '  %d/4  %s\n' "$STEP" "$1"
    echo "==============================================================="
}
_run() {                       # _run <name> <command...>
    local name="$1"; shift
    if "$@"; then DONE+=("$name"); else FAILED+=("$name"); fi
}

echo "pbcftools — full test run"
echo "  label  : $LABEL"
echo "  jobs   : $JOBS"
echo "  region : ${REGION:-per-type (sites: whole genome, geno: 1)}"
echo "  p_len  : $PLEN  (geno; sites use 10x)"
echo "  nfiles : $NFILES  (merge)"
echo "  backend: local (for LSF/Slurm use run_tests_hpc.sh)"
# Print this beside the other run parameters so every console log carries it. A run
# that dies partway through the benchmark is nearly always this number being small.
TMPFREE=$(df -Pk "${TMPDIR:-/tmp}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}')
echo "  scratch: ${TMPDIR:-/tmp} (${TMPFREE:-?} GB free; steps 3-4 want ~150 GB)"
echo "  bash   : $BASH_VERSION"
echo "  started: $(date '+%Y-%m-%d %H:%M:%S')"

#--- 1. Correctness --------------------------------------------------------
# No downloaded data: builds its own synthetic fixtures. --jobs is deliberately
# omitted — the chunking comes from --p_len and --jobs only sets concurrency, so it
# does not change the result.
_banner "Correctness — serial vs parallel over tests.cmd"
_run correctness bash "$HERE/run_tests.sh" --label "$LABEL"

#--- 2. Safety -------------------------------------------------------------
# --bench (NOT a bare "bench") adds a fixed synthetic speedup measurement: identical
# work on every platform, so the number is comparable across hosts without any
# download. Takes an extra 1-2 minutes.
_banner "Safety — failure, interrupt and data-preservation invariants"
_run safety bash "$HERE/run_tests_safety.sh" --label "$LABEL" --bench

#--- 3. Benchmark ----------------------------------------------------------
_banner "Benchmark — timed serial vs parallel on real data"
if [ -f "$SITES" ] && [ -f "$GENO" ]; then
    if [ -n "$REGION" ]; then
        _run benchmark bash "$HERE/run_tests.sh" --label "$LABEL" --benchmark \
            --jobs "$JOBS" --region "$REGION" --p_len "$PLEN"
    else
        _run benchmark bash "$HERE/run_tests.sh" --label "$LABEL" --benchmark \
            --jobs "$JOBS" --p_len "$PLEN"
    fi
else
    echo "SKIPPED — the 1000 Genomes files are not in tests/data/:"
    [ -f "$SITES" ] || echo "    missing: $(basename "$SITES")"
    [ -f "$GENO" ]  || echo "    missing: $(basename "$GENO")"
    echo "  See tests/README.md for the download links. Correctness and safety"
    echo "  above do not need them; only this step and the merge step do."
    SKIPPED+=("benchmark (no 1000G data)")
fi

#--- 4. Merge --------------------------------------------------------------
_banner "Merge — many-input merge scaling"
if [ -f "$MERGELIST" ]; then
    # Check the count HERE, where the fixture size is known, rather than letting the
    # merge script exit 2 and be recorded as a failure. Asking for more files than
    # exist is a mistake in the invocation, not a defect in pbcftools.
    AVAIL=$(grep -c . "$MERGELIST" 2>/dev/null || echo 0)
    if [ "$NFILES" -gt "$AVAIL" ]; then
        echo "NOTE: asked for $NFILES files but the fixture has $AVAIL — using $AVAIL."
        echo "      For more, rebuild it:"
        echo "          bash tests/make_merge_fixture.sh --nfiles $NFILES --nsamples 10 --force"
        echo
        NFILES="$AVAIL"
    fi
    _run merge bash "$HERE/run_tests_merge.sh" --label "$LABEL" \
        --jobs "$JOBS" --region "${REGION:-1}" --p_len "$PLEN" --nfiles "$NFILES" \
        --out "$HERE/merge_run_${LABEL}"
else
    echo "SKIPPED — no merge fixture at $MERGELIST"
    echo "  Build one first (needs the 1000G chr1 genotypes file):"
    echo "      bash tests/make_merge_fixture.sh --nfiles $NFILES --nsamples 10"
    SKIPPED+=("merge (no fixture)")
fi

#--- Summary ---------------------------------------------------------------
echo
echo "==============================================================="
echo "  Summary — $LABEL"
echo "==============================================================="
for d in ${DONE[@]+"${DONE[@]}"};    do printf '  \033[32mok\033[0m       %s\n' "$d"; done
for s in ${SKIPPED[@]+"${SKIPPED[@]}"}; do printf '  \033[33mskipped\033[0m  %s\n' "$s"; done
for f in ${FAILED[@]+"${FAILED[@]}"};   do printf '  \033[31mFAILED\033[0m   %s\n' "$f"; done
echo
echo "  Reports to send back:"
for r in "test_report_${LABEL}.md" "regression_report_${LABEL}.md" \
         "benchmark_report_${LABEL}.md" "merge_report_${LABEL}.md"; do
    [ -f "$HERE/$r" ] && printf '    %s\n' "$HERE/$r"
done
echo "  finished: $(date '+%Y-%m-%d %H:%M:%S')"

# Non-zero if any step failed, so this can be used in a job script.
[ "${#FAILED[@]}" -eq 0 ] || exit 1
