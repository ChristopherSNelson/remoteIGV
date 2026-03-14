#!/usr/bin/env bash
set -euo pipefail

#
# Download small public genomic test files and upload to S3.
# All files are publicly available — no credentials needed for download.
#
# Usage: ./upload_test_data.sh
#

REGION="us-east-2"
BUCKET="remoteigv-data"
S3_PREFIX="demo"
TMPDIR=$(mktemp -d)

trap "rm -rf $TMPDIR" EXIT

echo "========================================="
echo " Upload demo data → s3://$BUCKET/$S3_PREFIX/"
echo "========================================="
echo ""

cd "$TMPDIR"

GITHUB_RAW="https://raw.githubusercontent.com/igvteam/igv.js/master/test/data/bam"

# ── 1. HG002 demo BAM from igv.js test data (~736 KB) ────────
echo "[1/2] HG002 chr11 BAM (igv.js test data, ~736 KB)..."
curl -fSL -o HG002_chr11.bam     "$GITHUB_RAW/HG002_chr11_119076212_119102218_2.bam"
curl -fSL -o HG002_chr11.bam.bai "$GITHUB_RAW/HG002_chr11_119076212_119102218_2.bam.bai"
echo "  Downloaded HG002_chr11.bam + .bai"

# ── 2. Annotation tracks from UCSC API (real data) ───────────
#    All coordinates verified live from UCSC Genome Browser, hg38.
UCSC_API="https://api.genome.ucsc.edu/getData/track?genome=hg38"
CHR="chr11"
START=119076212
END=119102218

echo "[2/4] MANE Select gene models (UCSC API)..."
curl -sf "${UCSC_API}&track=mane&chrom=${CHR}&start=${START}&end=${END}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data['mane']:
    # BED12: chrom start end name score strand thickStart thickEnd rgb blockCount blockSizes blockStarts
    sizes = g['blockSizes'].rstrip(',')
    starts = g['chromStarts'].rstrip(',')
    print(f\"{g['chrom']}\t{g['chromStart']}\t{g['chromEnd']}\t{g['geneName2']}\t{g['score']}\t{g['strand']}\t{g['thickStart']}\t{g['thickEnd']}\t{g['reserved']}\t{g['blockCount']}\t{sizes}\t{starts}\")
" > mane_select_genes.bed
GENES=$(awk -F'\t' '{split($4,a,"|"); printf a[1]", "}' mane_select_genes.bed | sed 's/, $//')
echo "  Fetched $(wc -l < mane_select_genes.bed | tr -d ' ') genes: ${GENES}"

echo "[3/4] ENCODE cCREs — regulatory regions (UCSC API)..."
curl -sf "${UCSC_API}&track=encodeCcreCombined&chrom=${CHR}&start=${START}&end=${END}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data['encodeCcreCombined']:
    print(f\"{r['chrom']}\t{r['chromStart']}\t{r['chromEnd']}\t{r['ucscLabel']}:{r['name']}\t{r['score']}\t.\")
" > encode_ccres.bed
echo "  Fetched $(wc -l < encode_ccres.bed | tr -d ' ') cCREs (enhancers, promoters, etc.)"

echo "[4/4] phyloP 100-way conservation scores (UCSC API)..."
# Fetch per-base scores and write as bedGraph (chrom start end value)
curl -sf "${UCSC_API}&track=phyloP100way&chrom=${CHR}&start=${START}&end=${END}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pt in data['${CHR}']:
    print(f\"${CHR}\t{pt['start']}\t{pt['end']}\t{pt['value']:.4f}\")
" > phyloP100way.bedGraph
echo "  Fetched $(wc -l < phyloP100way.bedGraph | tr -d ' ') base positions"

# ── Upload ────────────────────────────────────────────────────
echo ""
echo "Uploading to s3://$BUCKET/$S3_PREFIX/ ..."
echo ""

for f in *.bam *.bam.bai *.bed *.bedGraph; do
  [ -f "$f" ] || continue
  SIZE=$(ls -lh "$f" | awk '{print $5}')
  printf "  %-40s %s\n" "$f" "$SIZE"
  aws s3 cp "$f" "s3://$BUCKET/$S3_PREFIX/$f" --region "$REGION" --quiet
done

echo ""
echo "========================================="
echo " Upload complete!"
echo "========================================="
echo ""
aws s3 ls "s3://$BUCKET/$S3_PREFIX/" --region "$REGION" --human-readable
echo ""
echo "Test regions for the UI:"
echo "  HG002  → chr11:119,076,212-119,102,218  (BAM reads + all annotations)"
echo "  Genes:   VPS11, HMBS, H2AX, DPAGT1 (MANE Select)"
echo "  Tracks:  32 ENCODE cCREs, ~26K phyloP conservation scores"
echo ""
