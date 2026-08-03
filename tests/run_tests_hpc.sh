#!/bin/bash
#=============================================================================
# pbcftools HPC (cluster-backend) Test Suite
#
# Companion to run_tests.sh. Instead of the local ForkManager backend, this
# routes the PARALLEL side of each test through the LSF (or Slurm) scheduler
# backend -- pbcftools submits one bsub/sbatch job per region chunk, the
# scheduler spreads them across compute nodes, and the merged output is
# compared against serial bcftools.
#
# The primary result is the Match column (LSF-parallel output == serial
# bcftools). Timings include scheduler queue latency, so speedup here is noisy
# and secondary.
#
# Run the controller from an interactive session or the login node (it only
# submits + polls). --p_dir stays under tests/, which must be a SHARED
# filesystem visible to all compute nodes.
#
# Usage:
#   bash run_tests_hpc.sh                                  # LSF, region 1:1-50Mb, 50 jobs
#   bash run_tests_hpc.sh --jobs 20,50 --p_len 5MB          # sweep concurrency
#   bash run_tests_hpc.sh --benchmark                      # genome-wide sites (~310 chunks)
#   bash run_tests_hpc.sh --p_queue normal --p_account myproj
#   bash run_tests_hpc.sh --p_cpu 4 --p_mem 16GB              # fatter per-job request
#   bash run_tests_hpc.sh --p_mode slurm                    # Slurm instead of LSF
#   bash run_tests_hpc.sh <label>                          # or --label <label>
#
# Works for BOTH schedulers via --p_mode lsf|slurm (default lsf). A platform
# <label> (positional or --label; default hostname) makes the report
# DISTINGUISHABLE: it is written to
#   tests/test_report_<label>_<pmode>.md   (host + CPU + OS captured)
#=============================================================================
set -uo pipefail

# Uses associative arrays (declare -A) -> bash >= 4 (macOS ships 3.2). HPC login
# nodes are Linux with bash >= 4, so this rarely bites here, but guard anyway.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "ERROR: $(basename "$0") needs bash >= 4 (you have ${BASH_VERSION:-?})." >&2
    echo "  Install a newer bash and run the script with it (e.g. brew install bash)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # absolute; data via $SCRIPT_DIR/data (the tests/data symlink)
# This script keeps its own argument parser (the cluster options have no counterpart
# in the local scripts), but the CHUNK-SIZE grammar must not diverge: source
# common.sh for pbcf_scale_plen so a --p_len spelling means the same thing here as
# it does locally. common.sh only sets defaults and defines functions; the names it
# sets (PBCF_*) are not the ones used below.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"
PBCF="perl $SCRIPT_DIR/../bin/pbcftools.pl"
SITES="$SCRIPT_DIR/data/ALL.wgs.phase3_shapeit2_mvncall_integrated_v5b.20130502.sites.vcf.gz"
GENO_CHR1="$SCRIPT_DIR/data/ALL.chr1.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz"
GENO="$GENO_CHR1"
OUTDIR="$SCRIPT_DIR/tmp_hpc_$$"     # under tests/ -> shared FS on HPC
PLEN="10MB"

# Backend + cluster options
PMODE="lsf"
JOB_LEVELS=(50)            # concurrent scheduler jobs to sweep (--jobs N[,N,...])
                           # NB: named --jobs, not --p_jobs, to avoid confusion with
                           # pbcftools' own --p_jobs which we set per level below.
PWAL="1h"
PMEM="8GB"
PCPU=""      # CPUs per scheduler job; empty = pbcftools default (1)
PQUEUE=""
PACCT=""

