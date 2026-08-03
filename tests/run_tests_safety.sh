#!/usr/bin/env bash
#
# run_tests_safety.sh — fast, self-contained regression tests for pbcftools.
#
# Unlike run_tests.sh (which benchmarks against large 1000G files), this suite
# builds tiny synthetic VCFs in a temp dir and exercises the specific behaviors
# fixed during code review. It has no external data dependency and runs in
# seconds, so it is safe to run on any platform (Linux, macOS, WSL2).
#
# Requires: bcftools, bgzip (htslib), perl. Exits non-zero if any test fails.
#
# Usage:  bash tests/run_tests_safety.sh [platform_label]
#
#   platform_label (optional) tags the report, e.g. "macos", "wsl2", "lsf".
#   Defaults to `uname -s`. A machine-readable report is written to
#   tests/regression_report_<label>.md  — send that file back for a
#   cross-platform summary.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PBCF="$SCRIPT_DIR/../bin/pbcftools.pl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pbcf_regress.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Args: a platform label (positional, or --label NAME as in the other scripts) and
# an optional --bench flag.
BENCH=0; LABEL=""; LABEL_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bench)  BENCH=1; shift ;;
    --label)  LABEL="$2"; LABEL_GIVEN=1; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    -*)       echo "Unknown option: $1" >&2; exit 2 ;;
    *)        [ -z "$LABEL" ] && { LABEL="$1"; LABEL_GIVEN=1; }; shift ;;
  esac
done
# The report is named after the label. Defaulting to `uname -s` is a poor fallback
# for a cross-platform round: zlab2, WSL2, an LSF login node and an Anvil login node
# are ALL "Linux", so four testers who omit the label produce four files with the
# same name and overwrite one another when collected. Say so rather than silently
# producing a colliding filename.
LABEL="${LABEL:-$(uname -s)}"
if [ "$LABEL_GIVEN" = 0 ]; then
    echo "NOTE: no label given, so this report will be written as"
    echo "      regression_report_${LABEL}.md — the same name every ${LABEL} host"
    echo "      produces. Pass a host label to keep results distinguishable:"
    echo "          bash tests/run_tests_safety.sh <host>"
    echo
fi
REPORT="$SCRIPT_DIR/regression_report_${LABEL}.md"

# --- portable platform / hardware detection (Linux, macOS/BSD, WSL2) ---
first_nonempty() { local v; for v in "$@"; do v="$(printf '%s' "$v" | xargs 2>/dev/null)"; [ -n "$v" ] && { printf '%s' "$v"; return; }; done; printf '?'; }

NCPU="$(first_nonempty "$(nproc 2>/dev/null)" "$(sysctl -n hw.ncpu 2>/dev/null)")"
CPU_MODEL="$(first_nonempty \
  "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" \
  "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)" \
  "$(lscpu 2>/dev/null | awk -F': +' '/Model name/{print $2; exit}')")"
MEM_GB="$(first_nonempty \
  "$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null)" \
  "$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}')")"
OS_DETAIL="$(first_nonempty \
  "$( (sw_vers -productName; sw_vers -productVersion) 2>/dev/null | paste -sd' ' - )" \
  "$( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}" )" \
  "$(uname -sr)")"
IS_WSL="$( (grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null && echo yes) || echo no )"

# Portable md5 of stdin. macOS ships `md5`, not `md5sum`; rather than branch, use
# Perl's core Digest::MD5 (perl is a hard dependency here — it runs pbcftools), so
# this returns the same bare hex digest on Linux, macOS, and BSD.
# hash every file in a tree, so a CONTENT change is visible and not just a count
_md5sum_list() { for f in "$@"; do printf '%s:%s\n' "$f" "$(_md5 < "$f" 2>/dev/null)"; done; }

_md5() { perl -MDigest::MD5 -e 'print Digest::MD5->new->addfile(*STDIN)->hexdigest, "\n"'; }

