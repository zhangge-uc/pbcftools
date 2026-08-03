#!/usr/bin/env bash
#=============================================================================
# run_tests_merge.sh — parallel-merge scaling test
#
# Merges many one-sample VCFs with serial `bcftools merge` vs `pbcftools merge`,
# over a genomic region, and checks the merged records are identical. This is
# where parallel merge shows its biggest advantage: serial merge opens all N
# files and streams one region; pbcftools splits the region into chunks and
# merges them concurrently.
#
# Backend (pick one):
#   --jobs N[,N,...]    levels to sweep (alias: --cpus). The BACKEND is chosen by
#                       --p_mode, never by which of these two names you use.
#                       (default 4,8,16,32)
#                       Default depends on --p_mode: local 4,8,16,32; cluster 50,100,200
#                       with --p_mode lsf|slurm. Each job requests 1 CPU (--p_cpu
#                       default); a scheduler may charge more cores to satisfy --p_mem.
#
# Usage:
#   bash run_tests_merge.sh                                # local sweep 4,8,16,32
#   bash run_tests_merge.sh --jobs 8                        # single level, local
#   bash run_tests_merge.sh --cpus 16 --nfiles 100 --region 1:1-50000000
#   bash run_tests_merge.sh --jobs 50 --p_mode lsf --p_queue normal   # cluster
#   bash run_tests_merge.sh --cpus 8 --out ~/merge_check   # keep outputs to inspect
#
# Options:
#   --list FILE     file list of input VCFs        (default tests/data/vcfs.lst;
#                   build it with tests/make_merge_fixture.sh)
#   --nfiles N      use the first N files          (default 100)
#   --region REG    region to merge                (default 1:1-25000000)
#                   NOTE: 1000G Phase 3 contigs are NOT chr-prefixed.
#   --p_ref V        reference for contig sizes     (default 37 for 1000G Phase 3;
#                   needed if inputs lack ##contig lengths)
#   --p_len SIZE     chunk size                     (default 5MB)
#   --out DIR       keep serial+parallel outputs here for inspection (default: temp, removed)
#   --jobs N[,N,..] levels to sweep (alias --cpus); default follows --p_mode:
#                   local 4,8,16,32   cluster 50,100,200
#   --p_mode M      local|lsf|slurm  (default local) — this alone selects the backend
#   --p_wal/--p_mem/--p_cpu/--p_queue/--p_account   cluster per-job resources
#                   --p_cpu = CPUs requested per job (pbcftools default 1). Note a
#                   scheduler may still allocate more cores to satisfy --p_mem.
#   --force-samples 0|1   pass --force-samples to merge (default 1; duplicate sample names)
#   --drop-caches 0|1     evict inputs from the page cache before each run, for cold-cache
#                         numbers (needs passwordless sudo or vmtouch; default 0)
#   --label <platform>    (or positional) tag the report: tests/merge_report_<label>.md
#                         (default hostname) so per-platform outputs don't collide
#
# For meaningful I/O timing the inputs must be on LOCAL disk, not a network /
# sshfs mount. With a warm cache the serial run pre-loads the region and the
# parallel speedup can look optimistic; use --drop-caches 1 for honest numbers.
#=============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PBCF="perl $SCRIPT_DIR/../bin/pbcftools.pl"

LIST="$SCRIPT_DIR/data/vcfs.lst"   # via the tests/data symlink, like the other scripts
NFILES=100
REGION="1:1-25000000"
PREF="37"
PLEN="5MB"
OUT=""
LABEL=""
PMODE="local"
PJOBS=""
# Concurrency levels to sweep, set by --jobs (alias --cpus). Left empty here: the
# default depends on the BACKEND, not on which option name was used, and --p_mode may
# appear after --jobs on the command line, so the default is applied once parsing is
# finished (local 4,8,16,32 workers; cluster 50,100,200 concurrent jobs).
LEVELS=()
PWAL="1h"; PMEM="8GB"; PCPU=""; PQUEUE=""; PACCT=""
FORCE_SAMPLES=1
BACKEND_SET=0
DROP=0          # --drop-caches: evict the input files from the page cache before
                # each run so serial and parallel start from a comparable (cold)
                # cache. Otherwise the serial run warms the cache and the parallel
                # run re-reads it, inflating the speedup.