# Region: default a modest window for a fast correctness check; --benchmark uses the
# same per-type defaults as the local scripts -- SITES operations read a sites-only
# file where per-record work is tiny, so they want the whole genome; GENOTYPE
# operations carry 2504 sample columns and one chromosome is already plenty.
MODE="region"
LABEL=""
SITES_REGION="1:1-50000000"
GENO_REGION="1:1-50000000"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --benchmark) MODE="benchmark"; SITES_REGION=""; GENO_REGION="1"; shift ;;
        --region)    MODE="custom"; SITES_REGION="$2"; GENO_REGION="$2"; shift 2 ;;
        --sites-region) MODE="custom"; SITES_REGION="$2"; shift 2 ;;   # sites data is chr1
        --geno-region)  MODE="custom"; GENO_REGION="$2";  shift 2 ;;   # genotype data is chr1
        --jobs)      IFS=',' read -ra JOB_LEVELS <<< "$2"; shift 2 ;;
        # Renamed to --jobs so it is not confused with pbcftools' OWN --p_jobs
        # (which this harness sets per level internally). Fail loudly rather than
        # silently accepting both spellings.
        --p_jobs)     echo "ERROR: use --jobs (this harness's concurrency sweep)." >&2
                     echo "       --p_jobs is pbcftools' own option and is set per level internally." >&2
                     exit 2 ;;
        --p_len)      PLEN="$2"; shift 2 ;;
        --p_mode)     PMODE="$2"; shift 2 ;;
        --p_wal)      PWAL="$2"; shift 2 ;;
        --p_mem)      PMEM="$2"; shift 2 ;;
        --p_cpu)      PCPU="$2"; shift 2 ;;
        --p_queue)    PQUEUE="$2"; shift 2 ;;
        --p_account)  PACCT="$2"; shift 2 ;;
        --label)     LABEL="$2"; shift 2 ;;
        -*)          echo "Unknown option: $1"; exit 1 ;;
        *)           [ -z "$LABEL" ] && LABEL="$1"; shift ;;
    esac
done

# Platform label -> DISTINGUISHABLE report filename (by platform AND scheduler),
# so outputs uploaded to one place never collide. Same convention as run_tests.sh.
LABEL="${LABEL:-$(hostname 2>/dev/null || uname -s)}"
REPORT="$SCRIPT_DIR/test_report_${LABEL}_${PMODE}.md"

# Portable platform / hardware capture (shared with run_tests.sh / run_regression.sh).
first_nonempty() { local v; for v in "$@"; do v="$(printf '%s' "$v" | xargs 2>/dev/null)"; [ -n "$v" ] && { printf '%s' "$v"; return; }; done; printf '?'; }
HOST="$(first_nonempty "$(hostname 2>/dev/null)")"
NCPU_HW="$(first_nonempty "$(nproc 2>/dev/null)" "$(sysctl -n hw.ncpu 2>/dev/null)")"
CPU_MODEL="$(first_nonempty \
  "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)" \
  "$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')")"
MEM_GB="$(first_nonempty "$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)")"
OS_DETAIL="$(first_nonempty "$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}" )" "$(uname -sr)")"

