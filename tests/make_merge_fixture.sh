#!/bin/bash
#=============================================================================
# Build the multi-sample merge test fixture from PUBLIC 1000 Genomes data.
#
# The merge benchmark needs many per-sample VCFs over one contig. The original
# fixture used low-pass WGS data that cannot be redistributed, so this script
# regenerates an equivalent fixture from 1000 Genomes Phase 3 chr1 — public,
# citable, and reproducible by anyone.
#
#   bash tests/make_merge_fixture.sh [--nfiles 100] [--nsamples 10]
#                                    [--region 1:1-50000000] [--out <dir>]
#                                    [--src <chr1.vcf.gz>] [--force]
#
#   --nfiles N     number of output VCFs            (default 100)
#   --nsamples N   samples per output VCF           (default 10)
#   --region REG   region to extract; use "1" for the whole chromosome
#                                                   (default 1:1-50000000)
#   --out DIR      output directory                 (default tests/data/vcfs)
#   --src FILE     source VCF (default: 1000G chr1 genotypes in tests/data)
#   --force        overwrite a non-empty --out
#
# Output: <out>/g001.vcf.gz .. gNNN.vcf.gz (+ .csi) and tests/data/vcfs.lst
# (paths RELATIVE to the list, so the fixture is portable between machines).
#
# Cost scales with region x nfiles. Reference points (nfiles=100, nsamples=10):
#   1:1-5000000    ~0.35 GB   ~1 min
#   1:1-50000000   ~3.5 GB    ~10 min
#   whole chr1     ~17 GB     ~45 min
#
# NOTE: 1000G Phase 3 contigs are NOT chr-prefixed ("1", not "chr1").
#=============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NFILES=100
NSAMPLES=10
REGION="1:1-50000000"
OUT="$SCRIPT_DIR/data/vcfs"
SRC="$SCRIPT_DIR/data/ALL.chr1.phase3_shapeit2_mvncall_integrated_v5b.20130502.genotypes.vcf.gz"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --nfiles)   NFILES="$2"; shift 2 ;;
        --nsamples) NSAMPLES="$2"; shift 2 ;;
        --region)   REGION="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --src)      SRC="$2"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v bcftools >/dev/null 2>&1 || { echo "ERROR: bcftools not on PATH" >&2; exit 2; }
bcftools +split -h >/dev/null 2>&1 || true   # plugin presence checked by the run below
[ -f "$SRC" ] || { echo "ERROR: source VCF not found: $SRC" >&2
                   echo "  Download 1000G Phase 3 chr1 genotypes into tests/data/ (see README)." >&2; exit 2; }

NEED=$(( NFILES * NSAMPLES ))
HAVE=$(bcftools query -l "$SRC" | wc -l | tr -d ' ')
[ "$HAVE" -ge "$NEED" ] || { echo "ERROR: need $NEED samples ($NFILES x $NSAMPLES) but '$SRC' has $HAVE." >&2; exit 2; }

if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] && [ "$FORCE" != 1 ]; then
    echo "ERROR: '$OUT' exists and is not empty. Pass --force to overwrite." >&2; exit 2
fi
rm -rf "$OUT"; mkdir -p "$OUT"

GRPFILE="$(mktemp)"; trap 'rm -f "$GRPFILE"' EXIT
# One pass over the source: `+split -G` maps each sample to an output file, so we
# read the (large) source ONCE instead of once per output file.
# NB: read the whole sample stream and limit inside awk. Piping into `head`
# would close the pipe early, and SIGPIPE under `set -o pipefail` would abort
# this script silently.
bcftools query -l "$SRC" \
  | awk -v need="$NEED" -v n="$NSAMPLES" \
        'NR<=need{printf "%s\t-\tg%03d\n", $1, int((NR-1)/n)+1}' > "$GRPFILE"

echo "Building merge fixture"
echo "  source : $SRC"
echo "  region : $REGION"
echo "  output : $NFILES files x $NSAMPLES samples -> $OUT"
bcftools +split "$SRC" -G "$GRPFILE" -Oz -o "$OUT" -r "$REGION"

n=0
for f in "$OUT"/*.vcf.gz; do bcftools index -f "$f"; n=$((n+1)); done
[ "$n" -eq "$NFILES" ] || { echo "ERROR: produced $n files, expected $NFILES." >&2; exit 1; }

# List with paths RELATIVE to the list's own directory, so a copied checkout
# resolves them on any machine (run_tests_merge.sh anchors to the list's dir).
LIST="$(dirname "$OUT")/vcfs.lst"
( cd "$(dirname "$OUT")" && ls "$(basename "$OUT")"/*.vcf.gz ) > "$LIST"

echo
echo "Done: $n VCFs, $(du -sh "$OUT" | cut -f1) total"
echo "List: $LIST ($(wc -l < "$LIST" | tr -d ' ') entries, relative paths)"
echo "Records/file: $(bcftools index -n "$OUT/g001.vcf.gz")"
echo
echo "Run the merge test with e.g.:"
echo "  bash tests/run_tests_merge.sh <label> --cpus 16 --nfiles $NFILES --region $REGION"