while [ $# -gt 0 ]; do
    case "$1" in
        --list)     LIST="$2"; shift 2 ;;
        --nfiles)   NFILES="$2"; shift 2 ;;
        --region)   REGION="$2"; shift 2 ;;
        --p_ref)     PREF="$2"; shift 2 ;;
        --p_len)     PLEN="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        # HARMONISED with run_tests.sh and run_tests_hpc.sh: --jobs is the canonical
        # name for the level sweep and --cpus is its alias. Neither selects a backend
        # any more — that is --p_mode's job alone. Previously --cpus implied local and
        # --jobs implied lsf, so the same number meant a different backend depending
        # on which word you used, and the same word meant different things in
        # different scripts.
        --jobs|--cpus) IFS=',' read -ra LEVELS <<< "$2"; BACKEND_SET=1; shift 2 ;;
        --p_mode)    PMODE="$2"; shift 2 ;;
        --p_wal)     PWAL="$2"; shift 2 ;;
        --p_mem)     PMEM="$2"; shift 2 ;;
        --p_cpu)     PCPU="$2"; shift 2 ;;
        --p_queue)   PQUEUE="$2"; shift 2 ;;
        --p_account) PACCT="$2"; shift 2 ;;
        --force-samples) FORCE_SAMPLES="$2"; shift 2 ;;
        --drop-caches) DROP="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)  [ -z "$LABEL" ] && LABEL="$1" || { echo "Unknown option: $1" >&2; exit 2; }; shift ;;
    esac
done

# Platform label for a distinguishable report filename (same convention as the
# other test scripts). Defaults to the hostname.
LABEL="${LABEL:-$(hostname 2>/dev/null || uname -s)}"

if [ "${#LEVELS[@]}" -eq 0 ]; then
    if [ "$PMODE" = "local" ]; then LEVELS=(4 8 16 32); else LEVELS=(50 100 200); fi
fi

#--- Preflight -------------------------------------------------------------
# pbcftools must actually RUN. Parallel::ForkManager is loaded LAZILY by the Local
# backend, so a missing copy breaks every parallel run while --help still works.
if ! perl -c "${PBCF##perl }" >/dev/null 2>&1; then
    echo "ERROR: pbcftools does not compile:"; perl -c "${PBCF##perl }" 2>&1 | sed 's/^/       /' | head -5
    exit 2
fi
if [ "${PMODE:-local}" = "local" ] && ! perl -MParallel::ForkManager -e1 >/dev/null 2>&1; then
    echo "ERROR: Perl module 'Parallel::ForkManager' is not installed (needed for local"
    echo "       execution). Install: sudo dnf install perl-Parallel-ForkManager |"
    echo "       sudo apt install libparallel-forkmanager-perl | cpan Parallel::ForkManager"
    exit 2
fi
command -v bcftools >/dev/null 2>&1 || { echo "ERROR: bcftools not on PATH"; exit 2; }
[ -f "$LIST" ] || { echo "ERROR: file list not found: $LIST"; echo "  (set up symlinks + list first, or pass --list)"; exit 2; }
AVAIL=$(grep -c . "$LIST")
[ "$NFILES" -le "$AVAIL" ] || { echo "ERROR: --nfiles $NFILES exceeds $AVAIL files in $LIST"; exit 2; }
if [ "$PMODE" != "local" ]; then
    SCHED=bsub; [ "$PMODE" = "slurm" ] && SCHED=sbatch
    command -v "$SCHED" >/dev/null 2>&1 || { echo "ERROR: '$SCHED' not found — run from a node that can submit $PMODE jobs."; exit 2; }
fi

#--- Output dir ------------------------------------------------------------
KEEP=1
if [ -z "$OUT" ]; then
    OUT="$(mktemp -d "${TMPDIR:-/tmp}/pbcf_merge.XXXXXX")"; KEEP=0
fi
mkdir -p "$OUT"