# Portable helpers (macOS lacks md5sum and `date +%N`; perl is always present).
_md5() { perl -MDigest::MD5 -e 'print Digest::MD5->new->addfile(*STDIN)->hexdigest, "\n"'; }
now()  { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
# Float arithmetic WITHOUT `bc`: it is absent from minimal installs (e.g. Fedora
# perl-interpreter/base images) and is not worth a hard dependency when perl is
# already required to run pbcftools. Note these ROUND, whereas `bc scale=2`
# TRUNCATED — so a speedup of 6.3470 now reports 6.35, not 6.34.
_fsub() { perl -e 'printf "%.3f", $ARGV[0] - $ARGV[1]' "$1" "$2"; }
_fdiv() { perl -e 'my ($a,$b)=@ARGV; if ($b > 0) { printf "%.2f", $a/$b } else { print "N/A" }' "$1" "$2"; }
# Fail-closed output validity: exists, non-empty, valid BGZF if it claims to be,
# and >=1 record/line of content (md5 of an empty body is a fixed non-empty hash,
# so a hash check alone would let empty==empty pass).
_output_ok() {
    local f="$1"; [ -s "$f" ] || return 1
    case "$f" in
        *.vcf.gz|*.bcf) bgzip -t "$f" 2>/dev/null || return 1
                        # wc -l reads fully (no SIGPIPE under pipefail); need >=1 record.
                        [ "$(bcftools view -H "$f" 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ] || return 1 ;;
    esac
    return 0
}

SITES_RFLAG=""; [ -n "$SITES_REGION" ] && SITES_RFLAG="-r $SITES_REGION"
GENO_RFLAG="";  [ -n "$GENO_REGION" ]  && GENO_RFLAG="-r $GENO_REGION"

# Backend flags appended to every parallel (pbcftools) command. __NJOB__ and
# __TMPDIR__ are substituted per run.
# --p_len is the GENOTYPE chunk size; sites workloads get PBCF_P_LEN_SITES_FACTOR
# times it. A sites chunk of the same span carries far less work -- measured across
# five machines, a 1MB sites chunk cost ~1s of fixed overhead (process start, open,
# index seek on a 1.9GB file) against ~25ms of actual work, so parallel time scaled
# as 1/jobs with a constant product and never beat serial. Scheduler queue latency
# makes this WORSE on a cluster, not better, so the same scaling applies here.
PLEN_GENO="$PLEN"
PLEN_SITES=$(pbcf_scale_plen "$PLEN" "$PBCF_P_LEN_SITES_FACTOR")
if [ "$PLEN_SITES" = OVERFLOW ]; then
    echo "WARNING: --p_len '$PLEN' scaled by $PBCF_P_LEN_SITES_FACTOR is out of range;" \
         "using it unchanged for sites workloads" >&2
    PLEN_SITES="$PLEN"
fi

_backend() {   # _backend <chunk-size>
    local out="--p_mode $PMODE --p_jobs __NJOB__ --p_len $1 --p_dir __TMPDIR__ --p_ref 37 --p_yes"
    # Wall time, memory, queue and account are scheduler concepts; the Local backend
    # has no use for them.
    if [ "$PMODE" != "local" ]; then
        out="$out --p_wal $PWAL --p_mem $PMEM"
        [ -n "$PCPU" ]   && out="$out --p_cpu $PCPU"
        [ -n "$PQUEUE" ] && out="$out --p_queue $PQUEUE"
        [ -n "$PACCT" ]  && out="$out --p_account $PACCT"
    fi
    printf '%s' "$out"
}
BACKEND_SITES=$(_backend "$PLEN_SITES")
BACKEND_GENO=$(_backend "$PLEN_GENO")
BACKEND="$BACKEND_GENO"   # retained for any workload not classified below

#--- Preflight -------------------------------------------------------------
# --p_mode local runs the same workloads through the Local backend, with no
# scheduler involved. That is how this script is verified off-cluster: the manifest
# parsing, command construction, comparison and reporting are all exercised, and only
# the submit/poll path is not.
if [ "$PMODE" != "local" ]; then
    SCHED_CMD="bsub"; [ "$PMODE" = "slurm" ] && SCHED_CMD="sbatch"
    command -v "$SCHED_CMD" >/dev/null 2>&1 || {
        echo "ERROR: '$SCHED_CMD' not found -- are you on a node that can submit $PMODE jobs?"
        echo "       (Run this from an interactive session or the login node.)"
        exit 2; }
fi
[ -e "$SITES" ] || { echo "ERROR: sites file not found: $SITES"; echo "  Sync the 1000G data into tests/data/ (see README)."; exit 2; }
[ -e "$SITES.csi" ] || bcftools index "$SITES"

mkdir -p "$OUTDIR"
declare -A RESULTS
TOTAL_PASS=0; TOTAL_FAIL=0
declare -a ALL_TESTS

# run_test <name> <serial-line> <parallel-line> <out-prefix> [compare]
#
# The lines are RAW manifest text, evaluated with $OUT exported -- never
# pre-expanded into a string. Pre-expanding mangled nested quotes (`-i 'TYPE="snp"'`
# became unparseable) and, because it forced different -o paths on the two sides,
# made every VCF header differ in the ##bcftools_*Command line it records. Both
# sides now write to the SAME $OUT and the serial artifacts are moved aside
# afterwards, which is what the local suite does and why its headers match.
run_test() {
    local name="$1" serial_line="$2" par_line="$3" out_prefix="$4" compare="${5:-validate}"
    local ref_dir="$OUTDIR/ref_$name"
    rm -rf "$ref_dir"; mkdir -p "$ref_dir"
    echo ""; echo "================================================================="
    echo "TEST: $name"; echo "================================================================="

    rm -f "$out_prefix".*
    echo "  [serial] Running..."
    local serial_rc=0
    OUT="$out_prefix"; export OUT
    local t1=$(now); eval "$serial_line" >/dev/null 2>&1 || serial_rc=$?; local t2=$(now)
    local serial_time=$(_fsub "$t2" "$t1")
    echo "  Serial: ${serial_time}s (rc=$serial_rc)"
    RESULTS["${name}:serial_time"]="$serial_time"
    # Move what serial produced aside; the parallel run reuses the same -o.
    local f
    for f in "$out_prefix".*; do [ -e "$f" ] && mv "$f" "$ref_dir/" 2>/dev/null; done
    # Serial validity gate: exit 0 AND valid, non-empty output, else every level FAILs.
    local serial_ok=1 serial_out=""
    for f in "$ref_dir"/*; do
        case "$f" in *.csi|*.tbi) continue ;; esac
        [ -e "$f" ] && serial_out="$f" && break
    done
    { [ "$serial_rc" -eq 0 ] && [ -n "$serial_out" ] && _output_ok "$serial_out"; } || serial_ok=0

    for njob in "${JOB_LEVELS[@]}"; do
        local par_cmd="${par_line//__NJOB__/$njob}"
        local tmpdir="$OUTDIR/${name}_${njob}job_tmp"
        rm -rf "$tmpdir" "$out_prefix".*; mkdir -p "$tmpdir"
        par_cmd="${par_cmd//__TMPDIR__/$tmpdir}"
        OUT="$out_prefix"; export OUT
        local par_out=""

        echo "  [$PMODE ${njob}jobs] Submitting (live pbcftools output below)..."
        echo "  ----------------------------------------------------------------"
        local par_rc=0
        local t3=$(now); eval "$par_cmd" || par_rc=$?; local t4=$(now)
        echo "  ----------------------------------------------------------------"
        local par_time=$(_fsub "$t4" "$t3")

        # Fail-closed: both sides must have exit 0 and valid, non-empty output
        # before any content check; equal record counts are NEVER a PASS fallback.
        local match="FAIL"
        if [ "$serial_ok" -ne 1 ]; then
            match="FAIL (serial produced no valid output, rc=$serial_rc)"
        else
          for f in "$out_prefix".*; do
              case "$f" in *.csi|*.tbi) continue ;; esac
              [ -e "$f" ] && par_out="$f" && break
          done
        fi
        if [ "$serial_ok" -ne 1 ]; then :
        elif [ "$par_rc" -ne 0 ] || [ -z "$par_out" ] || ! _output_ok "$par_out"; then
            match="FAIL (parallel produced no valid output, rc=$par_rc)"
        else
          case "$compare" in
            # The SAME comparison the local suite uses (common.sh), so a cluster
            # result and a local result mean the same thing. It knows which
            # tolerances are legitimate -- Date= in provenance, header line ORDER,
            # stats section order and number formatting -- and which are not.
            validate)
                local _why
                if _why=$(pbcf_validate "$serial_out" "$par_out" 2>&1); then match="PASS"
                else match="FAIL (${_why})"; fi ;;
            exact)  diff -q "$serial_out" "$par_out" >/dev/null 2>&1 && match="PASS" || match="FAIL (differ)" ;;
            vcf_body)
                local s=$(bcftools view -H "$serial_out" 2>/dev/null | _md5)
                local p=$(bcftools view -H "$par_out"    2>/dev/null | _md5)
                if [ -n "$s" ] && [ "$s" = "$p" ]; then match="PASS"; else
                    local sc=$(bcftools view -H "$serial_out" 2>/dev/null | wc -l | tr -d ' ')
                    local pc=$(bcftools view -H "$par_out"    2>/dev/null | wc -l | tr -d ' ')
                    match="FAIL (bodies differ; serial=$sc parallel=$pc recs)"
                fi ;;
            stats_sn)
                local s=$(grep '^SN' "$serial_out" 2>/dev/null | sort)
                local p=$(grep '^SN' "$par_out"    2>/dev/null | sort)
                { [ -n "$s" ] && [ "$s" = "$p" ]; } && match="PASS" || match="FAIL (SN lines differ or empty)" ;;
          esac
        fi

        local speedup=$(_fdiv "$serial_time" "$par_time")
        echo "    Time: ${par_time}s  Speedup: ${speedup}x  Match: $match"
        RESULTS["${name}:${njob}:time"]="$par_time"
        RESULTS["${name}:${njob}:speedup"]="$speedup"
        RESULTS["${name}:${njob}:match"]="$match"
        [[ "$match" == PASS* ]] && TOTAL_PASS=$((TOTAL_PASS+1)) || TOTAL_FAIL=$((TOTAL_FAIL+1))
        rm -rf "$tmpdir" "$out_prefix".*
    done
    rm -rf "$ref_dir"
}

echo "pbcftools HPC Test Suite ($PMODE backend)"
echo "========================================="
echo "Label: $LABEL   Host: $HOST"
echo "Date: $(date)"
echo "bcftools: $(bcftools --version | head -1)"
echo "Backend: $PMODE | concurrency (jobs): ${JOB_LEVELS[*]} | chunk geno/sites: $PLEN_GENO/$PLEN_SITES | $PWAL wall, $PMEM mem${PQUEUE:+, queue $PQUEUE}${PACCT:+, project $PACCT}"
echo "Region: sites ${SITES_REGION:-whole genome} | genotypes ${GENO_REGION:-whole genome} (mode: $MODE)"
echo "NOTE: timings include queue latency; the Match column is the real result."
echo ""

#-----------------------------------------------------------------------------
# Workloads come from tests/tests.cmd, benchmark tier -- the SAME list the local
# `run_tests.sh --benchmark` runs. This script used to carry its own hardcoded set
# of seven, which drifted from the manifest's eleven and compared with its own
# rules, so the two suites measured different things and could disagree for reasons
# that had nothing to do with the backend. One manifest, one comparison function.
#
# Each manifest line is shell, evaluated with the same variables run_tests.sh binds:
# $SITES/$GENO (datasets), $R_SITES/$R_GENO (region flags), $OUT (an output prefix),
# $SAMPLES/$SAMPLE1 (sample names taken from the bound genotype file). A line naming
# $GENO/$R_GENO is a genotype workload and gets the genotype chunk size; everything
# else is a sites workload and gets the 10x one.
#-----------------------------------------------------------------------------
MANIFEST="$SCRIPT_DIR/tests.cmd"
[ -f "$MANIFEST" ] || { echo "ERROR: manifest not found: $MANIFEST"; exit 2; }

[ -e "$GENO" ] || { echo "ERROR: genotype file not found: $GENO"; exit 2; }
[ -e "$GENO.csi" ] || bcftools index "$GENO"

# Sample names must come from the genotype file actually in use, never hardcoded.
SAMPLE1=$(bcftools query -l "$GENO" 2>/dev/null | head -1)
SAMPLES=$(bcftools query -l "$GENO" 2>/dev/null | head -3 | paste -sd, -)
R_SITES="$SITES_RFLAG"; R_GENO="$GENO_RFLAG"
export SITES GENO R_SITES R_GENO SAMPLE1 SAMPLES

_hpc_slug() {   # a short, filesystem-safe name from a description
    printf '%s' "$1" | tr -cs 'A-Za-z0-9' '_' | cut -c1-28 | sed 's/_*$//'
}

hpc_tier=""; hpc_desc=""; hpc_idx=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '##'*)     hpc_tier=$(printf '%s' "${line#\#\#}" | sed 's/^ *//; s/ *$//; s/ .*//'); hpc_desc="" ;;
        '#'*)      hpc_desc=$(printf '%s' "${line#\#}" | sed 's/^ *//; s/ *$//') ;;
        bcftools*)
            if [ "$hpc_tier" = benchmark ]; then
                hpc_idx=$((hpc_idx+1))
                name=$(printf 'w%02d_%s' "$hpc_idx" "$(_hpc_slug "${hpc_desc:-benchmark}")")
                case "$line" in
                    *'$GENO'*|*'$R_GENO'*) be="$BACKEND_GENO" ;;
                    *)                     be="$BACKEND_SITES" ;;
                esac
                # Pass the RAW manifest line through; run_test evaluates it with
                # $OUT exported. Only the leading binary and a trailing stdout
                # redirect are rewritten textually, so quoting inside the command
                # (e.g. -i 'TYPE="snp"') is never disturbed.
                ser_line="$line"
                par_line="${line/#bcftools/$PBCF}"
                par_line=$(printf '%s' "$par_line" \
                    | sed 's/[[:space:]]*>[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/ -o \1/')
                par_line="$par_line $be"
                ALL_TESTS+=("$name")
                run_test "$name" "$ser_line" "$par_line" "$OUTDIR/$name" "validate"
            fi
            hpc_desc="" ;;
        *) : ;;
    esac