PASS=0; FAIL=0; SKIP=0
RESULTS=()   # "PASS|desc" or "FAIL|desc -- reason" or "SKIP|desc"
ok()   { PASS=$((PASS+1)); RESULTS+=("PASS|$1"); printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1 -- $2"); printf "  \033[31mFAIL\033[0m  %s  -- %s\n" "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); RESULTS+=("SKIP|$1"); printf "  \033[33mSKIP\033[0m  %s\n" "$1"; }

for tool in bcftools bgzip perl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: '$tool' not found in PATH"; exit 2; }
done

# Functional preflight: the tools must actually RUN, not just exist. On some
# HPC modules bgzip/bcftools are present but fail at load time (e.g. a missing
# libcrypto.so.10), which would otherwise produce empty fixtures and a
# meaningless run. Fail loudly and early instead.
if ! bgzip --version >/dev/null 2>&1; then
    echo "ERROR: 'bgzip' is installed but fails to run (see error above -- often a"
    echo "       missing shared library like libcrypto.so.10). Fix your htslib/"
    echo "       bcftools install; a self-contained bioconda build is the easiest fix:"
    echo "         conda install -c bioconda -c conda-forge bcftools htslib"
    exit 2
fi
if ! bcftools --version >/dev/null 2>&1; then
    echo "ERROR: 'bcftools' is installed but fails to run (missing shared library?)."
    echo "       Use a self-contained build: conda install -c bioconda bcftools"
    exit 2
fi
# pbcftools needs --regions-overlap (bcftools >= 1.15) — the keystone that keeps
# boundary variants from duplicating across chunks.
if ! bcftools view --help 2>&1 | grep -q -- '--regions-overlap'; then
    echo "ERROR: your bcftools ($(bcftools --version 2>/dev/null | awk 'NR==1{print $2}')) lacks"
    echo "       '--regions-overlap' (added in bcftools 1.15). pbcftools requires >= 1.15."
    echo "       Install a newer bcftools: conda install -c bioconda 'bcftools>=1.15'"
    exit 2
fi
# Capability: the SHORT -W spelling of --write-index was added in bcftools 1.20.
# The project only requires >= 1.15 (and CI pins 1.19), so tests that exercise the
# short -W optional-attached form must skip below 1.20 rather than fail.  Detect
# the actual spelling from help instead of parsing a version number.
HAS_SHORT_W=0
if bcftools merge --help 2>&1 | grep -qE '^[[:space:]]*-W,'; then HAS_SHORT_W=1; fi

# Functional preflight for pbcftools ITSELF. Without this, any startup problem
# (a missing module, an unreadable lib/, an incompatible perl) shows up as ~100
# cryptic per-test failures — every parallel test failing while T4, which EXPECTS
# a failure, passes trivially. Diagnose it once, here, with an actionable message.
if ! perl -c "$PBCF" >/dev/null 2>&1; then
    echo "ERROR: pbcftools does not compile:"
    perl -c "$PBCF" 2>&1 | sed 's/^/       /' | head -5
    echo "       Is lib/PBCFTools/ present next to bin/ (FindBin resolves it relative"
    echo "       to the script, and does not follow a symlinked bin/pbcftools.pl)?"
    exit 2
fi
# Parallel::ForkManager is loaded LAZILY by the Local backend, so a missing copy
# does not break --help or `perl -c`; it breaks every parallel run instead.
if ! perl -MParallel::ForkManager -e1 >/dev/null 2>&1; then
    echo "ERROR: Perl module 'Parallel::ForkManager' is not installed. pbcftools needs"
    echo "       it for local (multi-core) execution, and every parallel test would"
    echo "       fail without it. Install one of:"
    echo "         sudo dnf install perl-Parallel-ForkManager      # Fedora/RHEL"
    echo "         sudo apt install libparallel-forkmanager-perl   # Debian/Ubuntu/WSL2"
    echo "         cpan Parallel::ForkManager                      # any platform"
    echo "         conda install -c conda-forge perl-parallel-forkmanager"
    exit 2
fi

echo "pbcftools regression suite"
echo "  pbcftools: $PBCF"
echo "  bcftools:  $(bcftools --version | head -1)"
echo "  workdir:   $WORK"
echo

#-----------------------------------------------------------------------------
# Build synthetic inputs
#-----------------------------------------------------------------------------
# (1) Two-contig, two-sample VCF with proper contig headers
{
  echo '##fileformat=VCFv4.2'
  echo '##contig=<ID=1,length=2000000>'
  echo '##contig=<ID=2,length=1000000>'
  echo '##INFO=<ID=AF,Number=A,Type=Float,Description="af">'
  echo '##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2\n'
  for p in $(seq 1 1500); do printf '1\t%d\t.\tA\tG\t100\tPASS\tAF=0.1\tGT\t0|1\t1|1\n' $((p*1000)); done
  for p in $(seq 1 800);  do printf '2\t%d\t.\tC\tT\t100\tPASS\tAF=0.2\tGT\t1|1\t0|1\n' $((p*1000)); done
} > "$WORK/main.vcf"
bgzip -f "$WORK/main.vcf" && bcftools index -f "$WORK/main.vcf.gz"
N_TOTAL=$(bcftools view -H "$WORK/main.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')   # expect 2300

# Fixture preflight: if the primary input didn't build (e.g. bgzip/bcftools
# failed at runtime), abort — otherwise every test runs against missing files
# and reports meaningless results.
if [ ! -s "$WORK/main.vcf.gz" ] || [ "$N_TOTAL" != "2300" ]; then
    echo "ERROR: failed to build test fixtures (expected 2300 records, got '${N_TOTAL:-none}')."
    echo "       This is an environment problem, not a pbcftools failure -- check the"
    echo "       bgzip/bcftools errors above. A self-contained bioconda build usually fixes it:"
    echo "         conda install -c bioconda -c conda-forge 'bcftools>=1.15' htslib"
    exit 2
fi

# (2) single-contig VCF (regression: single ##contig must not crash)
{
  echo '##fileformat=VCFv4.2'
  echo '##contig=<ID=1,length=2000000>'
  echo '##INFO=<ID=AF,Number=A,Type=Float,Description="af">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  for p in $(seq 1 500); do printf '1\t%d\t.\tA\tG\t100\tPASS\tAF=0.1\n' $((p*1000)); done
} > "$WORK/single.vcf"
bgzip -f "$WORK/single.vcf" && bcftools index -f "$WORK/single.vcf.gz"

# (3) header-less, non-human contig for --p_fai
{
  echo '##fileformat=VCFv4.2'
  echo '##INFO=<ID=AF,Number=A,Type=Float,Description="af">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  for p in $(seq 1 600); do printf 'scaffold_7\t%d\t.\tA\tG\t100\tPASS\tAF=0.1\n' $((p*1000)); done
} > "$WORK/nohdr.vcf"
bgzip -f "$WORK/nohdr.vcf" && bcftools index -f "$WORK/nohdr.vcf.gz"
printf 'scaffold_7\t1500000\t10\t60\t61\n' > "$WORK/ref.fa.fai"

# (4) per-sample files for merge
bcftools view -s S1 "$WORK/main.vcf.gz" -Oz -o "$WORK/s1.vcf.gz" 2>/dev/null && bcftools index -f "$WORK/s1.vcf.gz"
bcftools view -s S2 "$WORK/main.vcf.gz" -Oz -o "$WORK/s2.vcf.gz" 2>/dev/null && bcftools index -f "$WORK/s2.vcf.gz"

# (5) header-lines file for annotate -h
printf '##INFO=<ID=FOO,Number=1,Type=String,Description="hdr test">\n' > "$WORK/hdr.txt"

# (6) reference fasta matching main.vcf.gz (REF=A on contig 1, C on contig 2),
# for boundary-sensitive `norm -f` (routed to chromosome mode). NB: distinct
# basename from the T9 `ref.fa.fai` fixture — norm auto-builds normref.fa.fai.
{ echo '>1'; perl -e 'print "A" x 2000000, "\n"'; echo '>2'; perl -e 'print "C" x 1000000, "\n"'; } > "$WORK/normref.fa"

# (7) spanning-deletion fixture (contig 1): a deletion at POS 45 spans to 54, plus
# variants across a would-be chunk boundary — for user -r overlap/sub-split tests.
{ echo '##fileformat=VCFv4.2'; echo '##contig=<ID=1,length=1000>'
  echo '##INFO=<ID=AF,Number=A,Type=Float,Description="af">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  printf '1\t45\t.\tACGTGACGTG\tA\t100\tPASS\tAF=0.2\n'   # deletion 45-54 (spans into 50-)
  for p in 55 60 70 80 90 98 105 150 200 300; do printf '1\t%d\t.\tAC\tA\t100\tPASS\tAF=0.1\n' $p; done
} > "$WORK/span.vcf"
(grep '^#' "$WORK/span.vcf"; grep -v '^#' "$WORK/span.vcf" | sort -k1,1 -k2,2n) | bgzip > "$WORK/span.vcf.gz"
bcftools index -f "$WORK/span.vcf.gz"

# (7b) long deletion (1:45 spanning to 1:64) for adjacent-interval / single-pos tests.
{ echo '##fileformat=VCFv4.2'; echo '##contig=<ID=1,length=1000>'
  echo '##INFO=<ID=AF,Number=A,Type=Float,Description="af">'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  printf '1\t45\t.\t%s\tA\t100\tPASS\tAF=0.2\n' "$(perl -e 'print "A"x20')"   # 45-64 deletion
  for p in 50 60 61 100 101 150 200 300; do printf '1\t%d\t.\tC\tT\t100\tPASS\tAF=0.1\n' $p; done
} > "$WORK/spanlong.vcf"
(grep '^#' "$WORK/spanlong.vcf"; grep -v '^#' "$WORK/spanlong.vcf" | sort -k1,1 -k2,2n) | bgzip > "$WORK/spanlong.vcf.gz"
bcftools index -f "$WORK/spanlong.vcf.gz"

# (7c) two files, same contig name but DIFFERENT lengths (later record beyond first bound).
printf '##fileformat=VCFv4.2\n##contig=<ID=1,length=100>\n##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tLA\n1\t10\t.\tA\tG\t.\tPASS\t.\tGT\t0/1\n' > "$WORK/len_a.vcf"
printf '##fileformat=VCFv4.2\n##contig=<ID=1,length=1000>\n##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tLB\n1\t500\t.\tA\tG\t.\tPASS\t.\tGT\t0/1\n' > "$WORK/len_b.vcf"
for x in len_a len_b; do bgzip -f "$WORK/$x.vcf"; bcftools index -f "$WORK/$x.vcf.gz"; done

# (7d) file with an UNKNOWN contig length (no ##contig length -> index -s '.'),
# record at 500 (beyond main.vcf.gz? no — beyond a short first file), + a FAI that
# supplies the bound. For the --p_fai unknown-length test.
printf '##fileformat=VCFv4.2\n##contig=<ID=1,length=100>\n##FORMAT=<ID=GT,Number=1,Type=String,Description=gt>\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tUA\n1\t10\t.\tA\tG\t.\tPASS\t.\tGT\t0/1\n' > "$WORK/unk_a.vcf"
printf '##fileformat=VCFv4.2\n##contig=<ID=1>\n##FORMAT=<ID=GT,Number=1,Type=String,Description=gt>\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tUB\n1\t500\t.\tA\tG\t.\tPASS\t.\tGT\t0/1\n' > "$WORK/unk_b.vcf"
for x in unk_a unk_b; do bgzip -f "$WORK/$x.vcf"; bcftools index -f "$WORK/$x.vcf.gz"; done
printf '1\t1000\t3\t60\t61\n' > "$WORK/unk_ref.fa.fai"
# a fasta whose basename contains 'l' (for the csq attached-value test)
printf '>1\nACGTACGT\n' > "$WORK/local.fa"

# (8) two mini files with DIFFERENT contigs, for the multi-input contig-mismatch test.
printf '##fileformat=VCFv4.2\n##contig=<ID=1,length=1000>\n##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tA\n1\t10\t.\tA\tG\t.\tPASS\t.\tGT\t0/1\n' > "$WORK/mc_a.vcf"
printf '##fileformat=VCFv4.2\n##contig=<ID=2,length=1000>\n##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tB\n2\t20\t.\tT\tC\t.\tPASS\t.\tGT\t0/1\n' > "$WORK/mc_b.vcf"
for x in mc_a mc_b; do bgzip -f "$WORK/$x.vcf"; bcftools index -f "$WORK/$x.vcf.gz"; done

run() { perl "$PBCF" "$@" 2>"$WORK/err.log"; }   # returns bcftools/pbcftools exit code

# Same, but capturing BOTH streams, because pbcftools' routing notices go to stdout.
run_cap() { perl "$PBCF" "$@" >"$WORK/cap.log" 2>&1; }

# Did the last run_cap actually PARALLELIZE, or did it fall back to a single direct
# bcftools call? Several checks compare parallel output against serial; if the
# "parallel" side quietly ran serially, the comparison is vacuous and passes no
# matter what the parallel path does. pbcftools announces the split explicitly.
_ran_parallel() { grep -qE 'Split into [0-9]+ jobs' "$WORK/cap.log"; }

#-----------------------------------------------------------------------------
# Tests
#-----------------------------------------------------------------------------

# T1 region: query text over two contigs, all records present, ordered
run query -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t1.txt" --p_jobs 4 --p_len 400KB --p_yes
n=$(wc -l < "$WORK/t1.txt" | tr -d ' ')
[ "$n" = "$N_TOTAL" ] && ok "T1 region query ($n lines)" || bad "T1 region query" "got $n want $N_TOTAL"

# T2 (C3) annotate -h header.txt input  -> single-input, not misread as multi-input
run annotate -h "$WORK/hdr.txt" "$WORK/main.vcf.gz" -Oz -o "$WORK/t2.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes
n=$(bcftools view -H "$WORK/t2.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
grep -q "multi-input mode" "$WORK/err.log" && misread=1 || misread=0
{ [ "$n" = "$N_TOTAL" ] && [ "$misread" = 0 ]; } && ok "T2 annotate -h single-input ($n rec)" || bad "T2 annotate -h" "rec=$n misread=$misread"

# T3 (multi-input) merge two per-sample files -> S1,S2 samples, records preserved
run merge "$WORK/s1.vcf.gz" "$WORK/s2.vcf.gz" -Oz -o "$WORK/t3.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes
smp=$(bcftools query -l "$WORK/t3.vcf.gz" 2>/dev/null | tr '\n' ',' )
n=$(bcftools view -H "$WORK/t3.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
{ [ "$smp" = "S1,S2," ] && [ "$n" = "$N_TOTAL" ]; } && ok "T3 merge multi-input ($smp $n rec)" || bad "T3 merge" "samples=$smp rec=$n"

# T4 (C2) fail-closed: bad INFO tag fails every chunk -> non-zero exit, NO output
rm -f "$WORK/t4.vcf.gz"
run view -i 'INFO/NOSUCH>0' "$WORK/main.vcf.gz" -Oz -o "$WORK/t4.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes
rc=$?
{ [ "$rc" != 0 ] && [ ! -e "$WORK/t4.vcf.gz" ]; } && ok "T4 fail-closed (exit $rc, no output)" || bad "T4 fail-closed" "exit=$rc output_exists=$([ -e "$WORK/t4.vcf.gz" ] && echo yes || echo no)"

# T5 (G1) -Ob with a NON-.bcf extension -> real BCF, not text-corrupted
run view "$WORK/main.vcf.gz" -Ob -o "$WORK/t5out" --p_jobs 4 --p_len 400KB --p_yes
n=$(bcftools view -H "$WORK/t5out" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "$N_TOTAL" ] && ok "T5 -Ob non-standard ext -> valid BCF ($n rec)" || bad "T5 -Ob inference" "readable rec=$n want $N_TOTAL"

# T6 single-contig VCF must not crash (bonus fix)
run query -f '%POS\n' "$WORK/single.vcf.gz" -o "$WORK/t6.txt" --p_jobs 2 --p_len 400KB --p_yes
rc=$?
n=$(wc -l < "$WORK/t6.txt" 2>/dev/null | tr -d ' ')
{ [ "$rc" = 0 ] && [ "$n" = 500 ]; } && ok "T6 single-contig no crash ($n)" || bad "T6 single-contig" "exit=$rc lines=$n"

# T7 (R1) `query -l` must succeed and list the samples (whole-file, unparallelized).
# Assert rc=0, not misread as a file list, AND exact sample output — the earlier
# version only checked "not a file list", so a broken query -l passed silently.
rm -f "$WORK/t7.txt"
run query -l "$WORK/main.vcf.gz" -o "$WORK/t7.txt" --p_jobs 2 --p_len 400KB --p_yes
rc=$?
grep -q "Input file list:" "$WORK/err.log" && aslist=1 || aslist=0   # would appear only if misread
smp=$(tr '\n' ',' < "$WORK/t7.txt" 2>/dev/null)
{ [ "$rc" = 0 ] && [ "$aslist" = 0 ] && [ "$smp" = "S1,S2," ]; } \
  && ok "T7 query -l lists samples ($smp)" || bad "T7 query -l" "exit=$rc aslist=$aslist samples=$smp"

# T8 (R2 local) nested double-quotes in a filter expression survive locally
run view -i 'TYPE="snp"' "$WORK/main.vcf.gz" -Oz -o "$WORK/t8.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes
n=$(bcftools view -H "$WORK/t8.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "$N_TOTAL" ] && ok "T8 nested-quote filter ($n snps)" || bad "T8 nested-quote filter" "rec=$n want $N_TOTAL"

# T9 (--p_fai) header-less non-human contig resolved from a .fai
run query -f '%CHROM\t%POS\n' "$WORK/nohdr.vcf.gz" -o "$WORK/t9.txt" --p_jobs 2 --p_len 400KB --p_fai "$WORK/ref.fa.fai" --p_yes
rc=$?
n=$(wc -l < "$WORK/t9.txt" 2>/dev/null | tr -d ' ')
{ [ "$rc" = 0 ] && [ "$n" = 600 ]; } && ok "T9 --p_fai non-human contig ($n)" || bad "T9 --p_fai" "exit=$rc lines=$n"

# T10 unknown command must fail closed (refuse)
run frobnicate "$WORK/main.vcf.gz" -o "$WORK/t10.out" --p_yes
rc=$?
grep -q "not recognized" "$WORK/err.log" && refused=1 || refused=0
{ [ "$rc" != 0 ] && [ "$refused" = 1 ]; } && ok "T10 unknown command refused (exit $rc)" || bad "T10 unknown command" "exit=$rc refused=$refused"

# T11 (+fill-tags) the ONE whitelisted plugin: parallel output must equal serial,
# byte-for-byte on the record body. Gated on the plugin being runnable here.
if bcftools +fill-tags "$WORK/main.vcf.gz" -- -t AN,AC >/dev/null 2>&1; then
  bcftools +fill-tags "$WORK/main.vcf.gz" -Oz -o "$WORK/t11.ser.vcf.gz" -- -t AN,AC 2>/dev/null
  run_cap +fill-tags "$WORK/main.vcf.gz" -Oz -o "$WORK/t11.par.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes -- -t AN,AC
  rc=$?
  t11par=$(_ran_parallel && echo yes || echo NO)   # informational: see KI-8
  ser=$(bcftools view -H "$WORK/t11.ser.vcf.gz" 2>/dev/null | _md5)
  par=$(bcftools view -H "$WORK/t11.par.vcf.gz" 2>/dev/null | _md5)
  # The equality is only evidence if the run actually split into chunks.
  { [ "$rc" = 0 ] && [ -n "$ser" ] && [ "$ser" = "$par" ]; } \
    && ok "T11 +fill-tags == serial (split=$t11par)" \
    || bad "T11 +fill-tags" "exit=$rc serial=$ser parallel=$par parallelized=$t11par"
else
  skip "T11 +fill-tags (plugin not runnable here)"
fi

# T12 (stats) aggregate: if plot-vcfstats -m is available, EVERY normalized SN
# summary-number row (not just SNPs) must match serial; if NOT available,
# pbcftools must FAIL CLOSED (never emit a wrong concatenated stats file).
# Canonicalize: keep SN rows, drop the leading id column, sort.
canon_sn() { grep '^SN' "$1" | cut -f3- | sort; }
bcftools stats "$WORK/main.vcf.gz" > "$WORK/t12.ser.chk" 2>/dev/null
rm -f "$WORK/t12.par.chk"
run stats "$WORK/main.vcf.gz" -o "$WORK/t12.par.chk" --p_jobs 4 --p_len 400KB --p_yes
rc=$?
if [ "$rc" = 0 ] && [ -s "$WORK/t12.par.chk" ]; then
  # Compare EVERY non-comment data section row (SN, AF, QUAL, ST, SiS, TSTV, …),
  # not just SN. Keep the section label (field 1) so rows from different sections
  # can't be conflated, drop the set-id (field 2, always 0 for one input), keep
  # the data (fields 3+). Exclude the ID set-definition row — it carries the
  # run-specific input path, which differs between serial and parallel temp dirs.
  canon_all() { grep -v '^#' "$1" | awk -F'\t' '$1!="ID"{ o=$1; for(i=3;i<=NF;i++) o=o"\t"$i; print o }' | sort; }
  nrows=$(canon_all "$WORK/t12.ser.chk" | wc -l | tr -d ' ')
  diff -q <(canon_all "$WORK/t12.ser.chk") <(canon_all "$WORK/t12.par.chk") >/dev/null 2>&1 \
    && ok "T12 stats all $nrows sections == serial" || bad "T12 stats sections" "normalized rows differ"
else
  # plot-vcfstats unavailable -> must have failed closed with no wrong output
  [ ! -s "$WORK/t12.par.chk" ] \
    && ok "T12 stats fail-closed (no plot-vcfstats, exit $rc, no output)" \
    || bad "T12 stats fail-closed" "exit=$rc but a stats file was written"
fi

# T13 (head passthrough) `head` is stdout-only (rejects -o): pbcftools must
# redirect to -o, not break. Assert output has the expected header lines.
rm -f "$WORK/t13.txt"
run head "$WORK/main.vcf.gz" -o "$WORK/t13.txt" --p_yes
rc=$?
grep -q '^##fileformat=VCF' "$WORK/t13.txt" 2>/dev/null && hashdr=1 || hashdr=0
{ [ "$rc" = 0 ] && [ "$hashdr" = 1 ]; } && ok "T13 head passthrough -> -o file" || bad "T13 head passthrough" "exit=$rc hashdr=$hashdr"

# T14 (plugin NAME syntax) `plugin fill-tags` must be equivalent to `+fill-tags`
# (normalized to the + form and region-parallelized). Gated on the plugin.
if bcftools +fill-tags "$WORK/main.vcf.gz" -- -t AN,AC >/dev/null 2>&1; then
  bcftools +fill-tags "$WORK/main.vcf.gz" -Oz -o "$WORK/t14.ser.vcf.gz" -- -t AN,AC 2>/dev/null
  run_cap plugin fill-tags "$WORK/main.vcf.gz" -Oz -o "$WORK/t14.par.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes -- -t AN,AC
  rc=$?
  t14par=$(_ran_parallel && echo yes || echo NO)   # informational: see KI-8
  ser=$(bcftools view -H "$WORK/t14.ser.vcf.gz" 2>/dev/null | _md5)
  par=$(bcftools view -H "$WORK/t14.par.vcf.gz" 2>/dev/null | _md5)
  { [ "$rc" = 0 ] && [ -n "$ser" ] && [ "$ser" = "$par" ]; } \
    && ok "T14 'plugin NAME' == '+NAME' (split=$t14par)" \
    || bad "T14 plugin NAME syntax" "exit=$rc serial=$ser parallel=$par parallelized=$t14par"
else
  skip "T14 plugin NAME syntax (plugin not runnable here)"
fi

# T15 (informational passthrough) `plugin -l` must list plugins and exit 0
# without requiring input/output files. `+NAME -h` likewise prints usage.
run plugin -l >"$WORK/t15.out" 2>&1
rc=$?
grep -qi 'fill-tags' "$WORK/t15.out" && listed=1 || listed=0
{ [ "$rc" = 0 ] && [ "$listed" = 1 ]; } && ok "T15 'plugin -l' informational passthrough" || bad "T15 plugin -l" "exit=$rc listed=$listed"

# T16 (indexed-input gate) an UNINDEXED input is not region-seekable -> pbcftools
# must pass through to plain bcftools (behave as a drop-in), not error, and emit
# correct output. `main.vcf.gz` is indexed; a bare copy has no .csi/.tbi.
cp "$WORK/main.vcf.gz" "$WORK/t16.noidx.vcf.gz"
rm -f "$WORK/t16.noidx.vcf.gz.csi" "$WORK/t16.noidx.vcf.gz.tbi" "$WORK/t16.out.vcf.gz"
perl "$PBCF" view "$WORK/t16.noidx.vcf.gz" -Oz -o "$WORK/t16.out.vcf.gz" --p_jobs 4 --p_yes >"$WORK/t16.log" 2>&1
rc=$?
n=$(bcftools view -H "$WORK/t16.out.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
grep -qi 'running bcftools directly' "$WORK/t16.log" && passthru=1 || passthru=0
{ [ "$rc" = 0 ] && [ "$n" = "$N_TOTAL" ] && [ "$passthru" = 1 ]; } \
  && ok "T16 unindexed input -> passthrough ($n rec)" || bad "T16 indexed-input gate" "exit=$rc rec=$n passthru=$passthru"

# T17 (mode-aware routing) `norm -f` is boundary-sensitive (left-align can move
# records across a boundary) -> must run in CHROMOSOME mode, and its output must
# equal serial. `norm -m` (safe) must STAY region (negative control).
bcftools norm -f "$WORK/normref.fa" "$WORK/main.vcf.gz" -Oz -o "$WORK/t17.ser.vcf.gz" 2>/dev/null
perl "$PBCF" norm -f "$WORK/normref.fa" "$WORK/main.vcf.gz" -Oz -o "$WORK/t17.par.vcf.gz" \
     --p_jobs 4 --p_len 400KB --p_yes >"$WORK/t17.log" 2>&1
rc=$?
grep -qi 'per whole chromosome' "$WORK/t17.log" && routed=1 || routed=0
sm=$(bcftools view -H "$WORK/t17.ser.vcf.gz" 2>/dev/null | _md5)
pm=$(bcftools view -H "$WORK/t17.par.vcf.gz" 2>/dev/null | _md5)
# negative control: norm -m must NOT be upgraded to chromosome
perl "$PBCF" norm -m -both "$WORK/main.vcf.gz" -Oz -o "$WORK/t17.m.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes >"$WORK/t17m.log" 2>&1
grep -qi 'per whole chromosome' "$WORK/t17m.log" && m_upgraded=1 || m_upgraded=0
{ [ "$rc" = 0 ] && [ "$routed" = 1 ] && [ -n "$sm" ] && [ "$sm" = "$pm" ] && [ "$m_upgraded" = 0 ]; } \
  && ok "T17 norm -f -> chromosome == serial (norm -m stays region)" \
  || bad "T17 norm -f routing" "exit=$rc routed=$routed m_upgraded=$m_upgraded serial=$sm parallel=$pm"

# T18 (mode-aware routing) `filter -g` (SnpGap, neighbor-dependent) -> chromosome
# mode, output must equal serial.
bcftools filter -g5 -e 'QUAL<0' "$WORK/main.vcf.gz" -Oz -o "$WORK/t18.ser.vcf.gz" 2>/dev/null
perl "$PBCF" filter -g5 -e 'QUAL<0' "$WORK/main.vcf.gz" -Oz -o "$WORK/t18.par.vcf.gz" \
     --p_jobs 4 --p_len 400KB --p_yes >"$WORK/t18.log" 2>&1
rc=$?
grep -qi 'per whole chromosome' "$WORK/t18.log" && routed=1 || routed=0
sm=$(bcftools view -H "$WORK/t18.ser.vcf.gz" 2>/dev/null | _md5)
pm=$(bcftools view -H "$WORK/t18.par.vcf.gz" 2>/dev/null | _md5)
{ [ "$rc" = 0 ] && [ "$routed" = 1 ] && [ -n "$sm" ] && [ "$sm" = "$pm" ]; } \
  && ok "T18 filter -g -> chromosome == serial" || bad "T18 filter -g routing" "exit=$rc routed=$routed serial=$sm parallel=$pm"

# T19 (query data loss) a -f format producing '#'-prefixed rows must NOT be
# mistaken for headers — every data row must survive the parallel text merge.
bcftools query -f '#%CHROM\t%POS\n' "$WORK/main.vcf.gz" > "$WORK/t19.ser.txt" 2>/dev/null
run query -f '#%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t19.par.txt" --p_jobs 4 --p_len 400KB --p_yes
rc=$?
sn=$(wc -l < "$WORK/t19.ser.txt" 2>/dev/null | tr -d ' '); pn=$(wc -l < "$WORK/t19.par.txt" 2>/dev/null | tr -d ' ')
{ [ "$rc" = 0 ] && [ -n "$sn" ] && [ "$sn" = "$pn" ] && diff -q "$WORK/t19.ser.txt" "$WORK/t19.par.txt" >/dev/null 2>&1; } \
  && ok "T19 query '#'-format no data loss ($pn rows)" || bad "T19 query # data loss" "serial=$sn parallel=$pn exit=$rc"

# T20 (stats gating) `stats -s` (per-sample) is not exactly mergeable by
# plot-vcfstats -m -> must pass through to bcftools and still produce output.
perl "$PBCF" stats -s - "$WORK/main.vcf.gz" -o "$WORK/t20.txt" --p_jobs 4 --p_yes >"$WORK/t20.log" 2>&1
rc=$?
grep -qi 'not exactly' "$WORK/t20.log" && gated=1 || gated=0
sncount=$(grep -c '^SN' "$WORK/t20.txt" 2>/dev/null || echo 0)
{ [ "$rc" = 0 ] && [ "$gated" = 1 ] && [ "$sncount" -gt 0 ]; } \
  && ok "T20 stats -s -> passthrough" || bad "T20 stats -s gating" "exit=$rc gated=$gated SN=$sncount"

# T21 (user -r, region-safe) a user region must SUB-SPLIT for parallelism yet stay
# serial-identical, including a record that starts before the region and spans in,
# and one spanning an internal chunk boundary (first chunk default overlap, rest pos).
bcftools view -H -r 1:50-400 "$WORK/span.vcf.gz" > "$WORK/t21.ser.txt" 2>/dev/null
perl "$PBCF" view -r 1:50-400 "$WORK/span.vcf.gz" -Oz -o "$WORK/t21.par.vcf.gz" --p_jobs 4 --p_len 100 --p_yes >/dev/null 2>&1
rc=$?
bcftools view -H "$WORK/t21.par.vcf.gz" 2>/dev/null > "$WORK/t21.par.txt"
{ [ "$rc" = 0 ] && diff -q "$WORK/t21.ser.txt" "$WORK/t21.par.txt" >/dev/null 2>&1; } \
  && ok "T21 user -r sub-split == serial ($(wc -l <"$WORK/t21.par.txt" | tr -d ' ') rec, spanning ok)" \
  || bad "T21 user -r sub-split" "exit=$rc serial=$(wc -l <"$WORK/t21.ser.txt") parallel=$(wc -l <"$WORK/t21.par.txt")"

# T22 (multi-input contig mismatch) merging files with disjoint contigs would omit
# data -> must FAIL CLOSED (non-zero, no output), not silently drop records.
rm -f "$WORK/t22.vcf.gz"
perl "$PBCF" merge "$WORK/mc_a.vcf.gz" "$WORK/mc_b.vcf.gz" -Oz -o "$WORK/t22.vcf.gz" --p_yes >"$WORK/t22.log" 2>&1
rc=$?
grep -qi 'contig mismatch' "$WORK/t22.log" && caught=1 || caught=0
{ [ "$rc" != 0 ] && [ "$caught" = 1 ] && [ ! -e "$WORK/t22.vcf.gz" ]; } \
  && ok "T22 multi-input contig mismatch -> fail-closed" || bad "T22 contig mismatch" "exit=$rc caught=$caught output=$([ -e "$WORK/t22.vcf.gz" ] && echo yes || echo no)"

# T23 (query -H multiline) a multi-line -H format emits N header lines (N = \n in
# format); the parallel merge must not duplicate the later header lines.
bcftools query -H -f '%CHROM\n%POS\n' "$WORK/main.vcf.gz" > "$WORK/t23.ser.txt" 2>/dev/null
run query -H -f '%CHROM\n%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t23.par.txt" --p_jobs 4 --p_len 400KB --p_yes
rc=$?
{ [ "$rc" = 0 ] && diff -q "$WORK/t23.ser.txt" "$WORK/t23.par.txt" >/dev/null 2>&1; } \
  && ok "T23 query -H multiline no dup headers" || bad "T23 query -H multiline" "exit=$rc serial=$(wc -l <"$WORK/t23.ser.txt") parallel=$(wc -l <"$WORK/t23.par.txt")"

# T24 (option abbreviation) bcftools accepts `--SnpG=5` as `--SnpGap` — the safety
# classifier must catch the abbreviation and route filter to chromosome mode.
run filter --SnpG=5 -e 'QUAL<0' "$WORK/main.vcf.gz" -Oz -o "$WORK/t24.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes >"$WORK/t24.log" 2>&1
perl "$PBCF" filter --SnpG=5 -e 'QUAL<0' "$WORK/main.vcf.gz" -Oz -o "$WORK/t24.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes >"$WORK/t24.log" 2>&1
grep -qi 'per whole chromosome' "$WORK/t24.log" && routed=1 || routed=0
[ "$routed" = 1 ] && ok "T24 abbreviated --SnpG -> chromosome" || bad "T24 abbreviation" "not routed to chromosome"

# T25 (view -H passthrough) headerless output can't be VCF-concatenated -> passthrough.
perl "$PBCF" view -H "$WORK/main.vcf.gz" -o "$WORK/t25.txt" --p_yes >"$WORK/t25.log" 2>&1
rc=$?
n=$(grep -vc '^#' "$WORK/t25.txt" 2>/dev/null || echo 0)
grep -qi 'running bcftools directly' "$WORK/t25.log" && pt=1 || pt=0
{ [ "$rc" = 0 ] && [ "$pt" = 1 ] && [ "$n" = "$N_TOTAL" ]; } \
  && ok "T25 view -H -> passthrough ($n rec)" || bad "T25 view -H passthrough" "exit=$rc passthru=$pt rec=$n"

# T26 (regions-overlap default = record) -r's default includes a record that
# starts before the region and spans in (the 45-54 deletion for region 50-60).
# pbcftools must reproduce that (first-chunk default overlap).
sr=$(bcftools view -H -r 1:50-60 "$WORK/span.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run view -r 1:50-60 "$WORK/span.vcf.gz" -Oz -o "$WORK/t26.vcf.gz" --p_jobs 2 --p_len 5 --p_yes
pr=$(bcftools view -H "$WORK/t26.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ] && echo "$pr" | grep -q '^45,'; } \
  && ok "T26 -r default record overlap (spanning incl: $pr)" || bad "T26 regions-overlap record" "serial=$sr parallel=$pr"

# T27 (regions-overlap pos respected) an explicit --regions-overlap pos must be
# honored: the 45-spanning deletion is EXCLUDED (POS 45 is outside 50-60).
sr=$(bcftools view -H -r 1:50-60 --regions-overlap pos "$WORK/span.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run view -r 1:50-60 --regions-overlap pos "$WORK/span.vcf.gz" -Oz -o "$WORK/t27.vcf.gz" --p_jobs 2 --p_len 5 --p_yes
pr=$(bcftools view -H "$WORK/t27.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ] && ! echo "$pr" | grep -q '^45,'; } \
  && ok "T27 -r --regions-overlap pos respected (45 excluded: $pr)" || bad "T27 regions-overlap pos" "serial=$sr parallel=$pr"

# T28 (regions-overlap variant passthrough) variant can't be tiled exactly -> run direct.
perl "$PBCF" view -r 1:50-60 --regions-overlap variant "$WORK/span.vcf.gz" -Oz -o "$WORK/t28.vcf.gz" --p_yes >"$WORK/t28.log" 2>&1
rc=$?
grep -qi 'variant' "$WORK/t28.log" && pt=1 || pt=0
{ [ "$rc" = 0 ] && [ "$pt" = 1 ]; } && ok "T28 -r --regions-overlap variant -> passthrough" || bad "T28 variant passthrough" "exit=$rc passthru=$pt"

# T29 (adjacent intervals, no dup) a record spanning two adjacent user intervals
# must appear ONCE (bcftools dedups; coalesce per contig). deletion 45-64, -r
# 1:50-60,1:61-80.
sr=$(bcftools view -H -r 1:50-60,1:61-80 "$WORK/spanlong.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run view -r 1:50-60,1:61-80 "$WORK/spanlong.vcf.gz" -Oz -o "$WORK/t29.vcf.gz" --p_jobs 2 --p_len 5 --p_yes
pr=$(bcftools view -H "$WORK/t29.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ]; } && ok "T29 adjacent intervals no dup ($pr)" || bad "T29 adjacent intervals" "serial=$sr parallel=$pr"

# T30 (chr:pos single position) `-r 1:60` selects position 60 (not 60-to-end).
sr=$(bcftools view -H -r 1:60 "$WORK/spanlong.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run view -r 1:60 "$WORK/spanlong.vcf.gz" -Oz -o "$WORK/t30.vcf.gz" --p_jobs 2 --p_yes
pr=$(bcftools view -H "$WORK/t30.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ]; } && ok "T30 chr:pos single position ($pr)" || bad "T30 chr:pos parse" "serial=$sr parallel=$pr"

# T31 (repeated -r last-wins) bcftools uses the LAST -r; pbcftools must too.
sr=$(bcftools view -H -r 1:50-60 -r 1:100-110 "$WORK/spanlong.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run view -r 1:50-60 -r 1:100-110 "$WORK/spanlong.vcf.gz" -Oz -o "$WORK/t31.vcf.gz" --p_jobs 2 --p_yes
pr=$(bcftools view -H "$WORK/t31.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ]; } && ok "T31 repeated -r last-wins ($pr)" || bad "T31 repeated -r" "serial=$sr parallel=$pr"

# T32 (contig length union) same contig, larger length in a later file: records
# beyond the first file's bound must NOT be omitted.
sr=$(bcftools merge "$WORK/len_a.vcf.gz" "$WORK/len_b.vcf.gz" 2>/dev/null | bcftools view -H 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run merge "$WORK/len_a.vcf.gz" "$WORK/len_b.vcf.gz" -Oz -o "$WORK/t32.vcf.gz" --p_jobs 2 --p_yes
pr=$(bcftools view -H "$WORK/t32.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ] && echo "$pr" | grep -q '500'; } && ok "T32 multi-input max contig length ($pr)" || bad "T32 contig length union" "serial=$sr parallel=$pr"

# T33 (roh -O z passthrough) roh in CHROMOSOME mode assembles plain text (T98),
# but `-O z` is BGZF-COMPRESSED text the plain-text assembler cannot concatenate,
# so it must still be ROUTED to direct bcftools. We assert the routing, not roh's
# own success (roh needs AF params the synthetic data lacks).
perl "$PBCF" roh -O z "$WORK/main.vcf.gz" -o "$WORK/t33.txt.gz" --p_yes >"$WORK/t33.log" 2>&1
grep -qiE 'cannot be parallelized|Running: bcftools roh' "$WORK/t33.log" && pt=1 || pt=0
{ [ "$pt" = 1 ]; } && ok "T33 roh -O z -> passthrough (routed direct)" || bad "T33 roh -O z passthrough" "not routed to passthrough"

# T34 (query -H passthrough) header-printing query isn't tiled -> passthrough == serial.
bcftools query -H -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" > "$WORK/t34.ser.txt" 2>/dev/null
run query -H -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t34.par.txt" --p_jobs 4 --p_yes
rc=$?
{ [ "$rc" = 0 ] && diff -q "$WORK/t34.ser.txt" "$WORK/t34.par.txt" >/dev/null 2>&1; } \
  && ok "T34 query -H -> passthrough == serial" || bad "T34 query -H passthrough" "exit=$rc"

# T35 (contig order with a multi-interval contig) bcftools processes contigs in
# -r order; pbcftools must too (coalesce all when any contig is multi-interval).
sr=$(bcftools view -H -r 2:1-500000,1:1-500000,1:1000000-1500000 "$WORK/main.vcf.gz" 2>/dev/null | awk '{print $1}' | uniq | tr '\n' ',')
run view -r 2:1-500000,1:1-500000,1:1000000-1500000 "$WORK/main.vcf.gz" -Oz -o "$WORK/t35.vcf.gz" --p_jobs 3 --p_yes
pr=$(bcftools view -H "$WORK/t35.vcf.gz" 2>/dev/null | awk '{print $1}' | uniq | tr '\n' ',')
{ [ "$sr" = "$pr" ] && [ "$sr" = "2,1," ]; } && ok "T35 contig order preserved ($pr)" || bad "T35 contig order" "serial=$sr parallel=$pr"

# T36 (bundled short option) `norm -Na` = `-N -a`; the classifier must see the
# bundled -a (atomize) and route to chromosome, not miss it.
#
# The MEANING of this bundle is version-dependent, so the assertion is phrased
# against serial bcftools rather than against a fixed expectation. In 1.22 and
# earlier `-N` is `--do-not-normalize`, a flag, and `-Na` is `-N -a`. In 1.24 it
# became `--no-realign [NUM]`, an OPTIONAL-argument option, so `-Na` parses as
# -N with the argument "a" and serial bcftools itself rejects it ("Could not parse
# argument"). Asserting "must route to chromosome" therefore encoded a bcftools
# version, not a pbcftools property. What must hold on EVERY version is the
# fail-closed rule: parallel may not succeed where serial fails.
bcftools norm -Na "$WORK/main.vcf.gz" -Oz -o "$WORK/t36ser.vcf.gz" >"$WORK/t36ser.log" 2>&1
t36ser_ok=$(grep -qiE 'could not parse|expected .* option|unknown|invalid' "$WORK/t36ser.log" && echo 0 || echo 1)
perl "$PBCF" norm -Na "$WORK/main.vcf.gz" -Oz -o "$WORK/t36.vcf.gz" --p_jobs 2 --p_yes >"$WORK/t36.log" 2>&1
t36par_rc=$?
if [ "$t36ser_ok" = 1 ]; then
    grep -qi 'per whole chromosome' "$WORK/t36.log" \
      && ok "T36 bundled -Na -> chromosome" \
      || bad "T36 bundled short" "not routed to chromosome"
elif [ "$t36par_rc" != 0 ]; then
    skip "T36 bundled -Na (this bcftools parses -N as optional-arg; serial rejects it too)"
else
    bad "T36 bundled short" "serial bcftools rejects '-Na' but parallel returned 0"
fi

# T37 (abbreviated --regions-overlap) `--regions-o=pos` must be honored (excludes
# the spanning 45 deletion), same as the full option name.
sr=$(bcftools view -H -r 1:50-60 --regions-o=pos "$WORK/span.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run view -r 1:50-60 --regions-o=pos "$WORK/span.vcf.gz" -Oz -o "$WORK/t37.vcf.gz" --p_jobs 2 --p_len 5 --p_yes
pr=$(bcftools view -H "$WORK/t37.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ] && ! echo "$pr" | grep -q '45'; } && ok "T37 abbreviated --regions-o=pos honored ($pr)" || bad "T37 abbrev overlap" "serial=$sr parallel=$pr"

# T38 (abbreviated query --list-s) accepted as --list-samples -> passthrough, lists samples.
perl "$PBCF" query --list-s "$WORK/main.vcf.gz" -o "$WORK/t38.txt" --p_yes >"$WORK/t38.log" 2>&1
rc=$?
smp=$(tr '\n' ',' < "$WORK/t38.txt" 2>/dev/null)
{ [ "$rc" = 0 ] && [ "$smp" = "S1,S2," ]; } && ok "T38 query --list-s -> samples ($smp)" || bad "T38 abbrev list-s" "exit=$rc samples=$smp"

# T39 (unknown contig length) a later multi-input file with an unknown length
# (index '.') can't be bounded -> FAIL CLOSED (no --p_fai), don't omit records.
rm -f "$WORK/t39.vcf.gz"
perl "$PBCF" merge "$WORK/main.vcf.gz" "$WORK/unk_b.vcf.gz" -Oz -o "$WORK/t39.vcf.gz" --p_yes >"$WORK/t39.log" 2>&1
rc=$?
grep -qi 'length is unknown' "$WORK/t39.log" && caught=1 || caught=0
{ [ "$rc" != 0 ] && [ "$caught" = 1 ] && [ ! -e "$WORK/t39.vcf.gz" ]; } \
  && ok "T39 unknown length -> fail-closed" || bad "T39 unknown length" "exit=$rc caught=$caught output=$([ -e "$WORK/t39.vcf.gz" ] && echo yes || echo no)"

# T40 (--p_fai bounds unknown length) a valid FAI supplies the bound so a later
# record beyond the first header is NOT omitted (was silently truncated).
sr=$(bcftools merge "$WORK/unk_a.vcf.gz" "$WORK/unk_b.vcf.gz" 2>/dev/null | bcftools view -H 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run merge "$WORK/unk_a.vcf.gz" "$WORK/unk_b.vcf.gz" --p_fai "$WORK/unk_ref.fa.fai" -Oz -o "$WORK/t40.vcf.gz" --p_jobs 2 --p_yes
pr=$(bcftools view -H "$WORK/t40.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$sr" = "$pr" ] && echo "$pr" | grep -q '500'; } && ok "T40 --p_fai bounds unknown length ($pr)" || bad "T40 --p_fai bound" "serial=$sr parallel=$pr"

# T41 (attached-value not misread) `csq -flocal.fa` — the fasta basename contains an
# 'l' — must NOT be read as -l/--local-csq, which would relax csq into the
# region-splittable per-record mode.
#
# Haplotype-aware csq is split per CHROMOSOME, never within one. Checked against
# bcftools directly: with a GFF covering both contigs, per-contig output is
# byte-identical to a whole-file run. The assertion is that an attached value must
# not unlock the relaxed per-record mode.
perl "$PBCF" csq -f"$WORK/local.fa" -g nogff.gff "$WORK/main.vcf.gz" -Oz -o "$WORK/t41.vcf.gz" --p_jobs 2 --p_yes >"$WORK/t41.log" 2>&1
grep -qi 'per whole chromosome' "$WORK/t41.log" && routed=1 || routed=0
# and -l must still unlock the parallel path
perl "$PBCF" csq -l -f"$WORK/local.fa" -g nogff.gff "$WORK/main.vcf.gz" -Oz -o "$WORK/t41b.vcf.gz" --p_jobs 2 --p_yes >"$WORK/t41b.log" 2>&1
grep -qi 'per whole chromosome' "$WORK/t41b.log" && relaxed=0 || relaxed=1
{ [ "$routed" = 1 ] && [ "$relaxed" = 1 ]; } \
  && ok "T41 csq -flocal.fa -> chromosome (not misread as -l); -l still relaxes" \
  || bad "T41 attached-value overmatch" "serial_routed=$routed local_csq_relaxes=$relaxed"

# T42 (query -fhello stays parallel) an attached format value with 'l' must NOT
# be misread as query -l (which would passthrough).
run query -fhello "$WORK/main.vcf.gz" -o "$WORK/t42.txt" --p_jobs 4 --p_len 400KB --p_yes >"$WORK/t42.log" 2>&1
grep -qi 'cannot be parallelized' "$WORK/t42.log" && pass=0 || pass=1   # must NOT passthrough
[ "$pass" = 1 ] && ok "T42 query -fhello stays parallel (not misread as -l)" || bad "T42 query -f overmatch" "wrongly passed through"

# T43 (abbreviated --regions-file) `--regions-f` must be recognized -> passthrough.
printf '1\t1000000\t1500000\n' > "$WORK/t43.reg"
perl "$PBCF" view --regions-f="$WORK/t43.reg" "$WORK/main.vcf.gz" -Oz -o "$WORK/t43.vcf.gz" --p_yes >"$WORK/t43.log" 2>&1
rc=$?
grep -qi 'regions from a file' "$WORK/t43.log" && pt=1 || pt=0
{ [ "$rc" = 0 ] && [ "$pt" = 1 ]; } && ok "T43 abbreviated --regions-f -> passthrough" || bad "T43 --regions-f abbrev" "exit=$rc passthru=$pt"

# T44 (shell-metachar expression quoting) an -i/-e expression with `>` (and `<`,
# `|`, `"`, `[`) must be quoted per worker, not interpreted as a shell redirect.
bcftools view -i 'AF>0.05' "$WORK/main.vcf.gz" -Oz -o "$WORK/t44a.ser.vcf.gz" 2>/dev/null
run view -i 'AF>0.05' "$WORK/main.vcf.gz" -Oz -o "$WORK/t44a.par.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes
sa=$(bcftools view -H "$WORK/t44a.ser.vcf.gz" 2>/dev/null | _md5)
pa=$(bcftools view -H "$WORK/t44a.par.vcf.gz" 2>/dev/null | _md5)
bcftools view -i 'GT[0]="0|1"' "$WORK/main.vcf.gz" -Oz -o "$WORK/t44b.ser.vcf.gz" 2>/dev/null
run view -i 'GT[0]="0|1"' "$WORK/main.vcf.gz" -Oz -o "$WORK/t44b.par.vcf.gz" --p_jobs 4 --p_len 400KB --p_yes
sb=$(bcftools view -H "$WORK/t44b.ser.vcf.gz" 2>/dev/null | _md5)
pb=$(bcftools view -H "$WORK/t44b.par.vcf.gz" 2>/dev/null | _md5)
{ [ -n "$sa" ] && [ "$sa" = "$pa" ] && [ -n "$sb" ] && [ "$sb" = "$pb" ]; } \
  && ok "T44 metachar expressions (>,|,\",[]) quoted == serial" || bad "T44 expression quoting" "AF>: $sa/$pa  GT|: $sb/$pb"

# T45 (end-to-end OUTPUT-PATH injection) an -o filename with shell metacharacters
# ($, backtick, ;, space) but valid as a single path component must be written
# literally, match serial, index cleanly, and NOT execute embedded command
# substitution. Exercises the assembly/concat/index/provenance shell calls (the
# `;touch MARKER` payload lands in $WORK if injection occurs). run from $WORK so
# any stray marker is contained and cleaned with it.
INJ='out $x `id` ;touch pbcf_INJECT_MARKER .vcf.gz'
bcftools view "$WORK/main.vcf.gz" -Oz -o "$WORK/t45.ser.vcf.gz" 2>/dev/null
rm -f "$WORK/pbcf_INJECT_MARKER" "$WORK/$INJ" "$WORK/$INJ.csi"
( cd "$WORK" && run view main.vcf.gz -Oz -o "$INJ" --p_jobs 4 --p_len 400KB --p_yes ) >/dev/null 2>&1
t45rc=$?
s45=$(bcftools view -H "$WORK/t45.ser.vcf.gz" 2>/dev/null | _md5)
p45=$(bcftools view -H "$WORK/$INJ" 2>/dev/null | _md5)
if [ -e "$WORK/pbcf_INJECT_MARKER" ]; then
  bad "T45 output-path injection" "embedded \$(touch) executed -- SHELL INJECTION"
elif [ "$t45rc" = 0 ] && [ -n "$s45" ] && [ "$s45" = "$p45" ] && [ -e "$WORK/$INJ.csi" ]; then
  ok "T45 metachar output path (\$,\`,;,space) literal == serial, indexed, no injection"
else
  bad "T45 output-path injection" "rc=$t45rc ser=$s45 par=$p45 indexed=$([ -e "$WORK/$INJ.csi" ] && echo y || echo n)"
fi

# T46 (attached -rREGION) bcftools accepts `-r1:...` (value attached to the short
# option). pbcftools must recognize it, sub-split it, and match serial — not do a
# genome-wide split with the region re-applied per worker (which duplicated data).
bcftools query -f '%CHROM\t%POS\n' -r1:1-160000 "$WORK/main.vcf.gz" 2>/dev/null | sort > "$WORK/t46.ser"
run query -f '%CHROM\t%POS\n' -r1:1-160000 "$WORK/main.vcf.gz" -o "$WORK/t46.par" --p_jobs 4 --p_len 40000 --p_yes
sort "$WORK/t46.par" 2>/dev/null > "$WORK/t46.par.s"
if diff -q "$WORK/t46.ser" "$WORK/t46.par.s" >/dev/null 2>&1 && [ -s "$WORK/t46.ser" ]; then
  ok "T46 attached -rREGION == serial ($(wc -l < "$WORK/t46.ser" | tr -d ' ') rows)"
else bad "T46 attached -r" "ser=$(wc -l <"$WORK/t46.ser") par=$(wc -l <"$WORK/t46.par.s" 2>/dev/null)"; fi

# T47 (input/output alias refused) `view in -o in` must refuse and NOT delete the
# input, rather than unlink it and crash on region discovery.
cp "$WORK/main.vcf.gz" "$WORK/t47.vcf.gz"; cp "$WORK/main.vcf.gz.csi" "$WORK/t47.vcf.gz.csi" 2>/dev/null
run view "$WORK/t47.vcf.gz" -Oz -o "$WORK/t47.vcf.gz" --p_yes >/dev/null 2>&1
[ -s "$WORK/t47.vcf.gz" ] && grep -qs "same file" "$WORK/err.log" \
  && ok "T47 input/output alias refused; input preserved" \
  || bad "T47 io-alias" "input $([ -s "$WORK/t47.vcf.gz" ] && echo kept || echo DELETED)"

# T48 (unknown --p_mode rejected) a typo must error, not silently run Local.
run view "$WORK/main.vcf.gz" -o "$WORK/t48.vcf.gz" --p_mode slrum --p_yes >/dev/null 2>&1
[ ! -e "$WORK/t48.vcf.gz" ] && grep -qs -- "--p_mode must be" "$WORK/err.log" \
  && ok "T48 unknown --p_mode rejected" || bad "T48 pmode" "did not reject typo"

# T49 (invalid --p_wal fails closed, no injection) a metachar walltime must croak
# before building any scheduler command, and must not execute the payload.
rm -f "$WORK/T49_MARKER"
run view "$WORK/main.vcf.gz" -o "$WORK/t49.vcf.gz" --p_mode slurm --p_dir "$WORK/t49.pdir" \
    --p_jobs 2 --p_wal "1h; touch $WORK/T49_MARKER #" --p_yes >/dev/null 2>&1
[ ! -e "$WORK/T49_MARKER" ] && grep -qs "Invalid --p_wal" "$WORK/err.log" \
  && ok "T49 invalid --p_wal fails closed, no injection" || bad "T49 pwal injection" "marker=$([ -e "$WORK/T49_MARKER" ] && echo YES || echo no)"

# T50 (non-empty --p_dir refused) pbcftools must never delete a user directory.
mkdir -p "$WORK/t50.pdir"; touch "$WORK/t50.pdir/precious"
run view "$WORK/main.vcf.gz" -o "$WORK/t50.vcf.gz" --p_dir "$WORK/t50.pdir" --p_yes >/dev/null 2>&1
[ -e "$WORK/t50.pdir/precious" ] && grep -qs "not empty" "$WORK/err.log" \
  && ok "T50 non-empty --p_dir refused; contents preserved" \
  || bad "T50 pdir deletion" "precious $([ -e "$WORK/t50.pdir/precious" ] && echo kept || echo DELETED)"

# T51 (async cluster controller) drive Backend/Cluster.pm through a fake LSF
# scheduler: submit wave -> recover IDs by marker -> poll -> a forced failure ->
# escalate + re-batch -> all complete. The only offline check of the cluster loop.
# cluster_mock.pl is a development harness and is not part of the distribution, so
# a release checkout will not have it. That must SKIP, not FAIL: a user running the
# suite on a fresh install would otherwise see "1 failed" and reasonably conclude
# the software is broken.
if [ ! -f "$SCRIPT_DIR/cluster_mock.pl" ]; then
  skip "T51 async cluster controller (cluster_mock.pl not in this distribution)"
elif perl "$SCRIPT_DIR/cluster_mock.pl" >"$WORK/t51.log" 2>&1; then
  ok "T51 async cluster controller (submit/recover/retry/escalate via mock scheduler)"
else
  bad "T51 cluster controller" "$(grep -m1 FAIL "$WORK/t51.log" | sed 's/^ *//')"
fi

# T52 (empty text output still created) a filter that excludes every record must
# still produce the requested (empty) output file and exit 0 — not vanish.
rm -f "$WORK/t52.tsv"
run query -i 'POS<0' -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t52.tsv" --p_jobs 4 --p_yes
t52rc=$?
[ "$t52rc" = 0 ] && [ -e "$WORK/t52.tsv" ] && [ ! -s "$WORK/t52.tsv" ] \
  && ok "T52 all-empty text output: file created, exit 0" \
  || bad "T52 empty text" "rc=$t52rc exists=$([ -e "$WORK/t52.tsv" ] && echo y || echo n)"

# T53 (index -o honored) a custom index path must be written, not discarded.
cp "$WORK/main.vcf.gz" "$WORK/t53.vcf.gz"
run index -o "$WORK/t53.custom.csi" "$WORK/t53.vcf.gz" --p_yes >/dev/null 2>&1
[ -e "$WORK/t53.custom.csi" ] && ok "T53 index -o custom path honored" \
  || bad "T53 index -o" "custom index not created"

# T54 (multi-input passthrough keeps inputs) merge --gvcf routes to bcftools
# directly; it must run WITH its inputs (not a stripped argv) -> serial-equal.
mkdir="$WORK/t54"; mkdir -p "$mkdir"
for s in A B; do
  { echo '##fileformat=VCFv4.2'; echo '##contig=<ID=1,length=1000>';
    echo '##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">';
    printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\t%s\n' "$s";
    printf '1\t100\t.\tA\tG\t.\t.\t.\tGT\t0|1\n'; } > "$mkdir/$s.vcf"
  bgzip -f "$mkdir/$s.vcf" 2>/dev/null; bcftools index -f "$mkdir/$s.vcf.gz" 2>/dev/null
done
printf '%s\n%s\n' "$mkdir/A.vcf.gz" "$mkdir/B.vcf.gz" > "$mkdir/list"
bcftools merge --gvcf - -l "$mkdir/list" -Oz -o "$mkdir/ser.vcf.gz" 2>/dev/null
run merge --gvcf - -l "$mkdir/list" -Oz -o "$mkdir/par.vcf.gz" --p_yes >/dev/null 2>&1
sc=$(bcftools view -H "$mkdir/ser.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
pc=$(bcftools view -H "$mkdir/par.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
[ -n "$sc" ] && [ "$sc" = "$pc" ] && [ "$sc" -gt 0 ] \
  && ok "T54 merge --gvcf passthrough keeps inputs ($pc==$sc records)" \
  || bad "T54 multi-input passthrough" "serial=$sc parallel=$pc"

# T55 (concat output aliases FIRST input) `concat a b -o a` must refuse — the
# alias guard must enumerate ALL inputs (not just the last), or it destroys a.
cp "$mkdir/A.vcf.gz" "$mkdir/ca.vcf.gz"; cp "$mkdir/A.vcf.gz.csi" "$mkdir/ca.vcf.gz.csi" 2>/dev/null
cb="$mkdir/B.vcf.gz"
before=$(bcftools view -H "$mkdir/ca.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run concat "$mkdir/ca.vcf.gz" "$cb" -Oz -o "$mkdir/ca.vcf.gz" --p_yes >/dev/null 2>&1
after=$(bcftools view -H "$mkdir/ca.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
[ -n "$before" ] && [ "$before" = "$after" ] && grep -qs "same file" "$WORK/err.log" \
  && ok "T55 concat -o first-input alias refused; input preserved" \
  || bad "T55 concat alias" "first input records before=$before after=$after"

# T56 (Local signal-killed worker not treated as success) a worker whose shell is
# killed by a signal leaves exit-byte 0; it must be classified failed, not
# completed (which would let a partial chunk be assembled).
mkstat=$(perl -Ilib -e '
use PBCFTools::Backend::Local; use File::Temp qw(tempdir);
my $d=tempdir(CLEANUP=>1);
my @j=({name=>"k",file=>"$d/k",cmd=>"sh -c \x27kill -9 \$\$\x27",status=>""});
PBCFTools::Backend::Local->new(pjobs=>1,fail_stop=>0)->run_jobs(\@j,sub{});
print "MKSTAT=$j[0]{status}\n";
' 2>/dev/null | grep -oE "MKSTAT=[a-z:]+" | cut -d= -f2)
[ "$mkstat" = "failed" ] && ok "T56 Local signal-killed worker -> failed (not assembled)" \
  || bad "T56 Local signal status" "got '$mkstat' (expected failed)"

# T57 (preflight failure preserves a prior output) a run that fails during
# preflight (here: unknown --p_mode) must NOT destroy an existing valid output.
echo "PRECIOUS" > "$WORK/t57.out"
run view "$WORK/main.vcf.gz" -o "$WORK/t57.out" --p_mode slrum --p_yes >/dev/null 2>&1
[ "$(cat "$WORK/t57.out" 2>/dev/null)" = "PRECIOUS" ] \
  && ok "T57 preflight failure preserves existing output" \
  || bad "T57 output preservation" "existing output was destroyed"

# T58 (list container aliases output) the -f file is itself an input, not merely
# a source of member paths. Refuse before bcftools can truncate inputs.lst.
list_before=$(cksum "$mkdir/list" 2>/dev/null | awk '{print $1":"$2}')
run concat -f "$mkdir/list" -Oz -o "$mkdir/list" --p_yes >/dev/null 2>&1
list_after=$(cksum "$mkdir/list" 2>/dev/null | awk '{print $1":"$2}')
[ -n "$list_before" ] && [ "$list_before" = "$list_after" ] && grep -qs "same file" "$WORK/err.log" \
  && ok "T58 concat -o list-container alias refused; list preserved" \
  || bad "T58 list-container alias" "before=$list_before after=$list_after"

# T59 (buffered fixed-header append close failure) each query chunk is below the
# process file-size limit, but their concatenation is above it. Ignoring SIGXFSZ
# makes stdio close report EFBIG deterministically: the final output must vanish,
# the not-yet-consumed chunk must remain, and the run must fail.
{
  echo '##fileformat=VCFv4.2'
  echo '##contig=<ID=1,length=4000>'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  for k in $(seq 1 120); do printf '1\t%d\t.\tA\tG\t.\tPASS\t.\n' $((k*33)); done
} > "$WORK/append_fail.vcf"
bgzip -f "$WORK/append_fail.vcf" && bcftools index -f "$WORK/append_fail.vcf.gz"
rm -rf "$WORK/t59.pdir"; rm -f "$WORK/t59.txt" "$WORK/t59.log" "$WORK/t59.fifo"
# Diagnostics now go to STDERR; route them through a FIFO whose reader lives OUTSIDE
# the `ulimit -f 1` subshell. RLIMIT_FSIZE caps regular-file writes only, so the FIFO
# is unlimited while the OUTPUT file (t59.txt) still trips the cap on append — which
# is exactly the failure this test injects.
mkfifo "$WORK/t59.fifo"
cat "$WORK/t59.fifo" > "$WORK/t59.log" &
t59cat=$!
(
  trap '' XFSZ 2>/dev/null || true
  ulimit -f 1
  perl "$PBCF" query -f '%CHROM\t%POS\tXX\n' "$WORK/append_fail.vcf.gz" \
    -o "$WORK/t59.txt" --p_dir "$WORK/t59.pdir" --p_jobs 1 --p_len 1000 --p_yes \
    >/dev/null 2>"$WORK/t59.fifo"
)
t59rc=$?
wait "$t59cat" 2>/dev/null
rm -f "$WORK/t59.fifo"
find "$WORK/t59.pdir" -type f -name '*t59.txt' -size +0c -print -quit 2>/dev/null | grep -q . \
  && t59chunk=1 || t59chunk=0
grep -qE "Close of .*text output may be truncated|Append to .* failed" "$WORK/t59.log" \
  && t59caught=1 || t59caught=0
[ "$t59rc" != 0 ] && [ ! -e "$WORK/t59.txt" ] && [ "$t59chunk" = 1 ] && [ "$t59caught" = 1 ] \
  && ok "T59 query append-close failure -> fail, partial removed, chunk preserved" \
  || bad "T59 append-close failure" "rc=$t59rc output=$([ -e "$WORK/t59.txt" ] && echo y || echo n) chunk=$t59chunk caught=$t59caught"

# T60 (explicit local --p_dir is a parent, not a shared artifact root) launch two
# controllers concurrently with colliding output basenames below one initially
# empty parent. Each must create and retain its own nonce child containing its own
# para_job.lst/chunks, and both assembled outputs must match the input.
mkdir -p "$WORK/t60.parent" "$WORK/t60.a" "$WORK/t60.b"
perl "$PBCF" view "$WORK/main.vcf.gz" -Oz -o "$WORK/t60.a/shared.vcf.gz" \
  --p_dir "$WORK/t60.parent" --p_jobs 2 --p_len 400KB --p_yes \
  >"$WORK/t60.a.log" 2>&1 &
t60pa=$!
perl "$PBCF" view "$WORK/main.vcf.gz" -Oz -o "$WORK/t60.b/shared.vcf.gz" \
  --p_dir "$WORK/t60.parent" --p_jobs 2 --p_len 400KB --p_yes \
  >"$WORK/t60.b.log" 2>&1 &
t60pb=$!
wait "$t60pa"; t60ra=$?
wait "$t60pb"; t60rb=$?
t60dirs=$(find "$WORK/t60.parent" -mindepth 1 -maxdepth 1 -type d -name 'pbcf_*' 2>/dev/null | wc -l | tr -d ' ')
t60lists=$(find "$WORK/t60.parent" -mindepth 2 -maxdepth 2 -type f -name para_job.lst 2>/dev/null | wc -l | tr -d ' ')
t60ca=$(bcftools view -H "$WORK/t60.a/shared.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
t60cb=$(bcftools view -H "$WORK/t60.b/shared.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
[ "$t60ra" = 0 ] && [ "$t60rb" = 0 ] && [ "$t60dirs" = 2 ] && [ "$t60lists" = 2 ] \
  && [ "$t60ca" = "$N_TOTAL" ] && [ "$t60cb" = "$N_TOTAL" ] \
  && ok "T60 concurrent local controllers sharing --p_dir use isolated retained run children" \
  || bad "T60 local --p_dir isolation" "rc=$t60ra/$t60rb dirs=$t60dirs lists=$t60lists records=$t60ca/$t60cb"

# T61 (single-chunk = plain-bcftools passthrough) when the split yields exactly
# ONE chunk there is no parallelism to gain, so pbcftools runs the command with
# plain bcftools and exits — behaving exactly like bcftools. This also avoids the
# `stats` corner where `plot-vcfstats -m` rejects a lone input ("Nothing to
# merge", exit 255). `-r 1` with a plen larger than contig 1 (2 Mb) forces one
# chunk; the output must still match serial and NOT need plot-vcfstats.
bcftools stats -r 1 "$WORK/main.vcf.gz" > "$WORK/t61.ser.chk" 2>/dev/null
rm -f "$WORK/t61.par.chk"
run stats -r 1 "$WORK/main.vcf.gz" -o "$WORK/t61.par.chk" --p_jobs 4 --p_len 3MB --p_yes >/dev/null 2>&1
t61rc=$?
canon61() { grep -v '^#' "$1" | awk -F'\t' '$1!="ID"{ o=$1; for(i=3;i<=NF;i++) o=o"\t"$i; print o }' | sort; }
# The "one region chunk" passthrough NOTE is a diagnostic -> STDERR (err.log).
if [ "$t61rc" = 0 ] && [ -s "$WORK/t61.par.chk" ] \
   && grep -q "one region chunk" "$WORK/err.log" \
   && diff -q <(canon61 "$WORK/t61.ser.chk") <(canon61 "$WORK/t61.par.chk") >/dev/null 2>&1; then
  ok "T61 single-chunk stats == serial (plain-bcftools passthrough, no plot-vcfstats -m)"
else
  bad "T61 single-chunk stats" "exit=$t61rc; single chunk must pass through to plain bcftools and match"
fi

# T62 (query -l is NOT a file list, F4) `query -l` = --list-samples; it must pass
# through, never be opened as a file-of-filenames (which would read the whole input
# VCF as a text list). main.vcf.gz has 2 samples S1,S2.
perl "$PBCF" query -l "$WORK/main.vcf.gz" -o "$WORK/t62.txt" --p_yes >"$WORK/t62.log" 2>&1
t62rc=$?
if [ "$t62rc" = 0 ] && grep -q "Running: bcftools query -l" "$WORK/t62.log" \
   && [ "$(grep -c . "$WORK/t62.txt" 2>/dev/null)" = 2 ]; then
  ok "T62 query -l passes through (input not read as a file list)"
else
  bad "T62 query -l passthrough" "rc=$t62rc samples=$(grep -c . "$WORK/t62.txt" 2>/dev/null)"
fi

# T63 (-r unknown contig fails closed, F6) a -r component naming a contig not in
# the input must FAIL CLEARLY, never silently drop that region and emit a partial
# result. main.vcf.gz has contigs 1 and 2.
perl "$PBCF" view -r 1:1-100,NOSUCH:1-100 "$WORK/main.vcf.gz" -Oz -o "$WORK/t63.vcf.gz" --p_yes >"$WORK/t63.log" 2>&1
t63rc=$?
if [ "$t63rc" != 0 ] && grep -qi "not in the input" "$WORK/t63.log" && [ ! -s "$WORK/t63.vcf.gz" ]; then
  ok "T63 -r unknown contig fails closed (no silent partial)"
else
  bad "T63 -r unknown contig" "rc=$t63rc (must fail clearly with no output)"
fi

# T64 (wait_status_exit decoder, F1/F5) a signal-killed command's raw wait status
# must decode to a NONZERO exit — a bare `>>8` would report 0 for signal death.
t64=$(perl "-I$SCRIPT_DIR/../lib" -MPBCFTools::Helpers -e \
  'print((wait_status_exit(9)==137 && wait_status_exit(256)==1 && wait_status_exit(0)==0 && wait_status_exit(-1)==127)?"OK":"BAD")' 2>&1)
[ "$t64" = "OK" ] && ok "T64 wait_status_exit: signal death decodes nonzero" \
  || bad "T64 wait_status_exit" "got: $t64"

# T65 (concat --file-list member aliases output, F4-regression guard) the alias
# guard must enumerate the --file-list LONG form's members (not only -f), or
# `concat --file-list list -o <a-listed-member>` overwrites an input. $mkdir/list
# (from T54) holds A.vcf.gz + B.vcf.gz.
t65b=$(bcftools view -H "$mkdir/A.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run concat --file-list "$mkdir/list" -Oz -o "$mkdir/A.vcf.gz" --p_yes >/dev/null 2>&1
t65a=$(bcftools view -H "$mkdir/A.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$t65b" ] && [ "$t65b" = "$t65a" ] && grep -qs "same file" "$WORK/err.log"; then
  ok "T65 concat --file-list member alias refused; input preserved"
else
  bad "T65 concat --file-list alias" "before=$t65b after=$t65a (output must be refused, input intact)"
fi

# T66 (attached -lFILE recognized by the alias guard, round-10 regression) merge
# -l<list> (attached, no space) with -o = a listed member must be refused; before
# the shared-helper fix the guard missed attached short forms -> could overwrite
# an input. $mkdir/list holds A.vcf.gz + B.vcf.gz (from T54).
t66b=$(bcftools view -H "$mkdir/A.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run merge -l"$mkdir/list" -Oz -o "$mkdir/A.vcf.gz" --p_ref 38 --p_yes >/dev/null 2>&1
t66a=$(bcftools view -H "$mkdir/A.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$t66b" ] && [ "$t66b" = "$t66a" ] && grep -qs "same file" "$WORK/err.log"; then
  ok "T66 merge -l<attached> member alias refused; input preserved"
else
  bad "T66 attached -l alias" "before=$t66b after=$t66a (must refuse; input intact)"
fi

# T67 (repeated -l is last-occurrence-wins, matching bcftools getopt) la=[A],
# lb=[A,B]; `merge -l la -l lb` must use lb (both samples), not la (only A).
# --p_len 50 forces the multi-chunk path, whose per-chunk list comes from
# _find_list_flag's LAST value.
printf '%s\n' "$mkdir/A.vcf.gz" > "$mkdir/la.lst"
printf '%s\n%s\n' "$mkdir/A.vcf.gz" "$mkdir/B.vcf.gz" > "$mkdir/lb.lst"
run merge -l "$mkdir/la.lst" -l "$mkdir/lb.lst" --p_len 50 -Oz -o "$mkdir/t67.vcf.gz" --p_ref 38 --p_yes >/dev/null 2>&1
t67s=$(bcftools query -l "$mkdir/t67.vcf.gz" 2>/dev/null | sort | tr '\n' ',')
[ "$t67s" = "A,B," ] && ok "T67 repeated -l uses the LAST list (last-occurrence-wins)" \
  || bad "T67 -l last-wins" "output samples='$t67s' (expected 'A,B,' from the last -l)"

# T68 (ultra-short --file abbreviation recognized by the alias guard, round-11 F1)
# --file and --file= are bcftools-valid unique abbreviations of --file-list; with
# -o = a listed member the guard must still refuse. $mkdir/list = [A,B].
t68b=$(bcftools view -H "$mkdir/A.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run merge --file "$mkdir/list" -Oz -o "$mkdir/A.vcf.gz" --p_ref 38 --p_yes >/dev/null 2>&1
g1=$(grep -qs "same file" "$WORK/err.log" && echo yes || echo no)
run merge "--file=$mkdir/list" -Oz -o "$mkdir/A.vcf.gz" --p_ref 38 --p_yes >/dev/null 2>&1
g2=$(grep -qs "same file" "$WORK/err.log" && echo yes || echo no)
t68a=$(bcftools view -H "$mkdir/A.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
if [ "$t68b" = "$t68a" ] && [ "$g1" = yes ] && [ "$g2" = yes ]; then
  ok "T68 --file / --file= abbrev member alias refused; input preserved"
else
  bad "T68 --file abbrev alias" "before=$t68b after=$t68a g1=$g1 g2=$g2"
fi

# T69 (mixed positional + -l routes to bcftools, no dropped contigs, round-11 F2)
# bcftools merge processes positional inputs AND a -l list together; the wrapper
# discovers contigs only from the list, so the mixed case must pass through or it
# drops the positional's unique contig. Z is on contig 2 (absent from list=[A,B]).
{ echo '##fileformat=VCFv4.2'; echo '##contig=<ID=2,length=1000>';
  echo '##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">';
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tZ\n'; printf '2\t100\t.\tA\tG\t.\t.\t.\tGT\t0|1\n'; } > "$mkdir/Z.vcf"
bgzip -f "$mkdir/Z.vcf" 2>/dev/null; bcftools index -f "$mkdir/Z.vcf.gz" 2>/dev/null
bcftools merge "$mkdir/Z.vcf.gz" -l "$mkdir/list" -Oz -o "$mkdir/t69.ser.vcf.gz" 2>/dev/null
perl "$PBCF" merge "$mkdir/Z.vcf.gz" -l "$mkdir/list" -Oz -o "$mkdir/t69.par.vcf.gz" --p_ref 38 --p_yes >"$WORK/t69.log" 2>&1
# count contig-2 records without needing an index on the passthrough output
sc2=$(bcftools view -H "$mkdir/t69.par.vcf.gz" 2>/dev/null | awk -F'\t' '$1=="2"' | wc -l | tr -d ' ')
if grep -qi "mixes positional" "$WORK/t69.log" \
   && diff -q <(bcftools view -H "$mkdir/t69.ser.vcf.gz" 2>/dev/null) <(bcftools view -H "$mkdir/t69.par.vcf.gz" 2>/dev/null) >/dev/null 2>&1 \
   && [ "${sc2:-0}" -gt 0 ]; then
  ok "T69 mixed positional+list -> passthrough; positional contig not dropped"
else
  bad "T69 mixed positional+list" "contig2_recs=${sc2:-0} (want passthrough, records==serial, contig 2 present)"
fi

# T70 (mixed passthrough is EXTENSION-AGNOSTIC, round-12 HIGH) an indexed input
# with a NON-VCF name combined positionally with -l must still route to bcftools —
# else its unique contig is dropped. zdata = indexed bgzf VCF on contig 2 (absent
# from list=[A,B] on contig 1), named without a .vcf/.bcf extension.
{ echo '##fileformat=VCFv4.2'; echo '##contig=<ID=2,length=1000>';
  echo '##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">';
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tZ\n'; printf '2\t100\t.\tA\tG\t.\t.\t.\tGT\t0|1\n'; } > "$mkdir/z.raw"
bgzip -c "$mkdir/z.raw" > "$mkdir/zdata" 2>/dev/null; bcftools index -f "$mkdir/zdata" 2>/dev/null
bcftools merge "$mkdir/zdata" -l "$mkdir/list" -Oz -o "$mkdir/t70.ser.vcf.gz" 2>/dev/null
perl "$PBCF" merge "$mkdir/zdata" -l "$mkdir/list" -Oz -o "$mkdir/t70.par.vcf.gz" --p_ref 38 --p_yes >"$WORK/t70.log" 2>&1
c2=$(bcftools view -H "$mkdir/t70.par.vcf.gz" 2>/dev/null | awk -F'\t' '$1=="2"' | wc -l | tr -d ' ')
if grep -qi "mixes positional" "$WORK/t70.log" \
   && diff -q <(bcftools view -H "$mkdir/t70.ser.vcf.gz" 2>/dev/null) <(bcftools view -H "$mkdir/t70.par.vcf.gz" 2>/dev/null) >/dev/null 2>&1 \
   && [ "${c2:-0}" -gt 0 ]; then
  ok "T70 extension-less positional + list -> passthrough; contig not dropped"
else
  bad "T70 extensionless mixed" "contig2=${c2:-0} (want passthrough, records==serial)"
fi

# T71 (merge --no-index routes to passthrough, round-12 MEDIUM) bcftools --no-index
# forbids -r/-R, but the parallel path injects a per-chunk -r; with indexed inputs
# the seekability precheck passes, so without routing it would parallelize + fail.
bcftools merge --no-index "$mkdir/A.vcf.gz" "$mkdir/B.vcf.gz" -Oz -o "$mkdir/t71.ser.vcf.gz" 2>/dev/null
perl "$PBCF" merge --no-index "$mkdir/A.vcf.gz" "$mkdir/B.vcf.gz" -Oz -o "$mkdir/t71.par.vcf.gz" --p_ref 38 --p_yes >"$WORK/t71.log" 2>&1
t71rc=$?
if [ "$t71rc" = 0 ] && grep -qi "no-index" "$WORK/t71.log" \
   && diff -q <(bcftools view -H "$mkdir/t71.ser.vcf.gz" 2>/dev/null) <(bcftools view -H "$mkdir/t71.par.vcf.gz" 2>/dev/null) >/dev/null 2>&1; then
  ok "T71 merge --no-index -> passthrough; serial-equivalent"
else
  bad "T71 merge --no-index" "rc=$t71rc (want passthrough notice + records==serial)"
fi

# T72 (bounded structural parser contract) optional -W must not consume the next
# operand; option values equal to an input path must remain distinct by INDEX;
# extensionless stats operands count; and unknown syntax must be ambiguous.
t72=$(perl "-I$SCRIPT_DIR/../lib" -MPBCFTools::ArgParser=scan_command_argv -e '
  sub vals { my ($s)=@_; join q{|}, map { $_->{index}.q{:}.$_->{value} } @{$s->{operands}} }
  my $w = scan_command_argv([qw(merge -W B.data -l inputs.lst)], q{merge});
  die q{bare-W} unless !$w->{ambiguous} && vals($w) eq q{2:B.data}
      && $w->{roles}{file_list}[0]{value} eq q{inputs.lst};
  my $i = scan_command_argv([qw(merge --use-header A.vcf.gz A.vcf.gz B.data)], q{merge});
  die q{indices} unless !$i->{ambiguous} && vals($i) eq q{3:A.vcf.gz|4:B.data};
  my $s = scan_command_argv([qw(stats A.data B.data)], q{stats});
  die q{stats} unless !$s->{ambiguous} && vals($s) eq q{1:A.data|2:B.data};
  my $u = scan_command_argv([qw(merge --future-option X A.data B.data)], q{merge});
  die q{unknown} unless $u->{ambiguous};
  print q{OK};
' 2>&1)
[ "$t72" = "OK" ] && ok "T72 bounded argv parser: optional args, indices, extensionless inputs, ambiguity" \
  || bad "T72 bounded argv parser" "got: $t72"

# T73 (positional merge is extension-agnostic) if one input looks like VCF and
# the other does not, BOTH remain inputs in their original order. The old
# extension heuristic left Bdata in the worker argv and re-added A via -l,
# reversing sample order and potentially omitting later-only regions.
cp "$mkdir/B.vcf.gz" "$mkdir/Bdata"
cp "$mkdir/B.vcf.gz.csi" "$mkdir/Bdata.csi"
bcftools merge "$mkdir/A.vcf.gz" "$mkdir/Bdata" -Oz -o "$mkdir/t73.ser.vcf.gz" 2>/dev/null
perl "$PBCF" merge "$mkdir/A.vcf.gz" "$mkdir/Bdata" --p_len 50 --p_jobs 2 \
  -Oz -o "$mkdir/t73.par.vcf.gz" --p_ref 38 --p_yes >"$WORK/t73.log" 2>&1
t73rc=$?
t73s=$(bcftools query -l "$mkdir/t73.par.vcf.gz" 2>/dev/null | tr '\n' ',')
if [ "$t73rc" = 0 ] && [ "$t73s" = "A,B," ] \
   && diff -q <(bcftools view -H "$mkdir/t73.ser.vcf.gz" 2>/dev/null) <(bcftools view -H "$mkdir/t73.par.vcf.gz" 2>/dev/null) >/dev/null 2>&1; then
  ok "T73 merge positional inputs are extension-agnostic and order-preserving"
else
  bad "T73 extensionless positional merge" "rc=$t73rc samples='$t73s'"
fi

# T74 (two-file stats is extension-agnostic) both extensionless operands must
# force exact plain-bcftools execution, never approximate per-region aggregation.
cp "$WORK/main.vcf.gz" "$WORK/statsA"
cp "$WORK/main.vcf.gz.csi" "$WORK/statsA.csi"
cp "$WORK/main.vcf.gz" "$WORK/statsB"
cp "$WORK/main.vcf.gz.csi" "$WORK/statsB.csi"
bcftools stats "$WORK/statsA" "$WORK/statsB" > "$WORK/t74.ser.chk" 2>/dev/null
perl "$PBCF" stats "$WORK/statsA" "$WORK/statsB" -o "$WORK/t74.par.chk" \
  --p_jobs 2 --p_len 400KB --p_yes >"$WORK/t74.log" 2>&1
t74rc=$?
canon74() { grep -v '^#' "$1" | grep -v '^ID' | sort; }
if [ "$t74rc" = 0 ] && grep -qi "two-file input" "$WORK/t74.log" \
   && diff -q <(canon74 "$WORK/t74.ser.chk") <(canon74 "$WORK/t74.par.chk") >/dev/null 2>&1; then
  ok "T74 extensionless two-file stats -> exact passthrough"
else
  bad "T74 extensionless two-file stats" "rc=$t74rc (want exact passthrough)"
fi

# T75 (bare -W has an OPTIONAL attached-only value) zdata is therefore a
# positional input. Combined with -l it must trigger mixed-input passthrough so
# its contig-2 record cannot disappear from list-derived region discovery.
# Short -W is a bcftools >= 1.20 spelling; skip below that (project floor is 1.15).
if [ "$HAS_SHORT_W" != 1 ]; then
  skip "T75 bare -W operand (short -W needs bcftools >= 1.20)"
else
bcftools merge -W "$mkdir/zdata" -l "$mkdir/list" -Oz -o "$mkdir/t75.ser.vcf.gz" 2>/dev/null
perl "$PBCF" merge -W "$mkdir/zdata" -l "$mkdir/list" -Oz -o "$mkdir/t75.par.vcf.gz" \
  --p_ref 38 --p_yes >"$WORK/t75.log" 2>&1
t75rc=$?
t75c2=$(bcftools view -H "$mkdir/t75.par.vcf.gz" 2>/dev/null | awk -F'\t' '$1=="2"' | wc -l | tr -d ' ')
if [ "$t75rc" = 0 ] && grep -qi "mixes positional" "$WORK/t75.log" \
   && [ "${t75c2:-0}" -gt 0 ] \
   && diff -q <(bcftools view -H "$mkdir/t75.ser.vcf.gz" 2>/dev/null) <(bcftools view -H "$mkdir/t75.par.vcf.gz" 2>/dev/null) >/dev/null 2>&1; then
  ok "T75 bare -W preserves following operand and mixed-input barrier"
else
  bad "T75 bare -W operand" "rc=$t75rc contig2=${t75c2:-0}"
fi
fi

# T76 (isec uses the same indexed structural removal) B is intentionally first
# and A has no VCF-looking extension. `-w1` makes any input-order inversion
# visible in the output sample name.
cp "$mkdir/A.vcf.gz" "$mkdir/Adata"
cp "$mkdir/A.vcf.gz.csi" "$mkdir/Adata.csi"
bcftools isec -n=2 -w1 "$mkdir/B.vcf.gz" "$mkdir/Adata" -Oz -o "$mkdir/t76.ser.vcf.gz" 2>/dev/null
perl "$PBCF" isec -n=2 -w1 "$mkdir/B.vcf.gz" "$mkdir/Adata" --p_len 50 --p_jobs 2 \
  -Oz -o "$mkdir/t76.par.vcf.gz" --p_ref 38 --p_yes >"$WORK/t76.log" 2>&1
t76rc=$?
t76s=$(bcftools query -l "$mkdir/t76.par.vcf.gz" 2>/dev/null | tr '\n' ',')
if [ "$t76rc" = 0 ] && [ "$t76s" = "B," ] \
   && diff -q <(bcftools view -H "$mkdir/t76.ser.vcf.gz" 2>/dev/null) <(bcftools view -H "$mkdir/t76.par.vcf.gz" 2>/dev/null) >/dev/null 2>&1; then
  ok "T76 isec positional inputs are extension-agnostic and order-preserving"
else
  bad "T76 extensionless positional isec" "rc=$t76rc samples='$t76s'"
fi

# T77 (-W does not hide a positional input from the alias guard on NON-schema
# commands) `view` uses the conservative fallback parser, not the ArgParser
# schema; -W/--write-index is optional-attached, so `view -i 'expr' -W in -o in`
# (which would overwrite the input with a filtered subset) must be REFUSED.
# The -W premise is only a real bcftools option on >= 1.20; skip below that.
if [ "$HAS_SHORT_W" != 1 ]; then
  skip "T77 -W fallback alias guard (short -W needs bcftools >= 1.20)"
else
run view -i 'POS>500' -W "$WORK/main.vcf.gz" -o "$WORK/main.vcf.gz" --p_yes >/dev/null 2>&1
main_recs=$(bcftools view -H "$WORK/main.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
if grep -qs "same file" "$WORK/err.log" && [ "$main_recs" = "$N_TOTAL" ]; then
  ok "T77 -W does not hide a positional input from the alias guard (fallback)"
else
  bad "T77 -W fallback alias guard" "recs=$main_recs/$N_TOTAL (input must be refused, preserved)"
fi
fi

# T78 (destructive alias guard sees OPTION-VALUE inputs, not just positionals) A
# supported command can read a side input via an option, e.g. `annotate -a ann`.
# Naming the output after that side input must be REFUSED before the pre-run unlink
# can delete it. Guard fires before bcftools, so -c columns need not be valid.
ann_recs_before=$(bcftools view -H "$WORK/main.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run annotate -a "$WORK/main.vcf.gz" "$WORK/s1.vcf.gz" -Oz -o "$WORK/main.vcf.gz" --p_yes >/dev/null 2>&1
ann_recs_after=$(bcftools view -H "$WORK/main.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
if grep -qs "same file" "$WORK/err.log" && [ "$ann_recs_after" = "$ann_recs_before" ] \
   && [ "$ann_recs_after" = "$N_TOTAL" ]; then
  ok "T78 alias guard protects an option-value side input (annotate -a == -o refused)"
else
  bad "T78 option-value alias guard" "recs=$ann_recs_after/$N_TOTAL (side input must be refused, preserved)"
fi

# T79 (a stdin file list cannot be vetted against the output) `concat -f -` with an
# -o output must be REFUSED, not passed through — a member named on stdin could
# alias/overwrite the output and could never be checked.
rm -f "$WORK/t79.vcf.gz"
run concat -f - -Oz -o "$WORK/t79.vcf.gz" --p_yes </dev/null >/dev/null 2>&1
if grep -qs "non-regular file list" "$WORK/err.log" && [ ! -e "$WORK/t79.vcf.gz" ]; then
  ok "T79 stdin file list ('-f -') with an output is refused"
else
  bad "T79 stdin-list refusal" "output must not be produced from an unvettable stdin list"
fi

# T80 (multi-input contig probe FAILS CLOSED on a broken index) If `bcftools index
# -s` for a later input emits a valid PREFIX then exits nonzero, a partial contig
# set would slip past the mismatch guard and silently omit records. A PATH shim
# fakes exactly that for the second input; pbcftools must abort with no output.
mkdir -p "$WORK/shim"
REAL_BCFTOOLS="$(command -v bcftools)"
cat > "$WORK/shim/bcftools" <<SHIM
#!/bin/sh
if [ "\$1" = index ] && [ "\$2" = -s ]; then
  case "\$3" in
    *brokenidx*) printf '1\t.\n'; exit 1 ;;
  esac
fi
exec "$REAL_BCFTOOLS" "\$@"
SHIM
chmod +x "$WORK/shim/bcftools"
cp "$WORK/s2.vcf.gz" "$WORK/s2_brokenidx.vcf.gz"
bcftools index -f "$WORK/s2_brokenidx.vcf.gz" 2>/dev/null   # real index, before shim
rm -f "$WORK/t80.vcf.gz"
PATH="$WORK/shim:$PATH" perl "$PBCF" merge "$WORK/s1.vcf.gz" "$WORK/s2_brokenidx.vcf.gz" \
  -Oz -o "$WORK/t80.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes >"$WORK/t80.log" 2>&1
t80rc=$?
if [ "$t80rc" != 0 ] && [ ! -e "$WORK/t80.vcf.gz" ] \
   && grep -qiE "index -s|contig set" "$WORK/t80.log"; then
  ok "T80 multi-input contig probe fails closed on a nonzero 'index -s'"
else
  bad "T80 contig-probe fail-closed" "rc=$t80rc (must abort with no output on a broken index)"
fi

# T81 (bundled short options can HIDE a file-bearing side input) `view -GS<file>`
# glues the sample-file input after the no-arg -G. Naming the output after that
# file must be REFUSED — the suffix scan finds the glued path regardless of how many
# no-arg flags precede it, so the pre-run unlink / passthrough cannot destroy it.
printf 'S1\n' > "$WORK/t81.samples"
t81ck=$(_md5 < "$WORK/t81.samples")
run view -GS"$WORK/t81.samples" -r 1:1-1 "$WORK/main.vcf.gz" -Oz -o "$WORK/t81.samples" --p_yes >/dev/null 2>&1
if grep -qs "same file" "$WORK/err.log" && [ "$(_md5 < "$WORK/t81.samples")" = "$t81ck" ]; then
  ok "T81 bundled -GS<file> side input protected from an aliased output"
else
  bad "T81 bundled side-input alias guard" "sample file must be refused and preserved"
fi

# T82 (a non-file option value that merely SPELLS an existing file must not be
# mistaken for an input) `query -f /dev/null` is a format string and `-o /dev/null`
# is a legitimate discard. pbcftools must match bcftools' serial exit 0 — the guard
# protects REGULAR files only, so /dev/null is never mis-flagged.
bcftools query -r 1:1-1 -f /dev/null "$WORK/main.vcf.gz" -o /dev/null 2>/dev/null; t82ser=$?
run query -r 1:1-1 -f /dev/null "$WORK/main.vcf.gz" -o /dev/null --p_yes >/dev/null 2>&1; t82par=$?
if [ "$t82ser" = 0 ] && [ "$t82par" = 0 ]; then
  ok "T82 non-file option value (/dev/null) is not mis-flagged as an input"
else
  bad "T82 /dev/null passthrough" "serial=$t82ser pbcftools=$t82par (both should be 0)"
fi

# T83 (a NON-REGULAR file-list source cannot be vetted) `concat -f /dev/stdin` with
# an output must be refused before bcftools; a member arriving on the stream could
# equal the output and could never be checked. (Complements T79's literal '-'.)
rm -f "$WORK/t83.vcf.gz"
printf '/no/such.vcf\n' | perl "$PBCF" concat -f /dev/stdin -Oz -o "$WORK/t83.vcf.gz" --p_yes >"$WORK/t83.log" 2>&1
t83rc=$?
if [ "$t83rc" != 0 ] && grep -qi "non-regular file list" "$WORK/t83.log" && [ ! -e "$WORK/t83.vcf.gz" ]; then
  ok "T83 non-regular file-list source ('/dev/stdin') with an output is refused"
else
  bad "T83 non-regular list refusal" "rc=$t83rc (must refuse before bcftools, no output)"
fi

# T84 (tokens after '--' are RAW OPERANDS, not options) An input passed after '--'
# whose path is reused as the output must still be caught by the alias guard, even
# though a positional could look option-like.
cp "$WORK/main.vcf.gz" "$WORK/t84.vcf.gz"
t84ck=$(_md5 < "$WORK/t84.vcf.gz")
run view -r 1:1-1 -Oz -o "$WORK/t84.vcf.gz" -- "$WORK/t84.vcf.gz" </dev/null >/dev/null 2>&1
if grep -qs "same file" "$WORK/err.log" && [ "$(_md5 < "$WORK/t84.vcf.gz")" = "$t84ck" ]; then
  ok "T84 operand after '--' is protected by the alias guard"
else
  bad "T84 post-'--' operand alias guard" "input after '--' must be refused and preserved"
fi

# T85 (a plugin option AFTER the '--' boundary can carry a file side input) The
# only v1 region-enabled plugin, +fill-tags, takes `-S<file>` glued after '--'.
# Naming the output after that file must be REFUSED — the guard scans post-'--'
# short-option payloads, so the file cannot be overwritten. (The guard fires before
# the plugin runs, so this holds even where +fill-tags is not installed, but skip
# to keep the message clean when it is genuinely absent.)
if bcftools +fill-tags "$WORK/main.vcf.gz" -- -t AN >/dev/null 2>&1; then
  printf 'S1\n' > "$WORK/t85.groups"; t85ck=$(_md5 < "$WORK/t85.groups")
  run +fill-tags "$WORK/main.vcf.gz" -r 1:1-1 -Oz -o "$WORK/t85.groups" --p_ref 37 --p_yes \
    -- -S"$WORK/t85.groups" -t HWE >/dev/null 2>&1
  if grep -qs "same file" "$WORK/err.log" && [ "$(_md5 < "$WORK/t85.groups")" = "$t85ck" ]; then
    ok "T85 attached plugin side input after '--' ('-Sfile') is protected"
  else
    bad "T85 post-'--' attached-short side input" "sample file must be refused and preserved"
  fi
  # T86 same, via the attached long form `--samples-file=FILE` after '--'.
  printf 'S1\n' > "$WORK/t86.groups"; t86ck=$(_md5 < "$WORK/t86.groups")
  run +fill-tags "$WORK/main.vcf.gz" -r 1:1-1 -Oz -o "$WORK/t86.groups" --p_ref 37 --p_yes \
    -- --samples-file="$WORK/t86.groups" -t HWE >/dev/null 2>&1
  if grep -qs "same file" "$WORK/err.log" && [ "$(_md5 < "$WORK/t86.groups")" = "$t86ck" ]; then
    ok "T86 attached plugin side input after '--' ('--samples-file=FILE') is protected"
  else
    bad "T86 post-'--' attached-long side input" "sample file must be refused and preserved"
  fi
else
  skip "T85 attached plugin side input after '--' (+fill-tags unavailable)"
  skip "T86 attached plugin side input after '--' (+fill-tags unavailable)"
fi

# T87 (a NON-REGULAR output cannot go through multi-chunk assembly) A splittable
# command writing to /dev/null must route to ONE bcftools process, not the per-chunk
# assembler (which opens/reopens/unlinks the destination and would corrupt a stream
# or delete a FIFO).
perl "$PBCF" view "$WORK/main.vcf.gz" -Oz -o /dev/null --p_len 400KB --p_jobs 4 --p_yes \
  >"$WORK/t87.log" 2>&1
t87rc=$?
if [ "$t87rc" = 0 ] && grep -qi "not a regular file" "$WORK/t87.log"; then
  ok "T87 non-regular output (/dev/null) streams via a single passthrough process"
else
  bad "T87 non-regular output routing" "rc=$t87rc (must passthrough, not multi-chunk assemble)"
fi

# T88 (NARROW role carve-out) `query -f` is a format STRING, never a file. A format
# that coincidentally spells an existing regular file, reused as -o, must NOT be
# mis-flagged as an input alias — pbcftools must match bcftools' serial exit 0. The
# carve-out is surgical: a real file option like query -S stays protected (covered by
# the annotate/-S guard tests). Test both the separated and attached -f forms.
echo "fmt" > "$WORK/t88.fmt"
bcftools query -r 1:1-1 -f "$WORK/t88.fmt" "$WORK/main.vcf.gz" -o "$WORK/t88.fmt" 2>/dev/null; t88ser=$?
echo "fmt" > "$WORK/t88.fmt"
run query -r 1:1-1 -f "$WORK/t88.fmt" "$WORK/main.vcf.gz" -o "$WORK/t88.fmt" --p_yes >/dev/null 2>&1; t88a=$?
echo "fmt" > "$WORK/t88.fmt"
run query -r 1:1-1 -f"$WORK/t88.fmt" "$WORK/main.vcf.gz" -o "$WORK/t88.fmt" --p_yes >/dev/null 2>&1; t88b=$?
if [ "$t88ser" = 0 ] && [ "$t88a" = 0 ] && [ "$t88b" = 0 ]; then
  ok "T88 query -f/--format string value is not mis-flagged as a file input"
else
  bad "T88 query -f carve-out" "serial=$t88ser sep=$t88a attached=$t88b (all should be 0)"
fi

# T89-T91 (stdout STREAM output must be byte-equal to serial, with wrapper diagnostics
# on STDERR only). Data on stdout, diagnostics on stderr — the standard CLI contract a
# pipe depends on. Serial reference:
t89ser=$(bcftools query -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" 2>/dev/null | _md5)

# T89: `-o -` (the stdout convention). Must NOT create a literal file named '-'
# (bcftools `query -o -` would), and must not leak the banner/progress into the data.
( cd "$WORK" && rm -f -- './-' )
t89par=$( ( cd "$WORK" && perl "$PBCF" query -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o - --p_yes 2>/dev/null ) | _md5)
if [ "$t89par" = "$t89ser" ] && [ ! -e "$WORK/-" ]; then
  ok "T89 '-o -' streams data to stdout (byte-equal, no log text, no literal '-' file)"
else
  bad "T89 stdout '-o -'" "md5 par=$t89par ser=$t89ser dashfile=$([ -e "$WORK/-" ] && echo yes || echo no)"
fi

# T90: `-o /dev/stdout` connected to a pipe — byte-equal, no wrapper text.
t90par=$(perl "$PBCF" query -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o /dev/stdout --p_yes 2>/dev/null | _md5)
if [ "$t90par" = "$t89ser" ]; then
  ok "T90 '-o /dev/stdout' piped is byte-equal to serial (no diagnostics on stdout)"
else
  bad "T90 stdout /dev/stdout pipe" "md5 par=$t90par ser=$t89ser"
fi

# T91: `-o /dev/stdout` while stdout is redirected to a REGULAR file (the case that
# made `-f /dev/stdout` true and previously tried to unlink live stdout).
perl "$PBCF" query -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o /dev/stdout --p_yes >"$WORK/t91.out" 2>/dev/null
t91rc=$?
if [ "$t91rc" = 0 ] && [ "$(_md5 < "$WORK/t91.out")" = "$t89ser" ]; then
  ok "T91 '-o /dev/stdout' > regular file is rc0 and byte-equal to serial"
else
  bad "T91 stdout /dev/stdout to file" "rc=$t91rc md5=$(_md5 < "$WORK/t91.out") want=$t89ser"
fi

# T92 (`index -o -` streams the index to STDOUT) index writes the index itself; to
# stdout it needs an explicit `-o -`. Omitting -o (the stream default for data
# commands) would silently write a sidecar and emit nothing — a command-unaware
# stdout bug. Must be nonempty, byte-equal to serial, and create no sidecar.
cp "$WORK/main.vcf.gz" "$WORK/t92.vcf.gz"; rm -f "$WORK/t92.vcf.gz.csi" "$WORK/t92.vcf.gz.tbi"
t92ser=$(bcftools index -o - "$WORK/t92.vcf.gz" 2>/dev/null | _md5)
rm -f "$WORK/t92.vcf.gz.csi"
perl "$PBCF" index -o - "$WORK/t92.vcf.gz" --p_yes >"$WORK/t92.out" 2>/dev/null
t92n=$(wc -c <"$WORK/t92.out" | tr -d ' ')
if [ "${t92n:-0}" -gt 0 ] && [ "$(_md5 < "$WORK/t92.out")" = "$t92ser" ] && [ ! -e "$WORK/t92.vcf.gz.csi" ]; then
  ok "T92 index -o - streams the index to stdout (nonempty, byte-equal, no sidecar)"
else
  bad "T92 index -o - stream" "bytes=$t92n sidecar=$([ -e "$WORK/t92.vcf.gz.csi" ] && echo yes || echo no)"
fi

# T93 (multi-positional single-input command must NOT be region-split) `query A B`
# with disjoint contigs: bcftools reads the FIRST operand, but the wrapper's contig
# discovery would pick the last and silently emit nothing. The fail-safe passes it
# through instead — output must equal serial (non-empty), not vanish.
bcftools view -r 1 "$WORK/main.vcf.gz" -Oz -o "$WORK/t93.A.vcf.gz" 2>/dev/null && bcftools index -f "$WORK/t93.A.vcf.gz"
bcftools view -r 2 "$WORK/main.vcf.gz" -Oz -o "$WORK/t93.B.vcf.gz" 2>/dev/null && bcftools index -f "$WORK/t93.B.vcf.gz"
t93ser=$(bcftools query -f '%CHROM\t%POS\n' "$WORK/t93.A.vcf.gz" "$WORK/t93.B.vcf.gz" 2>/dev/null | _md5)
run query -f '%CHROM\t%POS\n' "$WORK/t93.A.vcf.gz" "$WORK/t93.B.vcf.gz" -o "$WORK/t93.par" \
  --p_len 400KB --p_jobs 4 --p_yes >/dev/null 2>&1
t93rc=$?
t93n=$(grep -c . "$WORK/t93.par" 2>/dev/null || echo 0)
if [ "$t93rc" = 0 ] && [ "${t93n:-0}" -gt 0 ] && [ "$(_md5 < "$WORK/t93.par")" = "$t93ser" ] \
   && grep -qs "more than one positional" "$WORK/err.log"; then
  ok "T93 multi-positional single-input query -> passthrough, serial-equivalent (no silent drop)"
else
  bad "T93 multi-positional query" "rc=$t93rc n=$t93n md5match=$([ "$(_md5 < "$WORK/t93.par" 2>/dev/null)" = "$t93ser" ] && echo y || echo n)"
fi

# T94 (`query --vcf-list` reads multiple VCFs) must pass through, not region-split.
printf '%s\n%s\n' "$WORK/t93.A.vcf.gz" "$WORK/t93.B.vcf.gz" > "$WORK/t94.list"
t94ser=$(bcftools query -f '%CHROM\t%POS\n' --vcf-list "$WORK/t94.list" 2>/dev/null | _md5)
run query -f '%CHROM\t%POS\n' --vcf-list "$WORK/t94.list" -o "$WORK/t94.par" \
  --p_len 400KB --p_jobs 4 --p_yes >/dev/null 2>&1
t94rc=$?
if [ "$t94rc" = 0 ] && [ "$(_md5 < "$WORK/t94.par" 2>/dev/null)" = "$t94ser" ] \
   && grep -qs "vcf-list" "$WORK/err.log"; then
  ok "T94 query --vcf-list -> passthrough, serial-equivalent"
else
  bad "T94 query --vcf-list passthrough" "rc=$t94rc md5match=$([ "$(_md5 < "$WORK/t94.par" 2>/dev/null)" = "$t94ser" ] && echo y || echo n)"
fi

# T95 (multi-primary fail-safe is EXTENSION-AGNOSTIC) an extensionless indexed first
# input paired with a .vcf.gz second must STILL be detected as >1 primary and passed
# through. Preferring VCF-suffixed names would miss the extensionless one, pick the
# suffixed second for contig discovery, and silently drop the first file's data (same
# root as T93, mixed filenames).
bcftools view -r 1 "$WORK/main.vcf.gz" -Oz -o "$WORK/t95.first" 2>/dev/null && bcftools index -f "$WORK/t95.first"
bcftools view -r 2 "$WORK/main.vcf.gz" -Oz -o "$WORK/t95.second.vcf.gz" 2>/dev/null && bcftools index -f "$WORK/t95.second.vcf.gz"
t95ser=$(bcftools query -f '%CHROM\t%POS\n' "$WORK/t95.first" "$WORK/t95.second.vcf.gz" 2>/dev/null | _md5)
run query -f '%CHROM\t%POS\n' "$WORK/t95.first" "$WORK/t95.second.vcf.gz" -o "$WORK/t95.par" \
  --p_len 400KB --p_jobs 4 --p_yes >/dev/null 2>&1
t95rc=$?
t95n=$(grep -c . "$WORK/t95.par" 2>/dev/null || echo 0)
if [ "$t95rc" = 0 ] && [ "${t95n:-0}" -gt 0 ] && [ "$(_md5 < "$WORK/t95.par")" = "$t95ser" ] \
   && grep -qs "more than one positional" "$WORK/err.log"; then
  ok "T95 multi-primary fail-safe is extension-agnostic (extensionless + .vcf.gz)"
else
  bad "T95 extension-agnostic multi-primary" "rc=$t95rc n=$t95n md5match=$([ "$(_md5 < "$WORK/t95.par" 2>/dev/null)" = "$t95ser" ] && echo y || echo n)"
fi

# T96 (--p_ref bounds an unknown contig length for multi-input merge) REGRESSION:
# the release refactor's contig-set consistency guard resolved unknown ('.')
# lengths from --p_fai ONLY, so a human merge relying on the built-in --p_ref table
# (no external .fai) wrongly failed closed. --p_ref must bound the unknown length
# exactly like --p_fai (T40) so a later record beyond the first file's header is
# not omitted. Fixtures unk_a/unk_b use bare contig '1' (in the --p_ref table).
s96=$(bcftools merge "$WORK/unk_a.vcf.gz" "$WORK/unk_b.vcf.gz" 2>/dev/null | bcftools view -H 2>/dev/null | awk '{print $2}' | tr '\n' ',')
run merge "$WORK/unk_a.vcf.gz" "$WORK/unk_b.vcf.gz" --p_ref 38 -Oz -o "$WORK/t96.vcf.gz" --p_jobs 2 --p_yes
p96=$(bcftools view -H "$WORK/t96.vcf.gz" 2>/dev/null | awk '{print $2}' | tr '\n' ',')
{ [ "$s96" = "$p96" ] && echo "$p96" | grep -q '500'; } \
  && ok "T96 --p_ref bounds unknown length ($p96)" \
  || bad "T96 --p_ref bound" "serial=$s96 parallel=$p96"

# T97 (valid-but-empty region contig must NOT be mistaken for a typo) a contig
# declared in the header (or a known --p_fai/--p_ref reference contig) that carries
# no records here is valid: region-splitting over it yields empty output (or, for
# multi-input merge, captures a LATER file's records), never a fail-closed stop.
# A contig in NEITHER the index nor the header/--p_ref is still a typo -> croak.
{ echo '##fileformat=VCFv4.2'; echo '##contig=<ID=1,length=1000000>'; echo '##contig=<ID=3,length=500000>';
  echo '##FORMAT=<ID=GT,Number=1,Type=String,Description="gt">';
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\n';
  printf '1\t100\t.\tA\tG\t.\tPASS\t.\tGT\t0/1\n'; } > "$WORK/emptyc.vcf"
bgzip -f "$WORK/emptyc.vcf"; bcftools index -f "$WORK/emptyc.vcf.gz"
t97ser=$(bcftools view -H -r 1,3 "$WORK/emptyc.vcf.gz" 2>/dev/null | _md5)
run view -r 1,3 "$WORK/emptyc.vcf.gz" -Oz -o "$WORK/t97.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t97rc=$?
t97par=$(bcftools view -H "$WORK/t97.vcf.gz" 2>/dev/null | _md5)
run view -r 1,7 "$WORK/emptyc.vcf.gz" -Oz -o "$WORK/t97b.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t97brc=$?
{ [ "$t97rc" = 0 ] && [ "$t97ser" = "$t97par" ] && [ "$t97brc" != 0 ]; } \
  && ok "T97 empty-but-valid region contig accepted; typo still fails closed" \
  || bad "T97 empty-contig region" "accept_rc=$t97rc match=$([ "$t97ser" = "$t97par" ] && echo y || echo n) typo_rc=$t97brc"

# T98 (roh runs in CHROMOSOME mode and assembles correctly) roh is an HMM whose
# state carries along a contig but is independent BETWEEN contigs, so it splits
# per whole chromosome and is never sub-divided. The assembler must (a) emit ONE
# header block, not one per contig, and (b) tolerate that each chunk's
# "# The command line was:" echoes that chunk's own -r. Data must equal serial.
t98ser="$WORK/t98.ser"; t98par="$WORK/t98.par"
bcftools roh --AF-dflt 0.4 -G30 "$WORK/main.vcf.gz" > "$t98ser" 2>/dev/null
run roh --AF-dflt 0.4 -G30 "$WORK/main.vcf.gz" -o "$t98par" --p_jobs 2 --p_yes
t98rc=$?
t98hs=$(grep -c '^#' "$t98ser" 2>/dev/null || echo 0)
t98hp=$(grep -c '^#' "$t98par" 2>/dev/null || echo 0)
if [ "$t98rc" = 0 ] \
   && diff <(grep -v '^# The command line was:' "$t98ser") \
           <(grep -v '^# The command line was:' "$t98par") >/dev/null 2>&1 \
   && [ "$t98hs" = "$t98hp" ]; then
  ok "T98 roh chromosome-mode == serial (one header block: $t98hp)"
else
  bad "T98 roh chromosome-mode" "rc=$t98rc hdr_serial=$t98hs hdr_par=$t98hp"
fi

# T99 (cnv runs SERIALLY and must not disturb its output) cnv writes a DIRECTORY of
# sample-named files (summary.tab, dat.<s>.tab, cn.<s>.tab, plot.<s>.py) whose names
# carry no contig. Parallelising it meant giving each contig its own subdirectory --
# a layout that differed from serial by design, and a whole third output kind with
# its own publication, path-rebinding and rerun rules. pbcftools now passes cnv
# straight to bcftools, so the only thing to assert is the thing that matters: the
# output is byte-identical to a direct bcftools run, in the same flat layout.
t99ser="$WORK/t99.ser"; t99par="$WORK/t99.par"; rm -rf "$t99ser" "$t99par"
mkdir -p "$t99ser" "$t99par"
bcftools cnv -s S1 "$WORK/main.vcf.gz" -o "$t99ser" >/dev/null 2>&1
run cnv -s S1 "$WORK/main.vcf.gz" -o "$t99par" --p_jobs 2 --p_yes
t99rc=$?
t99sern=$(find "$t99ser" -type f | wc -l | tr -d ' ')
t99parn=$(find "$t99par" -type f | wc -l | tr -d ' ')
t99dirs=$(find "$t99par" -mindepth 1 -type d | wc -l | tr -d ' ')
# The two runs are necessarily given DIFFERENT -o directories, and bcftools writes
# that path into its output: into `# The command line was:` in summary.tab, and as
# absolute paths inside plot.<sample>.py. Normalise the destination to a placeholder
# on both sides; everything else must then be byte-identical.
t99diff=ok
for f in "$t99ser"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ -e "$t99par/$b" ] || { t99diff="missing: $b"; continue; }
    cmp -s <(sed "s|$t99ser|@OUTDIR@|g" "$f") \
           <(sed "s|$t99par|@OUTDIR@|g" "$t99par/$b") \
      || t99diff="differs: $b"
done
{ [ "$t99rc" = 0 ] && [ "$t99sern" = "$t99parn" ] && [ "$t99sern" != 0 ] \
  && [ "$t99dirs" = 0 ] && [ "$t99diff" = ok ]; } \
  && ok "T99 cnv passthrough == serial ($t99parn files, flat layout)" \
  || bad "T99 cnv passthrough" "rc=$t99rc ser=$t99sern par=$t99parn dirs=$t99dirs $t99diff"

# T100 (USER-SPECIFIED -r with chromosome-mode commands) a user region must work
# and must NOT be sub-divided even when --p_len is small: sub-splitting an HMM
# result reports one run as two truncated, overlapping segments. Covers a
# sub-contig region, two intervals on the SAME contig (which must coalesce into
# one worker so the HMM sees them as one call), and a cross-contig pair.
t100fail=""
for spec in "1:100000-900000|--p_len 100KB" "1:100000-400000,1:600000-900000|" "1:200000-800000,2:200000-800000|"; do
  reg="${spec%%|*}"; extra="${spec##*|}"
  bcftools roh --AF-dflt 0.4 -G30 -r "$reg" "$WORK/main.vcf.gz" > "$WORK/t100.ser" 2>/dev/null
  run roh --AF-dflt 0.4 -G30 -r "$reg" "$WORK/main.vcf.gz" -o "$WORK/t100.par" $extra --p_jobs 4 --p_yes
  [ $? = 0 ] || { t100fail="$t100fail rc[$reg]"; continue; }
  diff <(grep -v '^# The command line was:' "$WORK/t100.ser") \
       <(grep -v '^# The command line was:' "$WORK/t100.par") >/dev/null 2>&1 \
    || t100fail="$t100fail differs[$reg]"
done
[ -z "$t100fail" ] && ok "T100 roh honors user -r (no sub-split even with small --p_len)" \
                   || bad "T100 roh user -r" "$t100fail"

# T101 (output header is bcftools-comparable) `concat --naive` inherits the FIRST
# chunk's header, whose ##bcftools_<cmd>Command records that chunk's injected -r
# and its temp -o — verbatim that advertises a fraction of the file and a path
# that no longer exists. The line must instead read as a DIRECT bcftools run:
#   (a) no pbcftools temp path, (b) the USER's -r when given and NO -r when not,
#   (c) the real output path, (d) ##pbcftools_command still present,
#   (e) no ##bcftools_view* artifact from our internal header read.
t101="$WORK/t101"; rm -f "$t101".*.vcf.gz
_t101hdr() { bgzip -dc "$1" 2>/dev/null | sed -n '/^#CHROM/q;p'; }
run view "$WORK/main.vcf.gz" -Oz -o "$t101.nor.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
run view -r 1:100000-900000 "$WORK/main.vcf.gz" -Oz -o "$t101.reg.vcf.gz" --p_jobs 2 --p_len 200KB --p_yes
h_nor="$(_t101hdr "$t101.nor.vcf.gz")"; h_reg="$(_t101hdr "$t101.reg.vcf.gz")"
t101fail=""
echo "$h_nor$h_reg" | grep -qE 'pbcf[0-9]{4}\.|\.par\.vcf\.gz'        && t101fail="$t101fail temp-path-leak"
echo "$h_nor$h_reg" | grep -q '^##bcftools_viewCommand=view -h'          && t101fail="$t101fail view-h-artifact"
echo "$h_nor" | grep '^##bcftools_viewCommand=' | grep -q -- '-r '       && t101fail="$t101fail spurious-r"
echo "$h_reg" | grep '^##bcftools_viewCommand=' | grep -q -- '-r 1:100000-900000' || t101fail="$t101fail missing-user-r"
echo "$h_nor" | grep -q "^##bcftools_viewCommand=.*$t101.nor.vcf.gz"     || t101fail="$t101fail wrong-output-path"
echo "$h_nor" | grep -q '^##pbcftools_command='                          || t101fail="$t101fail no-pbcftools-line"
[ -z "$t101fail" ] && ok "T101 output header reads as a direct bcftools run" \
                   || bad "T101 header provenance" "$t101fail"

# T102 (serial vs parallel header consistency) The output header must differ from
# a direct bcftools run in EXACTLY two ways:
#   1. ##bcftools_<cmd>Command — identical except the trailing "; Date=...".
#      Both runs use the SAME -o, so the recorded output path must match exactly;
#   2. ##pbcftools_command — present in parallel only.
# Everything else (contigs, FILTER/INFO/FORMAT, sample line, other ## lines) must
# match line for line. bcftools parses with getopt_long, which permutes argv so
# positionals move to the end; pbcftools must replicate that or the Command lines
# differ by argument order alone.
_t102norm() { # strip ONLY the trailing "; Date=..." — nothing else is normalized
  bgzip -dc "$1" 2>/dev/null | sed -n '/^#CHROM/q;p' | sed -e 's/; Date=.*$//'
}
t102fail=""
for spec in "view|-r 1:100000-900000" "filter|-i QUAL>0" "norm|-m -both" "annotate|-x INFO/AF"; do
  cmd="${spec%%|*}"; extra="${spec##*|}"
  # BOTH runs write to the SAME -o path, so the recorded output filename is
  # literally identical and needs no normalization; only Date= may differ.
  out="$WORK/t102.out.vcf.gz"
  rm -f "$out"
  bcftools $cmd $extra "$WORK/main.vcf.gz" -Oz -o "$out" 2>/dev/null || { t102fail="$t102fail serial-rc[$cmd]"; continue; }
  _t102norm "$out" > "$WORK/t102.ser.hdr"
  _t102norm "$out" | grep -q '^##pbcftools_command=' && t102fail="$t102fail pbcf-line-in-serial[$cmd]"
  rm -f "$out"
  run $cmd $extra "$WORK/main.vcf.gz" -Oz -o "$out" --p_jobs 2 --p_len 400KB --p_yes \
    || { t102fail="$t102fail par-rc[$cmd]"; continue; }
  _t102norm "$out" > "$WORK/t102.par.hdr"
  # (2) the pbcftools line: parallel only
  grep -q '^##pbcftools_command=' "$WORK/t102.par.hdr" || t102fail="$t102fail no-pbcf-line[$cmd]"
  # (1) everything else must match line for line, -o path included
  d=$(diff "$WORK/t102.ser.hdr" <(grep -v '^##pbcftools_command=' "$WORK/t102.par.hdr") | grep -c '^[<>]')
  [ "${d:-1}" -eq 0 ] || t102fail="$t102fail hdr-diff[$cmd:$d]"
done
[ -z "$t102fail" ] && ok "T102 par header == serial except Date + ##pbcftools_command" \
                   || bad "T102 header consistency" "$t102fail"

# T103 (short-option BUNDLES must not hide -r/-O) bcftools accepts GNU bundling:
# `-ur1:1-50000` is `-u -r 1:1-50000`, `-aOb` is `-a -O b`. pbcftools classified
# args by token PREFIX, so a bundled -r was invisible (it injected its own, and
# bcftools' last-region-wins silently DISCARDED the user's restriction) and a
# bundled -O b was missed (BCF pushed through the TEXT assembler). Both returned
# exit 0 with wrong output. Now bundles are expanded from `bcftools <cmd> --help`
# arity, or the run falls back to serial bcftools.
t103fail=""
b_ser=$(bcftools query -ur1:100000-400000 -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run query -ur1:100000-400000 -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t103a.txt" --p_jobs 2 --p_len 100KB --p_yes
b_par=$(wc -l < "$WORK/t103a.txt" 2>/dev/null | tr -d ' ')
[ "${b_ser:-0}" -gt 0 ] && [ "$b_ser" = "$b_par" ] || t103fail="$t103fail bundled-r[ser=$b_ser par=$b_par]"
# bundled -O b with a NEUTRAL output name (a .bcf name would let extension
# inference mask the bug — that is exactly how it was first missed).
bcftools view -aOb "$WORK/main.vcf.gz" -o "$WORK/t103.ser.out" 2>/dev/null
o_ser=$(bcftools view -H "$WORK/t103.ser.out" 2>/dev/null | wc -l | tr -d ' ')
run view -aOb "$WORK/main.vcf.gz" -o "$WORK/t103.par.out" --p_jobs 2 --p_len 400KB --p_yes
o_par=$(bcftools view -H "$WORK/t103.par.out" 2>/dev/null | wc -l | tr -d ' ')
[ "${o_ser:-0}" -gt 0 ] && [ "$o_ser" = "$o_par" ] || t103fail="$t103fail bundled-O[ser=$o_ser par=$o_par]"
[ -z "$t103fail" ] && ok "T103 bundled short options == serial (-ur.., -aOb)" \
                   || bad "T103 short-option bundles" "$t103fail"

# T104 (brace contig spelling is the SAME contig) `1` and `{1}` name one contig.
# Grouping keyed on the literal token made them two groups whose intervals then
# overlapped, emitting DUPLICATE records (and restarting roh's HMM on one contig).
c_ser=$(bcftools query -r '1:100000-400000,{1}:300000-600000' -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
run query -r '1:100000-400000,{1}:300000-600000' -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$WORK/t104.txt" --p_jobs 2 --p_len 100KB --p_yes
c_par=$(wc -l < "$WORK/t104.txt" 2>/dev/null | tr -d ' ')
{ [ "${c_ser:-0}" -gt 0 ] && [ "$c_ser" = "$c_par" ]; } \
  && ok "T104 brace contig spelling not duplicated ($c_par)" \
  || bad "T104 brace contig spelling" "serial=$c_ser parallel=$c_par"

# T105 (text output is PUBLISHED ONLY ON SUCCESS) text was appended straight to
# the user's -o as chunks finished, so a SIGTERM left a plausible truncated
# result at the requested path (69k of 615k lines in the reported case). It is
# now assembled in --p_dir and renamed into place only after every chunk passes.
t105out="$WORK/t105.txt"; rm -f "$t105out"
perl "$PBCF" query -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$t105out" \
     --p_jobs 1 --p_len 50KB --p_yes >/dev/null 2>&1 &
t105pid=$!
sleep 2; kill -TERM $t105pid 2>/dev/null; wait $t105pid 2>/dev/null
if [ -e "$t105out" ]; then
  bad "T105 text published only on success" "partial output left at -o ($(wc -l < "$t105out") lines)"
else
  ok "T105 interrupted run leaves no partial text output"
fi

# T106 (a file-list MEMBER is an input too) `query -v/--vcf-list` reads a
# file-of-filenames. The alias guard expanded list members only via the bounded
# ArgParser, which has no schema for query — so naming the output after one of the
# listed VCFs DESTROYED that input. Data loss, exit 255, no warning.
t106d="$WORK/t106"; rm -rf "$t106d"; mkdir -p "$t106d"
cp "$WORK/main.vcf.gz" "$t106d/m1.vcf.gz"; cp "$WORK/main.vcf.gz.csi" "$t106d/m1.vcf.gz.csi"
printf '%s\n' "$t106d/m1.vcf.gz" > "$t106d/list.txt"
t106ck=$(_md5 < "$t106d/m1.vcf.gz")
run query --vcf-list "$t106d/list.txt" -f '%CHROM\t%POS\n' -o "$t106d/m1.vcf.gz" --p_yes
t106rc=$?
if [ "$(_md5 < "$t106d/m1.vcf.gz")" = "$t106ck" ] && [ "$t106rc" != 0 ] \
   && grep -qs 'same file' "$WORK/err.log"; then
  ok "T106 --vcf-list member protected from being overwritten"
else
  bad "T106 vcf-list member alias" "rc=$t106rc intact=$([ "$(_md5 < "$t106d/m1.vcf.gz")" = "$t106ck" ] && echo y || echo N)"
fi

# T107 (uncompressed VCF assembly adds no header of its own) BGZF uses
# `concat --naive`, which stamps nothing; UNCOMPRESSED VCF uses plain `concat`,
# which appended ##bcftools_concatVersion/Command — including the internal
# file-list temp path — two header lines a direct bcftools run never has.
bcftools view -Ov -r 1:100000-900000 "$WORK/main.vcf.gz" -o "$WORK/t107.ser" 2>/dev/null
run view -Ov -r 1:100000-900000 "$WORK/main.vcf.gz" -o "$WORK/t107.par" --p_jobs 2 --p_len 200KB --p_yes
t107b=$(diff <(grep -v '^#' "$WORK/t107.ser") <(grep -v '^#' "$WORK/t107.par") >/dev/null 2>&1 && echo same || echo DIFF)
t107c=$(grep -c '^##bcftools_concat' "$WORK/t107.par" 2>/dev/null | tr -d ' ')
{ [ "$t107b" = same ] && [ "${t107c:-1}" -eq 0 ]; } \
  && ok "T107 -Ov assembly leaves no concat stamp; body == serial" \
  || bad "T107 -Ov header/body" "body=$t107b concat_lines=$t107c"

# T108 (long-option ABBREVIATIONS must not bypass the destructive-output guard)
# bcftools uses getopt_long, which accepts any unambiguous prefix: `--vcf-l` IS
# `--vcf-list`. Every guard compared spellings, so the abbreviation walked past
# all of them and bcftools truncated the list member to 0 bytes at exit 255.
t108d="$WORK/t108"; mkdir -p "$t108d"
cp "$WORK/main.vcf.gz" "$t108d/m1.vcf.gz"; cp "$WORK/main.vcf.gz.csi" "$t108d/m1.vcf.gz.csi"
printf '%s\n' "$t108d/m1.vcf.gz" > "$t108d/list.txt"
t108ck=$(_md5 < "$t108d/m1.vcf.gz")
run query "--vcf-l=$t108d/list.txt" -f '%CHROM\t%POS\n' -o "$t108d/m1.vcf.gz" --p_yes
t108rc=$?
if [ "$(_md5 < "$t108d/m1.vcf.gz")" = "$t108ck" ] && [ "$t108rc" != 0 ]; then
  ok "T108 abbreviated --vcf-l= still hits the alias guard; member intact"
else
  bad "T108 long-option abbreviation guard" \
      "rc=$t108rc intact=$([ "$(_md5 < "$t108d/m1.vcf.gz")" = "$t108ck" ] && echo y || echo N)"
fi

# T109 (stdin-valued options: '=' form, abbreviation, and the '^' EXCLUDE prefix)
# `-S ^-` still reads the sample list from stdin — '^' is bcftools' negation
# marker, not part of the name. Missing that, every worker read EOF and
# `view -S^-` returned ALL samples in parallel vs. the correct subset serially,
# at exit 0. Each spelling must reproduce the serial sample set exactly.
printf 'S1\n' > "$WORK/t109.samp"
t109fail=""
for spec in "-S -" "-S^-" "--samples-f=-" "--samples-file=^-"; do
  # shellcheck disable=SC2086
  t109s=$(bcftools view $spec "$WORK/main.vcf.gz" -Ov < "$WORK/t109.samp" 2>/dev/null \
          | grep -m1 '^#CHROM' | cut -f10-)
  # shellcheck disable=SC2086
  perl "$PBCF" view $spec "$WORK/main.vcf.gz" -Ov -o "$WORK/t109.par" --p_yes \
       < "$WORK/t109.samp" >/dev/null 2>"$WORK/err.log"
  t109p=$(grep -m1 '^#CHROM' "$WORK/t109.par" 2>/dev/null | cut -f10-)
  [ "$t109s" = "$t109p" ] || t109fail="$t109fail [$spec ser='$t109s' par='$t109p']"
  rm -f "$WORK/t109.par"
done
[ -z "$t109fail" ] \
  && ok "T109 stdin sample-file spellings (=, abbrev, ^) match serial" \
  || bad "T109 stdin option spellings" "$t109fail"

# T110 (a FAILED run must not destroy the user's PREVIOUS output) The
# incomplete-run guard unlinked -o, a leftover from when text appended straight
# to the destination. Text now stages in --p_dir, so that unlink only ever
# deleted a valid earlier result and wrote nothing in its place.
t110d="$WORK/t110"; mkdir -p "$t110d/fb"
cat > "$t110d/fb/bcftools" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in 1:*|2:*) echo "injected chunk failure" >&2; exit 42;; esac; done
exec $(command -v bcftools) "\$@"
EOF
chmod +x "$t110d/fb/bcftools"
printf 'PRIOR VALID RESULT\n' > "$t110d/prior.txt"
t110ck=$(_md5 < "$t110d/prior.txt")
PATH="$t110d/fb:$PATH" perl "$PBCF" query "$WORK/main.vcf.gz" -f '%CHROM\t%POS\n' \
     -o "$t110d/prior.txt" --p_jobs 2 --p_len 200KB --p_yes >/dev/null 2>"$WORK/err.log"
t110rc=$?
{ [ "$t110rc" != 0 ] && [ -e "$t110d/prior.txt" ] && [ "$(_md5 < "$t110d/prior.txt")" = "$t110ck" ]; } \
  && ok "T110 failed run leaves the pre-existing -o untouched" \
  || bad "T110 failed run clobbered -o" \
         "rc=$t110rc exists=$([ -e "$t110d/prior.txt" ] && echo y || echo N)"

# T111 (a failed INDEX must not destroy the previous output either) Indexing ran
# AFTER the destination had been replaced, so an index failure unlinked both the
# new output and the user's old one — leaving nothing at all. The index is now
# built on the staged file, before -o is touched.
t111d="$WORK/t111"; mkdir -p "$t111d/fb"
# Fail only real index CREATION. `bcftools index -s`/-n are read-only probes used
# during preflight; failing those too would abort the run before it ever reaches
# the staged-index step, so the test would pass without exercising the fix.
cat > "$t111d/fb/bcftools" <<EOF
#!/usr/bin/env bash
if [ "\$1" = index ] && [ "\${2:-}" != "-s" ] && [ "\${2:-}" != "-n" ]; then
    echo "injected index-CREATE failure" >&2; exit 43
fi
exec $(command -v bcftools) "\$@"
EOF
chmod +x "$t111d/fb/bcftools"
cp "$WORK/main.vcf.gz" "$t111d/out.vcf.gz"
t111ck=$(_md5 < "$t111d/out.vcf.gz")
PATH="$t111d/fb:$PATH" perl "$PBCF" view "$WORK/main.vcf.gz" -Oz -o "$t111d/out.vcf.gz" \
     --p_jobs 2 --p_len 200KB --p_yes >/dev/null 2>"$WORK/err.log"
t111rc=$?
# Require the failure to come from the STAGED-INDEX step specifically, so the test
# cannot pass by aborting somewhere earlier.
t111where=$(grep -qi 'Indexing the merged output failed' "$WORK/err.log" && echo staged || echo elsewhere)
{ [ "$t111rc" != 0 ] && [ "$t111where" = staged ] && [ -e "$t111d/out.vcf.gz" ] \
  && [ "$(_md5 < "$t111d/out.vcf.gz")" = "$t111ck" ]; } \
  && ok "T111 failed index leaves the pre-existing -o untouched" \
  || bad "T111 failed index clobbered -o" \
         "rc=$t111rc where=$t111where exists=$([ -e "$t111d/out.vcf.gz" ] && echo y || echo N)"

# T112 (publishing a TEXT result must not delete an unrelated .csi sidecar) The
# shared publisher dropped "$dst.csi"/".tbi" unconditionally to clear the stale
# index of a replaced VCF. For stats/query/roh text output a same-named .csi
# belongs to something else, and a SUCCESSFUL run silently destroyed it.
t112d="$WORK/t112"; mkdir -p "$t112d"
printf 'unrelated sidecar payload\n' > "$t112d/res.txt.csi"
t112ck=$(_md5 < "$t112d/res.txt.csi")
run query "$WORK/main.vcf.gz" -f '%CHROM\t%POS\n' -o "$t112d/res.txt" --p_jobs 2 --p_len 200KB --p_yes
t112rc=$?
{ [ "$t112rc" = 0 ] && [ "$(_md5 < "$t112d/res.txt.csi" 2>/dev/null)" = "$t112ck" ]; } \
  && ok "T112 text publish preserves an unrelated .csi sidecar" \
  || bad "T112 text publish ate a sidecar" "rc=$t112rc"

# T113 (isec: -O selects a format only WITH -w) Without -w/--write, `isec` prints
# the tab-delimited sites list whatever -O says, so `isec -n =2 -Ov -o sites.txt`
# was routed to the VCF concat path and died there (exit 255) on a command that
# works serially. -W/--write-index must not be mistaken for -w.
t113d="$WORK/t113"; mkdir -p "$t113d"
bcftools view -r 1:1-500000 "$WORK/main.vcf.gz" -Oz -o "$t113d/s2.vcf.gz" 2>/dev/null
bcftools index -f "$t113d/s2.vcf.gz" 2>/dev/null
t113fail=""
for ot in v z b u; do
  bcftools isec -n =2 -O $ot -o "$t113d/ser.$ot" "$WORK/main.vcf.gz" "$t113d/s2.vcf.gz" >/dev/null 2>&1
  run isec -n =2 -O $ot -o "$t113d/par.$ot" "$WORK/main.vcf.gz" "$t113d/s2.vcf.gz" \
      --p_jobs 2 --p_len 200KB --p_yes
  t113rc=$?
  { [ "$t113rc" = 0 ] && cmp -s "$t113d/ser.$ot" "$t113d/par.$ot"; } \
    || t113fail="$t113fail [-O$ot rc=$t113rc]"
done
[ -z "$t113fail" ] \
  && ok "T113 isec without -w is text for every -O; body == serial" \
  || bad "T113 isec -O without -w" "$t113fail"

# T114 (an AMBIGUOUS long prefix must fail exactly like serial) The abbreviation
# resolver judged uniqueness against the structured arity map, which silently
# drops help shapes it cannot parse ("-W, --write-index[=FMT]", "-c/C,
# --min-ac/--max-ac", "-f,   --apply-filters"). Names missing from that map made a
# genuinely ambiguous prefix look unique, so pbcftools resolved `--w` to `--write`
# and SUCCEEDED where bcftools errors — and when the wrongly chosen option takes a
# value it swallowed the next argv token, which was an input file.
t114d="$WORK/t114"; mkdir -p "$t114d"
bcftools view -r 1:1-500000 "$WORK/main.vcf.gz" -Oz -o "$t114d/b.vcf.gz" 2>/dev/null
bcftools index -f "$t114d/b.vcf.gz" 2>/dev/null
t114fail=""
# each: subcommand, ambiguous prefix, and the args that follow
_t114() {   # $1=desc  rest=argv
  local desc="$1"; shift
  bcftools "$@" >/dev/null 2>&1; local sr=$?
  perl "$PBCF" "$@" --p_jobs 2 --p_len 200KB --p_yes >/dev/null 2>&1; local pr=$?
  # both must fail, or both must succeed — never "serial errors, parallel invents"
  if [ "$sr" = 0 ] && [ "$pr" != 0 ]; then t114fail="$t114fail [$desc ser=$sr par=$pr]"; fi
  if [ "$sr" != 0 ] && [ "$pr" = 0 ]; then t114fail="$t114fail [$desc ser=$sr par=$pr]"; fi
}
_t114 "isec --w"      isec --w 1 -n=2 -Oz -o "$t114d/i.out" "$WORK/main.vcf.gz" "$t114d/b.vcf.gz"
_t114 "view --w"      view --w "$WORK/main.vcf.gz" -Oz -o "$t114d/v.vcf.gz"
_t114 "view --regions-" view --regions- 1 "$WORK/main.vcf.gz" -Oz -o "$t114d/r.vcf.gz"
[ -z "$t114fail" ] \
  && ok "T114 ambiguous long prefixes fail closed, as serial does" \
  || bad "T114 ambiguous prefix resolved" "$t114fail"

# T115 (provenance permutation must survive abbreviations and a first-position
# input) The recorded ##bcftools_*Command is rebuilt from the ORIGINAL argv and
# permuted like getopt_long. Two defects corrupted it: the permuter never saw
# long-option arity (so an abbreviated option's FILE value was mistaken for a
# positional and moved to the end), and it was handed an array whose subcommand
# had already been shifted off — hiding the first real argument from the scan.
t115d="$WORK/t115"; mkdir -p "$t115d"
printf 'S1\n' > "$t115d/s.txt"
_t115hdr() { bcftools view -h "$1" 2>/dev/null | grep -m1 '^##bcftools_viewCommand' | sed 's/; Date=.*//'; }
t115fail=""
# (a) abbreviated value-taking option; (b) input given FIRST
bcftools view -Oz --samples-f "$t115d/s.txt" -o "$t115d/a.vcf.gz" "$WORK/main.vcf.gz" 2>/dev/null
t115sa=$(_t115hdr "$t115d/a.vcf.gz")
run view -Oz --samples-f "$t115d/s.txt" "$WORK/main.vcf.gz" -o "$t115d/a.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t115pa=$(_t115hdr "$t115d/a.vcf.gz")
[ "$t115sa" = "$t115pa" ] || t115fail="$t115fail [abbrev]"
bcftools view -Oz -o "$t115d/b.vcf.gz" "$WORK/main.vcf.gz" 2>/dev/null
t115sb=$(_t115hdr "$t115d/b.vcf.gz")
run view "$WORK/main.vcf.gz" -Oz -o "$t115d/b.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t115pb=$(_t115hdr "$t115d/b.vcf.gz")
[ "$t115sb" = "$t115pb" ] || t115fail="$t115fail [first-pos]"
[ -z "$t115fail" ] \
  && ok "T115 provenance permutation matches serial (abbrev + first-position input)" \
  || bad "T115 provenance permutation" "$t115fail"

# T119 (a failed index INSTALL must not report success) The index is built on the
# staged file, so reaching this point proves the data are sorted and valid — but
# publication already removed the replaced output's stale index, so exit 0 would
# promise an index that is absent and break downstream indexed access.
t119d="$WORK/t119"; mkdir -p "$t119d"
run view "$WORK/main.vcf.gz" -Oz -o "$t119d/o.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1
# make the destination .csi path unusable: a non-empty DIRECTORY cannot be replaced
rm -f "$t119d/o.vcf.gz.csi"; mkdir -p "$t119d/o.vcf.gz.csi/blocker"
run view "$WORK/main.vcf.gz" -Oz -o "$t119d/o.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t119rc=$?
# Count records by READING the file, not via `bcftools index -n` — the index is
# precisely what is missing here, so an index-based count would fail by design.
t119data=$(bcftools view -H "$t119d/o.vcf.gz" 2>/dev/null | wc -l | tr -d ' ')
rm -rf "$t119d/o.vcf.gz.csi"
{ [ "$t119rc" != 0 ] && [ "${t119data:-0}" = "$N_TOTAL" ]; } \
  && ok "T119 failed index install reports failure but keeps valid data ($t119data records)" \
  || bad "T119 index install failure reported success" \
         "rc=$t119rc records=$t119data want=$N_TOTAL"

# T121 (pbcftools must not claim option spellings it does not own) pbcftools options
# used to be --pjobs, --pref, ... and `--pref` was simultaneously OURS and a valid
# abbreviation of bcftools' `isec --prefix`. We consumed it plus the FOLLOWING argv
# token — an INPUT FILE — so `isec -n =2 -p DIR --pref A B` exited 0 having silently
# dropped input A and intersected a single file, where serial bcftools exits 255.
# Wrong output at exit 0, the worst class.
#
# Now structural rather than guarded: every pbcftools option is --p_<name>, and no
# bcftools long option contains an underscore, so no bcftools option can have
# "p_..." as a prefix. --pref, --pre and --pr all belong to bcftools now and must
# behave exactly as they do serially.
t121d="$WORK/t121"; mkdir -p "$t121d"
bcftools view -r 1:1-500000 "$WORK/main.vcf.gz" -Oz -o "$t121d/b.vcf.gz" 2>/dev/null
bcftools index -f "$t121d/b.vcf.gz" 2>/dev/null
t121fail=""
for ab in --pref --pre --pr; do
  rm -rf "$t121d/s" "$t121d/p"
  bcftools isec -n =2 -p "$t121d/s" $ab "$WORK/main.vcf.gz" "$t121d/b.vcf.gz" >/dev/null 2>&1
  t121s=$?
  perl "$PBCF" isec -n =2 -p "$t121d/p" $ab "$WORK/main.vcf.gz" "$t121d/b.vcf.gz" --p_yes \
       >/dev/null 2>"$WORK/err.log"
  t121p=$?
  # serial rejects these; parallel must too — never "serial fails, parallel invents"
  { [ "$t121s" != 0 ] && [ "$t121p" != 0 ]; } || t121fail="$t121fail [$ab ser=$t121s par=$t121p]"
done
# and the real pbcftools options, spelled in full, must still be consumed
perl "$PBCF" view "$WORK/main.vcf.gz" -Oz -o "$t121d/ok.vcf.gz" \
     --p_ref 37 --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1
[ "$?" = 0 ] || t121fail="$t121fail [full-names-broken]"
[ -z "$t121fail" ] \
  && ok "T121 pbcftools options do not shadow bcftools abbreviations" \
  || bad "T121 option-namespace collision" "$t121fail"

# T123 (the pbcftools namespace is disjoint from bcftools' by construction) This
# used to assert that an ambiguity GUARD refused the colliding spelling. The guard is
# gone: pbcftools options are --p_<name>, and since no bcftools long option contains
# an underscore, no bcftools option can have "p_..." as a prefix. So the property is
# now checked directly — no pbcftools option name may be an exact match for, or a
# prefix of, any long option of any bcftools subcommand.
t123bad=""
for sub in view query merge isec norm annotate filter stats roh cnv concat csq index sort; do
  bcftools "$sub" --help 2>&1 \
    | grep -oE -- '--[a-zA-Z0-9][a-zA-Z0-9_-]*' | sed 's/^--//' | sort -u
done | sort -u > "$WORK/t123.bcfopts"
for ours in p_mode p_jobs p_len p_dir p_pre p_ref p_fai p_yes p_verbose p_wal \
            p_mem p_cpu p_int p_try p_mem_inc p_wal_inc p_queue p_account; do
  # any bcftools option that starts with our name would make our name an abbreviation
  if grep -qE "^${ours}" "$WORK/t123.bcfopts"; then
    t123bad="$t123bad [$ours]"
  fi
done
t123n=$(wc -l < "$WORK/t123.bcfopts" | tr -d ' ')
# and an underscore must genuinely be absent from bcftools' namespace
t123u=$(grep -c '_' "$WORK/t123.bcfopts" | tr -d ' ')
{ [ -z "$t123bad" ] && [ "${t123u:-1}" -eq 0 ] && [ "${t123n:-0}" -ge 100 ]; } \
  && ok "T123 pbcftools namespace disjoint from bcftools ($t123n options, 0 with '_')" \
  || bad "T123 namespace collision possible" \
         "collides=$t123bad bcftools_opts_with_underscore=$t123u scanned=$t123n"

# T124 (an index destination we cannot write must be rejected BEFORE the data are
# published) Data and index are two renames and cannot be one transaction, so an
# index install that fails after publication leaves the user's previous output
# already REPLACED by a failed rerun. The only fix is to refuse up front.
t124d="$WORK/t124"; mkdir -p "$t124d"
bcftools view "$WORK/main.vcf.gz" -Oz -o "$t124d/o.vcf.gz" 2>/dev/null
bcftools index -f "$t124d/o.vcf.gz" 2>/dev/null
t124ck=$(_md5 < "$t124d/o.vcf.gz")
rm -f "$t124d/o.vcf.gz.csi"; mkdir -p "$t124d/o.vcf.gz.csi/blocker"; : > "$t124d/o.vcf.gz.csi/blocker/x"
run view -r 1 "$WORK/main.vcf.gz" -Oz -o "$t124d/o.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t124rc=$?
t124same=$([ "$(_md5 < "$t124d/o.vcf.gz")" = "$t124ck" ] && echo yes || echo no)
rm -rf "$t124d/o.vcf.gz.csi"
{ [ "$t124rc" != 0 ] && [ "$t124same" = yes ]; } \
  && ok "T124 unusable index destination refused; prior output untouched" \
  || bad "T124 failed index install replaced prior output" "rc=$t124rc unchanged=$t124same"

# T125 (the output path must be taken from any spelling bcftools accepts) GetOptions
# intercepts only -o/--output, so `query --out FILE` (a valid abbreviation) and
# `cnv --output-dir DIR` (documented) were passed through and pbcftools then died
# "Please provide a bcftools output file" on commands that work serially.
t125d="$WORK/t125"; mkdir -p "$t125d"
bcftools query -f '%CHROM\t%POS\n' --out "$t125d/ser.txt" "$WORK/main.vcf.gz" 2>/dev/null
run query -f '%CHROM\t%POS\n' --out "$t125d/par.txt" "$WORK/main.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes
t125a=$?
t125m=$(cmp -s "$t125d/ser.txt" "$t125d/par.txt" && echo yes || echo no)
rm -rf "$t125d/cnv"
run cnv -s S1 --output-dir "$t125d/cnv" "$WORK/main.vcf.gz" --p_jobs 2 --p_yes >/dev/null 2>&1
t125b=$?
# cnv runs serially now, so what must hold is that --output-dir was recognised as
# the destination and bcftools wrote there -- not any particular internal layout.
t125c=$(find "$t125d/cnv" -type f 2>/dev/null | wc -l | tr -d ' ')
{ [ "$t125a" = 0 ] && [ "$t125m" = yes ] && [ "$t125b" = 0 ] && [ "${t125c:-0}" -ge 1 ]; } \
  && ok "T125 output path adopted from --out / --output-dir; matches serial" \
  || bad "T125 output-spelling adoption" "query_rc=$t125a match=$t125m cnv_rc=$t125b files=$t125c"

# T126 (cross-device publication must not change the output's mode) The atomic
# O_CREAT|O_EXCL claim creates its scratch file 0600 so a half-copied result is
# never briefly world-readable; without restoring the staged mode, a cross-device
# run handed back 0600 where serial and the same-filesystem path give 0644.
t126alt=""
for c in /dev/shm /run/shm; do [ -d "$c" ] && [ -w "$c" ] && { t126alt="$c/pbcf_t126.$$"; break; }; done
if [ -z "$t126alt" ]; then
  skip "T126 cross-device publication preserves output mode (no second filesystem)"
else
  mkdir -p "$t126alt"
  t126d="$WORK/t126"; mkdir -p "$t126d"
  ( umask 0022
    bcftools view "$WORK/main.vcf.gz" -Oz -o "$t126d/ser.vcf.gz" 2>/dev/null
    perl "$PBCF" view "$WORK/main.vcf.gz" -Oz -o "$t126d/par.vcf.gz" \
         --p_dir "$t126alt" --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1 )
  t126s=$(stat -c %a "$t126d/ser.vcf.gz" 2>/dev/null || stat -f %Lp "$t126d/ser.vcf.gz" 2>/dev/null)
  t126p=$(stat -c %a "$t126d/par.vcf.gz" 2>/dev/null || stat -f %Lp "$t126d/par.vcf.gz" 2>/dev/null)
  rm -rf "$t126alt"
  [ -n "$t126p" ] && [ "$t126s" = "$t126p" ] \
    && ok "T126 cross-device publication preserves output mode ($t126p)" \
    || bad "T126 cross-device output mode" "serial=$t126s parallel=$t126p"
fi

# T127 (the output destination is the LAST one given, whatever the spelling) bcftools
# applies last-occurrence-wins across -o / --output / --output-dir and every valid
# abbreviation. pbcftools intercepted only exact -o/--output, so a later spelling
# survived in the worker argv and could not win: `query -o A --out B` wrote to A and
# left an EMPTY B where serial writes only to B, and `cnv -o A --output-dir B` let
# the surviving --output-dir override staging so both workers wrote into B at once.
t127d="$WORK/t127"; mkdir -p "$t127d"
_t127one() {   # $1=label  $2..=argv after the subcommand
  local label="$1"; shift
  rm -f "$t127d/A" "$t127d/B"
  bcftools query -r 1:100000-300000 -f '%CHROM\t%POS\n' "$@" "$WORK/main.vcf.gz" >/dev/null 2>&1
  local sa=$([ -e "$t127d/A" ] && stat -c %s "$t127d/A" 2>/dev/null || echo absent)
  local sb=$([ -e "$t127d/B" ] && stat -c %s "$t127d/B" 2>/dev/null || echo absent)
  rm -f "$t127d/A" "$t127d/B"
  perl "$PBCF" query -r 1:100000-300000 -f '%CHROM\t%POS\n' "$@" "$WORK/main.vcf.gz" \
       --p_jobs 2 --p_len 100KB --p_yes >/dev/null 2>&1
  local pa=$([ -e "$t127d/A" ] && stat -c %s "$t127d/A" 2>/dev/null || echo absent)
  local pb=$([ -e "$t127d/B" ] && stat -c %s "$t127d/B" 2>/dev/null || echo absent)
  [ "$sa" = "$pa" ] && [ "$sb" = "$pb" ] || echo "[$label ser=$sa/$sb par=$pa/$pb]"
}
t127fail=""
t127fail="$t127fail$(_t127one 'o-then-out'  -o "$t127d/A" --out "$t127d/B")"
t127fail="$t127fail$(_t127one 'out-then-o'  --out "$t127d/B" -o "$t127d/A")"
t127fail="$t127fail$(_t127one 'o-only'      -o "$t127d/A")"
# cnv: a surviving --output-dir must not override staging
rm -rf "$t127d/ca" "$t127d/cb"
run cnv -s S1 -o "$t127d/ca" --output-dir "$t127d/cb" "$WORK/main.vcf.gz" --p_jobs 2 --p_yes >/dev/null 2>&1
t127crc=$?
t127ca=$([ -e "$t127d/ca" ] && echo present || echo absent)
# cnv is serial now, so the assertion is that the LAST spelling won and bcftools
# wrote there -- counting files, not per-contig subdirectories.
t127cb=$(find "$t127d/cb" -type f 2>/dev/null | wc -l | tr -d ' ')
{ [ -z "$t127fail" ] && [ "$t127crc" = 0 ] && [ "$t127ca" = absent ] && [ "${t127cb:-0}" -ge 1 ]; } \
  && ok "T127 output destination follows last-occurrence-wins across spellings" \
  || bad "T127 output-spelling precedence" \
         "query=$t127fail cnv_rc=$t127crc first_dest=$t127ca last_dest_files=$t127cb"

# T128 (a cross-device publish must re-check for a signal before the final rename)
# The abort predicate was consulted only BEFORE _publish_output, but its cross-device
# path copies first — minutes on a whole-genome result — so a SIGTERM arriving during
# the copy was deferred and the rename replaced the user's previous output anyway.
# Also asserts no sibling scratch file is orphaned, which the text path used to leave
# behind on an ordinary SIGTERM (not only on SIGKILL, as L7 assumed).
t128alt=""
for c in /dev/shm /run/shm; do [ -d "$c" ] && [ -w "$c" ] && { t128alt="$c/pbcf_t128.$$"; break; }; done
if [ -z "$t128alt" ]; then
  skip "T128 cross-device publish re-checks for signals (no second filesystem)"
else
  mkdir -p "$t128alt"
  t128d="$WORK/t128"; mkdir -p "$t128d"
  printf 'PRIOR TEXT RESULT\n' > "$t128d/out.txt"
  t128ck=$(_md5 < "$t128d/out.txt")
  perl "$PBCF" query "$WORK/main.vcf.gz" -f '%CHROM\t%POS\t%REF\t%ALT\n' -o "$t128d/out.txt" \
       --p_dir "$t128alt" --p_jobs 2 --p_len 100KB --p_yes >/dev/null 2>&1 &
  t128pid=$!
  # fire as soon as the run is under way; either outcome must be safe
  ( sleep 0.4; kill -TERM "$t128pid" 2>/dev/null ) &
  wait "$t128pid" 2>/dev/null
  t128rc=$?
  t128now=$(_md5 < "$t128d/out.txt" 2>/dev/null)
  t128orphan=$(find "$t128d" -maxdepth 1 -name 'out.txt.pbcf.*' 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$t128alt"
  # -o must be EITHER the old content OR a complete new result; never partial, and
  # no scratch file may be left beside it.
  t128ok=no
  if [ "$t128now" = "$t128ck" ]; then t128ok=old
  elif [ -s "$t128d/out.txt" ] && [ "$(awk 'NF!=4{c++} END{print c+0}' "$t128d/out.txt")" = 0 ]; then t128ok=new
  fi
  { [ "$t128ok" != no ] && [ "${t128orphan:-1}" -eq 0 ]; } \
    && ok "T128 interrupted cross-device publish leaves old-or-complete, no orphan ($t128ok)" \
    || bad "T128 interrupted cross-device publish" \
           "rc=$t128rc state=$t128ok orphans=$t128orphan"
fi

# T129 (a pbcftools option name sitting where bcftools expects a VALUE must never be
# consumed) Renaming into the --p_ namespace fixed option-name collisions, but argv
# also has ROLES: `isec -f --p_len A PASS C` uses --p_len as the value of isec's -f.
# GetOptions runs before the subcommand's arity is known, so it captured --p_len and
# then took the NEXT token — the input file A — as our chunk length. The run
# continued one input short: wrong output at exit 0, and because the alias guard
# never saw A, `-o A` overwrote that same input. Must fail closed instead.
t129d="$WORK/t129"; mkdir -p "$t129d"
bcftools view -Oz -o "$t129d/A" "$WORK/main.vcf.gz" 2>/dev/null; bcftools index -f "$t129d/A" 2>/dev/null
bcftools view -r 1:1-500000 -Oz -o "$t129d/C" "$WORK/main.vcf.gz" 2>/dev/null
bcftools index -f "$t129d/C" 2>/dev/null
t129ck=$(_md5 < "$t129d/A")
# (a) wrong-output form
( cd "$t129d" && perl "$PBCF" isec -f --p_len A PASS C -n=1 -w1 -Oz -o par.vcf.gz --p_yes ) \
    >/dev/null 2>"$WORK/err.log"
t129a=$?
# (b) destructive form: -o names the input that would be swallowed
( cd "$t129d" && perl "$PBCF" isec -f --p_len A PASS C -n=1 -w1 -Oz -o A --p_yes ) \
    >/dev/null 2>>"$WORK/err.log"
t129b=$?
t129intact=$([ "$(_md5 < "$t129d/A")" = "$t129ck" ] && echo yes || echo no)
# (c) the same spelling in an OPTION position must still work normally
run view "$WORK/main.vcf.gz" -Oz -o "$t129d/ok.vcf.gz" --p_len 400KB --p_jobs 2 --p_yes >/dev/null 2>&1
t129c=$?
{ [ "$t129a" != 0 ] && [ "$t129b" != 0 ] && [ "$t129intact" = yes ] && [ "$t129c" = 0 ]; } \
  && ok "T129 wrapper option in a value position refused; input preserved" \
  || bad "T129 wrapper option captured from a value position" \
         "wrong_output_rc=$t129a destructive_rc=$t129b A_intact=$t129intact normal_use_rc=$t129c"

# T130 (the migration diagnostic must not fire on a bcftools option VALUE) It scans
# token text, so `query -f --pjobs FILE` — where --pjobs is the format string, which
# serial bcftools prints literally — was intercepted with "use --p_jobs" and produced
# no output at all.
t130d="$WORK/t130"; mkdir -p "$t130d"
bcftools query -f --pjobs "$WORK/main.vcf.gz" -o "$t130d/ser.txt" 2>/dev/null
t130s=$?
run query -f --pjobs "$WORK/main.vcf.gz" -o "$t130d/par.txt" --p_yes
t130p=$?
t130m=$(cmp -s "$t130d/ser.txt" "$t130d/par.txt" && echo yes || echo no)
# ...while a genuinely misspelled option in an OPTION position still gets the hint
run view "$WORK/main.vcf.gz" -Oz -o "$t130d/x.vcf.gz" --pjobs 2 --p_yes >/dev/null 2>&1
t130hint=$(grep -qs -- "--p_jobs" "$WORK/err.log" && echo yes || echo no)
{ [ "$t130s" = 0 ] && [ "$t130p" = 0 ] && [ "$t130m" = yes ] && [ "$t130hint" = yes ]; } \
  && ok "T130 migration hint skips value positions; matches serial" \
  || bad "T130 migration hint intercepts a value" \
         "ser=$t130s par=$t130p match=$t130m hint_still_shown=$t130hint"

# T131 (a bundled short option must not hide a value position) The value-position
# refusal added in T129 recognised only a standalone `-x` token, so a BUNDLE walked
# past it: `isec -Cf --p_len A PASS C` is `-C -f`, and it is the LAST letter that
# decides whether the next token is a value — here --p_len is the value of -f. We
# consumed it plus input A, then ran on C alone and exited 0 with a 500-record
# result, where serial bcftools exits 255.
t131d="$WORK/t131"; mkdir -p "$t131d"
bcftools view -Oz -o "$t131d/A" "$WORK/main.vcf.gz" 2>/dev/null; bcftools index -f "$t131d/A" 2>/dev/null
bcftools view -r 1:1-500000 -Oz -o "$t131d/C" "$WORK/main.vcf.gz" 2>/dev/null
bcftools index -f "$t131d/C" 2>/dev/null
t131fail=""
for bundle in -Cf -Cfw; do
  ( cd "$t131d" && bcftools isec $bundle --p_len A PASS C -w1 -Oz -o s.vcf.gz ) >/dev/null 2>&1
  t131s=$?
  ( cd "$t131d" && perl "$PBCF" isec $bundle --p_len A PASS C -w1 -Oz -o p.vcf.gz --p_yes ) \
      >/dev/null 2>&1
  t131p=$?
  # serial rejects these; parallel must too — never "serial fails, parallel invents"
  { [ "$t131s" != 0 ] && [ "$t131p" != 0 ]; } || t131fail="$t131fail [$bundle ser=$t131s par=$t131p]"
done
# ...and ordinary bundles must be completely unaffected
run view -aOb "$WORK/main.vcf.gz" -o "$t131d/ok.bcf" --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1
[ "$?" = 0 ] || t131fail="$t131fail [view -aOb broken]"
run query -ur1:100000-400000 -f '%CHROM\t%POS\n' "$WORK/main.vcf.gz" -o "$t131d/ok.txt" \
    --p_jobs 2 --p_len 100KB --p_yes >/dev/null 2>&1
[ "$?" = 0 ] || t131fail="$t131fail [query -ur.. broken]"
[ -z "$t131fail" ] \
  && ok "T131 bundled short options do not hide a value position" \
  || bad "T131 bundle evades the value-position check" "$t131fail"

# T132 (a '+' spelling must not be captured as a pbcftools option) Getopt::Long's
# default getopt_compat mode ALSO accepts `+p_len` as `--p_len`. The value-position
# check looks for `--p_` spellings, so `isec -f +p_len A PASS C -o A` slipped past it
# and destroyed input A at exit 0. '+' is bcftools' PLUGIN prefix, so it was never
# ours to claim; no_getopt_compat now leaves it for bcftools.
t132d="$WORK/t132"; mkdir -p "$t132d"
bcftools view -Oz -o "$t132d/A" "$WORK/main.vcf.gz" 2>/dev/null; bcftools index -f "$t132d/A" 2>/dev/null
bcftools view -r 1:1-500000 -Oz -o "$t132d/C" "$WORK/main.vcf.gz" 2>/dev/null
bcftools index -f "$t132d/C" 2>/dev/null
t132ck=$(_md5 < "$t132d/A")
( cd "$t132d" && perl "$PBCF" isec -f +p_len A PASS C -n=1 -w1 -Oz -o A --p_yes ) >/dev/null 2>&1
t132rc=$?
t132intact=$([ "$(_md5 < "$t132d/A")" = "$t132ck" ] && echo yes || echo no)
# and a real plugin invocation must still reach bcftools
run +fill-tags "$WORK/main.vcf.gz" -Oz -o "$t132d/ft.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes \
    >/dev/null 2>&1
t132plug=$?
{ [ "$t132rc" != 0 ] && [ "$t132intact" = yes ] && [ "$t132plug" = 0 ]; } \
  && ok "T132 '+' spellings are not claimed as pbcftools options; plugins still work" \
  || bad "T132 plus-prefix capture" "rc=$t132rc A_intact=$t132intact plugin_rc=$t132plug"

# T133 (a long option whose arity --help does not reveal must still create a value
# position) bcftools 1.22 prints roh's option as "-b  --buffer-size" — spaces, no
# comma — so the arity parser never learned it, the token after it was not treated as
# a value, and `--buffer-size --p_len A 10 C -o A` consumed --p_len AND input A, then
# overwrote the VCF A with roh text at exit 0. Unknown arity is now conservative.
t133d="$WORK/t133"; mkdir -p "$t133d"
bcftools view -Oz -o "$t133d/A" "$WORK/main.vcf.gz" 2>/dev/null; bcftools index -f "$t133d/A" 2>/dev/null
bcftools view -r 1:1-500000 -Oz -o "$t133d/C" "$WORK/main.vcf.gz" 2>/dev/null
t133ck=$(_md5 < "$t133d/A")
( cd "$t133d" && perl "$PBCF" roh -G30 --AF-dflt 0.4 --buffer-size --p_len A 10 C -o A --p_yes ) \
    >/dev/null 2>&1
t133rc=$?
t133intact=$([ "$(_md5 < "$t133d/A")" = "$t133ck" ] && echo yes || echo no)
# ...while an attached value must NOT be mistaken for one: -W=tbi carries its own, so
# a --p_ option after it is in an ordinary option position, not a value position.
run view "$WORK/main.vcf.gz" -Oz -W=tbi --p_len 400KB -o "$t133d/w.vcf.gz" --p_jobs 2 --p_yes \
    >/dev/null 2>&1
t133w=$?
{ [ "$t133rc" != 0 ] && [ "$t133intact" = yes ] && [ "$t133w" = 0 ]; } \
  && ok "T133 unknown-arity long option is conservative; attached values are not" \
  || bad "T133 arity gap" "rc=$t133rc A_intact=$t133intact attached_W_rc=$t133w"

# T134 (an OPTIONAL-argument option must not create a value position) `-W` takes
# only an ATTACHED argument (`-W=tbi`), so a bare `-W` cannot consume the token after
# it. The arity parser deliberately omits optional-argument options so that BUNDLES
# containing them fail closed — but the value-position walk read that omission as
# "unknown, so assume it takes a value" and refused
# `view in.vcf.gz -Oz -o out -W --p_jobs 2`, an ordinary command that works serially.
# Optional-argument options are now recorded separately: excluded from bundles,
# arity 0 for value positions.
#
# Also covers the validation probe: it runs with `-o /dev/null`, so an auto-index
# request tried to write "/dev/null.csi" and failed the whole run. The probe now
# drops -W/--write-index; pbcftools indexes the published output itself.
t134d="$WORK/t134"; mkdir -p "$t134d"
t134fail=""
for spec in "-W" "--write-index"; do
  rm -f "$t134d/o.vcf.gz" "$t134d/o.vcf.gz.csi"
  bcftools view "$WORK/main.vcf.gz" -Oz -o "$t134d/s.vcf.gz" $spec >/dev/null 2>&1
  t134s=$?
  run view "$WORK/main.vcf.gz" -Oz -o "$t134d/o.vcf.gz" $spec --p_jobs 2 --p_len 400KB --p_yes \
      >/dev/null 2>&1
  t134p=$?
  t134i=$([ -e "$t134d/o.vcf.gz.csi" ] && echo yes || echo no)
  { [ "$t134s" = 0 ] && [ "$t134p" = 0 ] && [ "$t134i" = yes ]; } \
    || t134fail="$t134fail [$spec ser=$t134s par=$t134p index=$t134i]"
done
# an attached value still works, and the real hazard is still refused
run view "$WORK/main.vcf.gz" -Oz -W=tbi -o "$t134d/w.vcf.gz" --p_jobs 2 --p_len 400KB --p_yes \
    >/dev/null 2>&1
[ "$?" = 0 ] || t134fail="$t134fail [-W=tbi broken]"
bcftools view -Oz -o "$t134d/A" "$WORK/main.vcf.gz" 2>/dev/null; bcftools index -f "$t134d/A" 2>/dev/null
bcftools view -r 1:1-500000 -Oz -o "$t134d/C" "$WORK/main.vcf.gz" 2>/dev/null
t134ck=$(_md5 < "$t134d/A")
( cd "$t134d" && perl "$PBCF" isec -Cf --p_len A PASS C -w1 -Oz -o A --p_yes ) >/dev/null 2>&1
{ [ "$?" != 0 ] && [ "$(_md5 < "$t134d/A")" = "$t134ck" ]; } \
  || t134fail="$t134fail [hazard no longer refused]"
[ -z "$t134fail" ] \
  && ok "T134 optional-argument options do not create a value position; -W works" \
  || bad "T134 optional-argument arity" "$t134fail"

# T135 (provenance must record the command the user actually typed) Two defects made
# the parallel header differ from serial for reasons unrelated to correctness:
#   * `csq` writes ##bcftools/csqCommand with a SLASH where every other subcommand
#     uses an underscore, so the rewrite never matched and the published header named
#     the FIRST CHUNK's region plus a temp path that had already been deleted;
#   * the equivalent command was rebuilt from an argv GetOptions had already stripped
#     -o/--output from, so an "-o" was synthesised and appended — rewriting the user's
#     `--output PATH` and moving it to the end.
t135d="$WORK/t135"; mkdir -p "$t135d"
_t135hdr() { bcftools view -h --no-version "$1" 2>/dev/null \
             | grep -E '^##bcftools[_/][a-z]+Command' | sed 's/; Date=.*//'; }
t135fail=""
# every output spelling, and -o both before and after the other options
for spec in "-Oz -o" "-Oz --output" "--output-type=z --output"; do
  rm -f "$t135d/o.vcf.gz"
  bcftools view --min-al 2 "$WORK/main.vcf.gz" $spec "$t135d/o.vcf.gz" 2>/dev/null
  t135s=$(_t135hdr "$t135d/o.vcf.gz")
  run view --min-al 2 "$WORK/main.vcf.gz" $spec "$t135d/o.vcf.gz" \
      --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1
  t135p=$(_t135hdr "$t135d/o.vcf.gz")
  [ "$t135s" = "$t135p" ] || t135fail="$t135fail [$spec]"
done
rm -f "$t135d/p.vcf.gz"
bcftools view -Oz -o "$t135d/p.vcf.gz" --min-al 2 "$WORK/main.vcf.gz" 2>/dev/null
t135s=$(_t135hdr "$t135d/p.vcf.gz")
run view -Oz -o "$t135d/p.vcf.gz" --min-al 2 "$WORK/main.vcf.gz" \
    --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1
t135p=$(_t135hdr "$t135d/p.vcf.gz")
[ "$t135s" = "$t135p" ] || t135fail="$t135fail [-o first]"
# and no published header may name an internal chunk path, whatever the separator
grep -qE '/pbcf[0-9]{4}\.' <(_t135hdr "$t135d/p.vcf.gz") && t135fail="$t135fail [chunk path leaked]"
[ -z "$t135fail" ] \
  && ok "T135 provenance keeps the user's output spelling and leaks no chunk path" \
  || bad "T135 provenance rewritten" "$t135fail"

# T136 (a section that cannot be merged must not be silently dropped) Per-region
# stats are combined with `plot-vcfstats -m`, which does not carry the custom
# transition/transversion section through: `stats -u AF:0:1:10` emits two USR rows
# serially and NONE after merging — at exit 0. Losing a whole section the user
# explicitly asked for is worse than not parallelising, so that form runs serially.
t136d="$WORK/t136"; mkdir -p "$t136d"
bcftools stats -u AF:0:1:10 "$WORK/main.vcf.gz" > "$t136d/ser.stats" 2>/dev/null
t136s=$(grep -c '^USR' "$t136d/ser.stats" 2>/dev/null)
run stats -u AF:0:1:10 "$WORK/main.vcf.gz" -o "$t136d/par.stats" --p_jobs 2 --p_len 400KB --p_yes
t136rc=$?
t136p=$(grep -c '^USR' "$t136d/par.stats" 2>/dev/null)
t136m=$(cmp -s <(grep -v '^#' "$t136d/ser.stats") <(grep -v '^#' "$t136d/par.stats") && echo yes || echo no)
# ...and ordinary stats must still be merged in parallel, not forced serial
run stats "$WORK/main.vcf.gz" -o "$t136d/plain.stats" --p_jobs 2 --p_len 400KB --p_yes >/dev/null 2>&1
t136plain=$?
{ [ "$t136rc" = 0 ] && [ "${t136s:-0}" -gt 0 ] && [ "$t136s" = "$t136p" ] \
  && [ "$t136m" = yes ] && [ "$t136plain" = 0 ]; } \
  && ok "T136 stats -u keeps its USR section ($t136p rows, matches serial)" \
  || bad "T136 stats -u section dropped" \
         "rc=$t136rc ser_rows=$t136s par_rows=$t136p match=$t136m plain_stats_rc=$t136plain"

# T137 (a passthrough that cannot stage beside its output must still never destroy
# that output) The stdout-redirect passthrough stages into a sibling file and
# publishes only on success. When no sibling can be claimed -- every candidate taken,
# or the directory not writable -- it used to fall back to `> $ofile`, which
# truncates the destination the instant the redirect is set up, BEFORE the command
# runs: a run that then failed left the user's result destroyed and zero bytes in its
# place.
#
# The first fix refused outright, which was itself a regression: `bcftools stats >
# FILE` succeeds when the FILE is writable even if its DIRECTORY is not, and
# pbcftools must not fail where the tool it wraps works. It now stages in a temp
# directory and copies in only after success. Two properties are asserted, because
# either alone can be satisfied by a broken implementation:
#   (a) a SUCCEEDING run in an unwritable directory still produces the result;
#   (b) a FAILING run leaves the pre-existing output byte-identical.
t137d="$WORK/t137"; mkdir -p "$t137d/ro"
{ echo '##fileformat=VCFv4.2'
  echo '##contig=<ID=1,length=10000>'
  printf '#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n'
  printf '1\t1000\t.\tA\tG\t100\tPASS\t.\n'
} > "$t137d/tiny.vcf"
bgzip -f "$t137d/tiny.vcf" 2>/dev/null && bcftools index -f "$t137d/tiny.vcf.gz" 2>/dev/null

# (a) succeeds where serial succeeds
t137a_out="$t137d/ro/ok.stats"; printf 'old\n' > "$t137a_out"
chmod 555 "$t137d/ro" 2>/dev/null
perl "$PBCF" stats "$t137d/tiny.vcf.gz" -o "$t137a_out" --p_jobs 1 --p_yes >"$t137d/a.log" 2>&1
t137arc=$?
t137asn=$(grep -c '^SN' "$t137a_out" 2>/dev/null || echo 0)

# (b) a failing run leaves the pre-existing result untouched
t137b_out="$t137d/ro/keep.stats"
chmod 755 "$t137d/ro" 2>/dev/null
printf 'IRREPLACEABLE\n' > "$t137b_out"
t137bef=$(md5sum "$t137b_out" | awk '{print $1}')
chmod 555 "$t137d/ro" 2>/dev/null
perl "$PBCF" stats "$t137d/no_such_input.vcf.gz" -o "$t137b_out" --p_jobs 1 --p_yes >"$t137d/b.log" 2>&1
t137brc=$?
t137aft=$(md5sum "$t137b_out" 2>/dev/null | awk '{print $1}')
chmod 755 "$t137d/ro" 2>/dev/null

{ [ "$t137arc" = 0 ] && [ "${t137asn:-0}" -gt 0 ] \
  && [ "$t137brc" != 0 ] && [ "$t137bef" = "$t137aft" ]; } \
  && ok "T137 unwritable output dir: success still writes, failure preserves prior result" \
  || bad "T137 unstageable output" \
         "ok_rc=$t137arc ok_sn=$t137asn fail_rc=$t137brc preserved=$([ "$t137bef" = "$t137aft" ] && echo yes || echo NO)"
#-----------------------------------------------------------------------------
# Optional benchmark (--bench): fixed synthetic workload, serial vs parallel.
# Same work on every platform => comparable serial time AND parallel speedup,
# with no external data download. Uses `norm -m -both` (CPU-bound; the headline
# operation) on a file with many multiallelic sites so there is real work to do.
#-----------------------------------------------------------------------------
BENCH_DONE=0
if [ "$BENCH" = 1 ]; then
  # Sizing (override via env for a strict cross-platform comparison, e.g.
  # PBCF_BENCH_VARIANTS=8000000 PBCF_BENCH_CPUS=4). Default ~8M sites gives a
  # serial time (~25-70s depending on CPU) large enough to amortize fixed
  # split/concat/index overhead, so the speedup is representative rather than
  # overhead-dominated. Whole benchmark takes ~1-2 min.
  BVAR="${PBCF_BENCH_VARIANTS:-8000000}"
  case "$NCPU" in ''|*[!0-9]*) _nc=4 ;; *) _nc=$NCPU ;; esac
  BCPU="${PBCF_BENCH_CPUS:-$([ "$_nc" -lt 8 ] && echo "$_nc" || echo 8)}"
  BLEN=$(( BVAR * 100 + 1000 ))                 # contig length (positions are i*100)
  BPLEN=$(( BLEN / (BCPU * 4) )); [ "$BPLEN" -lt 1 ] && BPLEN=1

  echo
  echo "Benchmark: norm -m -both  |  ${BVAR} sites (multiallelic)  |  ${BCPU} workers"
  echo "  building synthetic data..."

  # Sites-only, multiallelic VCF: `norm -m -both` splits the multiallelics and
  # redistributes the per-allele INFO/AF — pure CPU work (the headline 5.3x
  # operation), no genotype I/O. perl is fast and always present.
  perl -e '
    my $n = $ARGV[0];
    open(my $f, ">", $ARGV[1]) or die $!;
    print $f "##fileformat=VCFv4.2\n##contig=<ID=1,length=".($n*100+1000).">\n";
    print $f "##INFO=<ID=AF,Number=A,Type=Float,Description=\"af\">\n";
    print $f "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n";
    my @alt = ("C", "G,T", "G,T,C");         # 1, 2, or 3 ALT alleles
    my @af  = ("0.1", "0.1,0.2", "0.1,0.2,0.3");
    for my $i (1..$n) {
      my $k = $i % 3;                        # cycle allele multiplicity
      print $f "1\t".($i*100)."\t.\tA\t$alt[$k]\t100\tPASS\tAF=$af[$k]\n";
    }
    close $f;
  ' "$BVAR" "$WORK/bench.vcf"
  bgzip -f "$WORK/bench.vcf" && bcftools index -f "$WORK/bench.vcf.gz"

  now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

  echo "  timing serial bcftools..."
  t0=$(now)
  bcftools norm -m -both "$WORK/bench.vcf.gz" -Oz -o "$WORK/bench_serial.vcf.gz" 2>/dev/null
  bench_ser_rc=$?
  t1=$(now)
  BENCH_SER=$(perl -e "printf '%.2f', $t1-$t0")

  echo "  timing parallel pbcftools (${BCPU} workers)..."
  t0=$(now)
  perl "$PBCF" norm -m -both "$WORK/bench.vcf.gz" -Oz -o "$WORK/bench_par.vcf.gz" \
       --p_jobs "$BCPU" --p_len "$BPLEN" --p_yes >/dev/null 2>&1
  bench_par_rc=$?
  t1=$(now)
  BENCH_PAR=$(perl -e "printf '%.2f', $t1-$t0")

  BENCH_SPEEDUP=$(perl -e "printf '%.2f', ($BENCH_PAR>0)?$BENCH_SER/$BENCH_PAR:0")
  # Fail-closed: both must exit 0 and produce a valid, NON-EMPTY body; only then
  # do the record-body hashes decide. Empty==empty (both hashing to d41d8…) is
  # never a match, and a nonzero producer rc never yields "yes".
  bench_sm=$(bgzip -t "$WORK/bench_serial.vcf.gz" 2>/dev/null && bcftools view -H "$WORK/bench_serial.vcf.gz" 2>/dev/null | _md5)
  bench_pm=$(bgzip -t "$WORK/bench_par.vcf.gz"    2>/dev/null && bcftools view -H "$WORK/bench_par.vcf.gz"    2>/dev/null | _md5)
  bench_sn=$(bcftools view -H "$WORK/bench_serial.vcf.gz" 2>/dev/null | grep -cm1 . )
  if [ "$bench_ser_rc" -eq 0 ] && [ "$bench_par_rc" -eq 0 ] \
     && [ "${bench_sn:-0}" -gt 0 ] && [ -n "$bench_sm" ] && [ "$bench_sm" = "$bench_pm" ]; then
    BENCH_MATCH="yes"
  else
    BENCH_MATCH="NO"
  fi
  BENCH_VARS="$BVAR"; BENCH_CPU="$BCPU"; BENCH_DONE=1
  printf "  serial %ss  |  parallel %ss  |  speedup %sx  |  output match: %s\n" \
    "$BENCH_SER" "$BENCH_PAR" "$BENCH_SPEEDUP" "$BENCH_MATCH"
fi

#-----------------------------------------------------------------------------
# Write a shareable Markdown report
#-----------------------------------------------------------------------------
{
  echo "# pbcftools regression report"
  echo
  echo "| field | value |"
  echo "|---|---|"
  echo "| platform label | \`$LABEL\` |"
  echo "| date (UTC) | $(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date) |"
  echo "| OS | $OS_DETAIL |"
  echo "| kernel / arch | $(uname -srm 2>/dev/null || echo '?') |"
  echo "| WSL | $IS_WSL |"
  echo "| host | $(hostname 2>/dev/null || echo '?') |"
  echo "| CPU model | $CPU_MODEL |"
  echo "| CPUs (logical) | $NCPU |"
  echo "| RAM (GB) | $MEM_GB |"
  echo "| perl | $(perl -e 'print $^V' 2>/dev/null) |"
  echo "| bcftools | $(bcftools --version 2>/dev/null | head -1) |"
  echo "| pbcftools commit | $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'n/a (tarball)') |"
  echo "| elapsed (s) | $SECONDS |"
  echo "| result | **$PASS passed, $FAIL failed$([ "$SKIP" -gt 0 ] && echo ", $SKIP skipped")** |"
  echo
  echo "| result | test |"
  echo "|---|---|"
  for r in "${RESULTS[@]}"; do
    st="${r%%|*}"; msg="${r#*|}"
    echo "| $st | $msg |"
  done
  if [ "$BENCH_DONE" = 1 ]; then
    echo
    echo "## Benchmark (\`norm -m -both\`, synthetic)"
    echo
    echo "| metric | value |"
    echo "|---|---|"
    echo "| workload | ${BENCH_VARS} multiallelic sites (norm splits + AF redistribute) |"
    echo "| workers | ${BENCH_CPU} |"
    echo "| serial (s) | ${BENCH_SER} |"
    echo "| parallel (s) | ${BENCH_PAR} |"
    echo "| **speedup** | **${BENCH_SPEEDUP}x** |"
    echo "| output matches serial | ${BENCH_MATCH} |"
  fi
} > "$REPORT"

echo
echo "-------------------------------------------"
printf "Regression: %d passed, %d failed%s  (%ds)\n" "$PASS" "$FAIL" \
  "$([ "$SKIP" -gt 0 ] && echo ", $SKIP skipped")" "$SECONDS"
echo "Report written to: $REPORT"
echo ">> Send this file back for the cross-platform summary."
echo "Note: LSF/Slurm cluster quote-escaping (R2) is verified separately; this"
echo "      suite covers local-mode behavior and correctness invariants."
[ "$FAIL" = 0 ] || exit 1