FS=""; [ "$FORCE_SAMPLES" = "1" ] && FS="--force-samples"
SUBLIST="$OUT/inputs_${NFILES}.lst"

# Build the sublist with machine-portable ABSOLUTE paths. The list is a local,
# per-machine manifest that may hold absolute paths (possibly baked on another
# machine) OR paths relative to the list's own directory. Either way we anchor
# to where the list actually lives — the VCFs sit next to it under vcfs/ — so a
# copied checkout runs unchanged on any host, CWD, or home directory. bcftools
# resolves list entries against the CWD, so we always emit absolute paths.
LIST_DIR="$(cd "$(dirname "$LIST")" && pwd)"
: > "$SUBLIST"
head -n "$NFILES" "$LIST" | while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    case "$f" in
        /*) if [ -f "$f" ]; then rf="$f"; else rf="$LIST_DIR/vcfs/$(basename "$f")"; fi ;;
        *)  rf="$LIST_DIR/$f" ;;
    esac
    printf '%s\n' "$rf" >> "$SUBLIST"
done

# Fail early with an actionable message instead of a cryptic bcftools hts_open
# error deep in the serial/parallel merge.
FIRST="$(head -n 1 "$SUBLIST")"
if [ ! -f "$FIRST" ]; then
    echo "ERROR: input VCFs not found on this machine."
    echo "  list:     $LIST"
    echo "  resolved: $FIRST"
    echo "  Place the merge VCFs under $LIST_DIR/vcfs/ (the list names files"
    echo "  relative to its own directory), or pass --list pointing at a list"
    echo "  whose paths are absolute or relative to that list's directory."
    exit 2
fi

# backend flags for pbcftools
# Backend flags for ONE concurrency level. Each level gets its own --p_dir child so
# runs never share artifacts. --p_cpu is passed only when the user sets it;
# otherwise pbcftools' default of 1 CPU per job applies. Note a scheduler may
# still allocate more cores than requested in order to satisfy --p_mem.
backend_for() {
    local lvl="$1"
    local b="--p_jobs $lvl --p_len $PLEN --p_ref $PREF --p_dir $OUT/partmp_$lvl --p_yes"
    if [ "$PMODE" != "local" ]; then
        b="$b --p_mode $PMODE --p_wal $PWAL --p_mem $PMEM"
        [ -n "$PCPU" ] && b="$b --p_cpu $PCPU"
        [ -n "$PQUEUE" ] && b="$b --p_queue $PQUEUE"
        [ -n "$PACCT" ]  && b="$b --p_account $PACCT"
    fi
    printf '%s' "$b"
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# Evict the input files from the page cache before a run, so serial and parallel
# start from a comparable (cold) cache. Prefers system-wide drop (needs
# passwordless sudo), falls back to per-file vmtouch, else warns and stays warm.
CACHE_STATE="warm (not dropped — speedup may be optimistic)"
drop_cache() {
    [ "$DROP" = "1" ] || return 0
    if sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; then
        CACHE_STATE="cold (dropped system page cache)"
    elif command -v vmtouch >/dev/null 2>&1; then
        while read -r f; do [ -n "$f" ] && vmtouch -qe "$f" >/dev/null 2>&1; done < "$SUBLIST"
        CACHE_STATE="cold (evicted inputs via vmtouch)"
    else
        CACHE_STATE="warm (--drop-caches requested but no passwordless sudo / vmtouch)"
        echo "  NOTE: --drop-caches requested but no passwordless sudo or vmtouch; cache NOT dropped."
    fi
}

echo "pbcftools merge test"
echo "===================="
echo "files:   $NFILES (of $AVAIL) from $LIST"
echo "region:  $REGION   chunk: $PLEN   pref: $PREF"
if [ "$PMODE" = "local" ]; then
    echo "backend: local   worker levels: ${LEVELS[*]}"
else
    echo "backend: $PMODE   concurrency levels: ${LEVELS[*]}   ($PWAL/$PMEM, ${PCPU:-1} CPU/job${PQUEUE:+, queue $PQUEUE})"
fi
echo "output:  $OUT $([ "$KEEP" = 1 ] && echo '(kept)' || echo '(temp, removed)')"
echo "bcftools: $(bcftools --version | head -1)"
echo

#--- Serial ---------------------------------------------------------------
SER="$OUT/merge_serial.vcf.gz"
drop_cache
# Same shape as `run_tests.sh --benchmark`: name the workload, show the command that
# is actually being timed, time the serial side ONCE, then one line per level.
printf '  \033[1mMerge %d files over %s\033[0m   (chunk %s, cache %s)\n' \
    "$NFILES" "$REGION" "$PLEN" "$CACHE_STATE"
printf '    \033[2mbcftools merge -l %s -r %s %s-Oz -o %s\033[0m\n' \
    "$SUBLIST" "$REGION" "${FS:+$FS }" "$SER"
printf '    %-14s' "serial"
t0=$(now)
bcftools merge -l "$SUBLIST" -r "$REGION" $FS -Oz -o "$SER" 2>"$OUT/serial.err"
rc_ser=$?
t1=$(now)
SER_T=$(perl -e "printf '%.1f', $t1-$t0")
if [ $rc_ser -ne 0 ]; then
    printf '\033[31mFAILED\033[0m  (see %s)\n' "$OUT/serial.err"
    head -3 "$OUT/serial.err"; exit 1
fi
bcftools index -f "$SER" 2>/dev/null
SER_N=$(bcftools view -H "$SER" 2>/dev/null | wc -l | tr -d ' ')
printf '%9ss   %s records' "$SER_T" "$SER_N"
# Same guard as the main benchmark: under a second, the ratio is startup overhead.
BENCH_TOOSMALL=0
if perl -e "exit(($SER_T < 1.0) ? 0 : 1)"; then
    printf '   \033[33m(too small to benchmark — ratios below are startup overhead)\033[0m'
    BENCH_TOOSMALL=1
fi
printf '\n' 

#--- Parallel sweep -------------------------------------------------------
# One serial baseline (above), then one parallel run per concurrency level.
LEVEL_NOUN=$([ "$PMODE" = "local" ] && echo "workers" || echo "jobs")
declare -a L_LVL L_TIME L_SPEEDUP L_MATCH L_N
WORST_RC=0
for lvl in "${LEVELS[@]}"; do
    PAR="$OUT/merge_par_${lvl}.vcf.gz"
    rm -f "$PAR"
    drop_cache
    printf '    %-14s' "@${lvl} $LEVEL_NOUN"
    t0=$(now)
    $PBCF merge -l "$SUBLIST" -r "$REGION" $FS -Oz -o "$PAR" $(backend_for "$lvl") \
        > "$OUT/par_${lvl}.log" 2>&1
    rc_par=$?
    t1=$(now)
    PAR_T=$(perl -e "printf '%.1f', $t1-$t0")

    if [ $rc_par -ne 0 ] || [ ! -s "$PAR" ]; then
        printf '\033[31mFAIL\033[0m  (exit %s; see %s)\n' "$rc_par" "$OUT/par_${lvl}.log"
        tail -3 "$OUT/par_${lvl}.log" | sed 's/^/        /' 
        L_LVL+=("$lvl"); L_TIME+=("$PAR_T"); L_SPEEDUP+=("-"); L_N+=("0")
        L_MATCH+=("FAIL (exit $rc_par)"); WORST_RC=1
        continue
    fi

    PAR_N=$(bcftools view -H "$PAR" 2>/dev/null | wc -l | tr -d ' ')
    # Fail-closed: BOTH sides must contain records before a match is accepted
    # (two empty record-body streams are byte-equal and would otherwise "PASS").
    if [ "${SER_N:-0}" -le 0 ] || [ "${PAR_N:-0}" -le 0 ]; then
        m="FAIL (empty: serial=$SER_N parallel=$PAR_N)"; WORST_RC=1
    elif diff -q <(bcftools view -H "$SER" 2>/dev/null) <(bcftools view -H "$PAR" 2>/dev/null) >/dev/null 2>&1; then
        m="PASS (records identical)"
    elif [ "$PAR_N" = "$SER_N" ]; then
        m="PARTIAL (count matches: $PAR_N; bodies differ)"; WORST_RC=1
    else
        m="FAIL (serial=$SER_N parallel=$PAR_N)"; WORST_RC=1
    fi
    sp=$(perl -e "printf '%.2f', ($PAR_T>0)?$SER_T/$PAR_T:0")
    case "$m" in
        PASS*)    printf '%9ss   speedup %6sx   \033[32mPASS\033[0m   %s records\n' \
                      "$PAR_T" "$sp" "$PAR_N" ;;
        PARTIAL*) printf '%9ss   speedup %6sx   \033[33m%s\033[0m\n' "$PAR_T" "$sp" "$m" ;;
        *)        printf '%9ss   speedup %6sx   \033[31m%s\033[0m\n' "$PAR_T" "$sp" "$m" ;;
    esac
    L_LVL+=("$lvl"); L_TIME+=("$PAR_T"); L_SPEEDUP+=("$sp"); L_N+=("$PAR_N"); L_MATCH+=("$m")
    [ "$KEEP" = 1 ] || rm -f "$PAR"
done

echo
echo "-------------------------------------------"
if [ "$WORST_RC" = 0 ]; then
    printf 'merge [%s]: %d level(s) passed, records identical to serial (%s)\n' \
        "$LABEL" "${#L_LVL[@]}" "$SER_N"
else
    printf 'merge [%s]: at least one level did NOT match serial — see above\n' "$LABEL"
fi

#--- Report ---------------------------------------------------------------
# Report goes to a PERSISTENT location (next to the other scripts' reports), NOT
# inside $OUT — which is a temp dir removed at the end when no --out was given, so
# a report written there would vanish immediately (it only survived on macOS,
# where the default TMPDIR is not auto-purged the same way).
LEVEL_LABEL=$([ "$PMODE" = "local" ] && echo "workers" || echo "concurrent jobs")
REPORT="$SCRIPT_DIR/merge_report_${LABEL}.md"
{
  echo "# pbcftools merge test — $LABEL"
  echo
  echo "| field | value |"
  echo "|---|---|"
  echo "| label | $LABEL |"
  echo "| date (UTC) | $(date -u '+%Y-%m-%d %H:%M' 2>/dev/null || date) |"
  echo "| host | $(hostname 2>/dev/null) |"
  echo "| bcftools | $(bcftools --version | head -1) |"
  echo "| backend | $PMODE |"
  echo "| levels | ${LEVELS[*]} |"
  echo "| files | $NFILES |"
  echo "| region | $REGION |"
  echo "| chunk (--p_len) | $PLEN |"
  [ "$PMODE" != "local" ] && echo "| per-job resources | ${PWAL}/${PMEM}, ${PCPU:-1} CPU(s) |"
  echo "| serial (s) | $SER_T |"
  echo "| serial records | $SER_N |"
  echo "| page cache | $CACHE_STATE |"
  echo
  echo "| ${LEVEL_LABEL} | parallel (s) | speedup | records | match |"
  echo "|---|---:|---:|---:|---|"
  for i in "${!L_LVL[@]}"; do
    echo "| ${L_LVL[$i]} | ${L_TIME[$i]} | ${L_SPEEDUP[$i]}x | ${L_N[$i]} | ${L_MATCH[$i]} |"
  done
  echo
  echo "Note: with a warm cache the serial run pre-loads the region, so the"
  echo "parallel speedup can be optimistic. Use --drop-caches 1 (needs sudo or"
  echo "vmtouch) for cold-cache numbers. Inputs should be on local disk, not a"
  echo "network/sshfs mount, for meaningful I/O timing."
  if [ "$PMODE" != "local" ]; then
    echo
    echo "Cluster timings include scheduler queue latency and are site-dependent."
    echo "Each job requests 1 CPU, but a scheduler may charge more cores to satisfy"
    echo "--p_mem (cores = max(--p_cpu, ceil(--p_mem / mem-per-core)))."
  fi
} > "$REPORT"
echo "  report   : $REPORT"
[ "$KEEP" = 1 ] && echo "  outputs  : $OUT"

if [ "$KEEP" = 0 ]; then rm -rf "$OUT"; fi
exit $WORST_RC