done < "$MANIFEST"

[ "$hpc_idx" -gt 0 ] || { echo "ERROR: no benchmark workloads found in $MANIFEST"; exit 2; }

#--- Report ----------------------------------------------------------------
echo ""; echo "================================================================="
echo "SUMMARY: $TOTAL_PASS passed, $TOTAL_FAIL failed out of $((TOTAL_PASS+TOTAL_FAIL))"
echo "================================================================="

JOB_HEADER=""; JOB_SEP=""
for j in "${JOB_LEVELS[@]}"; do JOB_HEADER+=" | ${j}-job (s) | ${j}x"; JOB_SEP+=" | --- | ---"; done

{
  echo "# pbcftools HPC Backend Report ($PMODE)"
  echo ""
  echo "| Parameter | Value |"
  echo "|---|---|"
  echo "| Label | $LABEL |"
  echo "| Host | $HOST |"
  echo "| Date (UTC) | $(date -u '+%Y-%m-%d %H:%M') |"
  echo "| Backend | $PMODE |"
  echo "| OS | $OS_DETAIL |"
  echo "| CPU model | $CPU_MODEL |"
  echo "| Cores (controller) | $NCPU_HW |"
  echo "| RAM GB (controller) | $MEM_GB |"
  echo "| bcftools | $(bcftools --version | head -1) |"
  echo "| Concurrency (jobs) | ${JOB_LEVELS[*]} |"
  echo "| Chunk size (geno / sites) | $PLEN_GENO / $PLEN_SITES |"
  echo "| Per-job | $PWAL wall, $PMEM mem${PQUEUE:+, queue $PQUEUE}${PACCT:+, project $PACCT} |"
  echo "| Region (sites / geno) | ${SITES_REGION:-whole genome} / ${GENO_REGION:-whole genome} (mode $MODE) |"
  echo "| Result | **$TOTAL_PASS passed, $TOTAL_FAIL failed** |"
  echo ""
  echo "Correctness = ${PMODE}-parallel output vs serial bcftools. Timings include"
  echo "scheduler queue latency and are secondary."
  echo ""
  echo "| # | Test${JOB_HEADER} | Match |"
  echo "| --- | ---${JOB_SEP} | --- |"
  idx=0
  for name in "${ALL_TESTS[@]}"; do
    idx=$((idx+1)); row="| $idx | $name"; agg="PASS"
    # Aggregate across ALL concurrency levels: PASS only if EVERY level passed;
    # otherwise report the first failing level (never hide it behind the last).
    for j in "${JOB_LEVELS[@]}"; do
      row+=" | ${RESULTS[${name}:${j}:time]:-N/A} | ${RESULTS[${name}:${j}:speedup]:-N/A}"
      lvl_m="${RESULTS[${name}:${j}:match]:-N/A}"
      case "$lvl_m" in PASS) ;; *) [ "$agg" = "PASS" ] && agg="${j}job: $lvl_m" ;; esac
    done
    echo "$row | $agg |"
  done
} > "$REPORT"

echo ""; echo "Report written to: $REPORT"
rm -rf "$OUTDIR"
exit $TOTAL_FAIL
