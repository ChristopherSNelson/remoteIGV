#!/usr/bin/env bash
set -euo pipefail

#
# Download small public genomic test files and upload to S3.
# All files are publicly available — no credentials needed for download.
#
# Usage: ./upload_test_data.sh
#    or: REMOTEIGV_BUCKET=my-bucket ./upload_test_data.sh
#

source "$(dirname "$0")/config.sh"

S3_PREFIX="demo"
TMPDIR=$(mktemp -d)

trap "rm -rf $TMPDIR" EXIT

echo "========================================="
echo " Upload demo data → s3://$BUCKET/$S3_PREFIX/"
echo "========================================="
echo ""

# verify bucket exists
if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "ERROR: Bucket s3://$BUCKET does not exist. Run setup_aws.sh first." >&2
  exit 1
fi

cd "$TMPDIR"

GITHUB_RAW="https://raw.githubusercontent.com/igvteam/igv.js/master/test/data/bam"

# ── 1. HG002 demo BAM from igv.js test data (~736 KB) ────────
echo "[1/4] HG002 chr11 BAM (igv.js test data, ~736 KB)..."
if ! curl -fSL -o HG002_chr11.bam "$GITHUB_RAW/HG002_chr11_119076212_119102218_2.bam"; then
  echo "ERROR: Failed to download HG002 BAM." >&2
  exit 1
fi
if ! curl -fSL -o HG002_chr11.bam.bai "$GITHUB_RAW/HG002_chr11_119076212_119102218_2.bam.bai"; then
  echo "ERROR: Failed to download HG002 BAM index." >&2
  exit 1
fi
echo "  Downloaded HG002_chr11.bam + .bai"

# ── 2. Annotation tracks from UCSC API (real data) ───────────
#    All coordinates verified live from UCSC Genome Browser, hg38.
UCSC_API="https://api.genome.ucsc.edu/getData/track?genome=hg38"
CHR="chr11"
START=119076212
END=119102218

echo "[2/4] MANE Select gene models (UCSC API)..."
if ! curl -sf "${UCSC_API}&track=mane&chrom=${CHR}&start=${START}&end=${END}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for g in data['mane']:
    sizes = g['blockSizes'].rstrip(',')
    starts = g['chromStarts'].rstrip(',')
    print(f\"{g['chrom']}\t{g['chromStart']}\t{g['chromEnd']}\t{g['geneName2']}\t{g['score']}\t{g['strand']}\t{g['thickStart']}\t{g['thickEnd']}\t{g['reserved']}\t{g['blockCount']}\t{sizes}\t{starts}\")
" > mane_select_genes.bed; then
  echo "  WARNING: UCSC API failed for MANE Select, skipping"
fi
if [ -s mane_select_genes.bed ]; then
  GENES=$(awk -F'\t' '{printf $4", "}' mane_select_genes.bed | sed 's/, $//')
  echo "  Fetched $(wc -l < mane_select_genes.bed | tr -d ' ') genes: ${GENES}"
fi

echo "[3/4] ENCODE cCREs — regulatory regions (UCSC API)..."
if ! curl -sf "${UCSC_API}&track=encodeCcreCombined&chrom=${CHR}&start=${START}&end=${END}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data['encodeCcreCombined']:
    print(f\"{r['chrom']}\t{r['chromStart']}\t{r['chromEnd']}\t{r['ucscLabel']}:{r['name']}\t{r['score']}\t.\")
" > encode_ccres.bed; then
  echo "  WARNING: UCSC API failed for ENCODE cCREs, skipping"
fi
if [ -s encode_ccres.bed ]; then
  echo "  Fetched $(wc -l < encode_ccres.bed | tr -d ' ') cCREs (enhancers, promoters, etc.)"
fi

echo "[4/4] phyloP 100-way conservation scores (UCSC API)..."
if ! curl -sf "${UCSC_API}&track=phyloP100way&chrom=${CHR}&start=${START}&end=${END}" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pt in data['${CHR}']:
    print(f\"${CHR}\t{pt['start']}\t{pt['end']}\t{pt['value']:.4f}\")
" > phyloP100way.bedGraph; then
  echo "  WARNING: UCSC API failed for phyloP, skipping"
fi
if [ -s phyloP100way.bedGraph ]; then
  echo "  Fetched $(wc -l < phyloP100way.bedGraph | tr -d ' ') base positions"
fi

# ── Upload demo/ ──────────────────────────────────────────────
echo ""
echo "Uploading to s3://$BUCKET/$S3_PREFIX/ ..."
echo ""

FAIL=0
for f in *.bam *.bam.bai *.bed *.bedGraph; do
  [ -f "$f" ] || continue
  SIZE=$(ls -lh "$f" | awk '{print $5}')
  printf "  %-40s %s\n" "$f" "$SIZE"
  if ! aws s3 cp "$f" "s3://$BUCKET/$S3_PREFIX/$f" --region "$REGION" --quiet; then
    echo "  ERROR: Failed to upload $f" >&2
    FAIL=1
  fi
done

if [ "$FAIL" = "1" ]; then
  echo ""
  echo "Some uploads failed. Check your AWS permissions." >&2
  exit 1
fi

# ── Multisample: 1000G high-coverage hg38 ─────────────────────
# Stream a region from the 1000G GRCh38 high-coverage CRAMs.
# Requires samtools >= 1.10 with htslib (for remote CRAM streaming).
# Uses the EBI CRAM reference server for decoding — no local reference needed.
echo ""
echo "========================================="
echo " Multisample: 1000G hg38 high-coverage"
echo "========================================="
echo ""

if ! command -v samtools &>/dev/null; then
  echo "WARNING: samtools not found — skipping multisample upload."
  echo "  Install samtools and re-run to populate s3://$BUCKET/multisample/"
else
  MULTI_PREFIX="multisample"
  # Genomic region: ±500kb around HG002 demo locus for good exon coverage
  LOCUS="chr11:118500000-119600000"
  # 1000G 30x high-coverage hg38 WGS CRAMs (from EBI SRA)
  # URLs from: http://ftp.1000genomes.ebi.ac.uk/vol1/ftp/data_collections/1000G_2504_high_coverage/1000G_2504_high_coverage.sequence.index
  declare -A CRAMS
  CRAMS[HG00096]="http://ftp.sra.ebi.ac.uk/vol1/run/ERR324/ERR3240114/HG00096.final.cram"
  CRAMS[HG00097]="http://ftp.sra.ebi.ac.uk/vol1/run/ERR324/ERR3240115/HG00097.final.cram"
  CRAMS[HG00099]="http://ftp.sra.ebi.ac.uk/vol1/run/ERR324/ERR3240116/HG00099.final.cram"
  # Use EBI CRAM reference server for decoding (no local reference needed)
  export REF_PATH=":http://www.ebi.ac.uk/ena/cram/md5/%s"

  for SAMPLE in HG00096 HG00097 HG00099; do
    CRAM_URL="${CRAMS[$SAMPLE]}"
    OUT_BAM="${SAMPLE}_chr11.bam"
    echo "[$SAMPLE] Fetching $LOCUS from hg38 CRAM..."
    if samtools view -b -o "$OUT_BAM" "$CRAM_URL" "$LOCUS" 2>/dev/null; then
      samtools index "$OUT_BAM"
      SIZE=$(ls -lh "$OUT_BAM" | awk '{print $5}')
      echo "  Created $OUT_BAM ($SIZE), uploading..."
      aws s3 cp "$OUT_BAM"     "s3://$BUCKET/$MULTI_PREFIX/$OUT_BAM"     --region "$REGION" --quiet
      aws s3 cp "$OUT_BAM.bai" "s3://$BUCKET/$MULTI_PREFIX/$OUT_BAM.bai" --region "$REGION" --quiet
      echo "  Uploaded."
    else
      echo "  WARNING: Failed to fetch $SAMPLE — skipping."
    fi
  done
fi

echo ""
echo "========================================="
echo " Upload complete!"
echo "========================================="
echo ""
aws s3 ls "s3://$BUCKET/$S3_PREFIX/" --region "$REGION" --human-readable
echo ""
echo "Test regions for the UI:"
echo "  HG002  → chr11:119,076,212-119,102,218  (long reads, all annotations)"
echo "  Multi  → chr11:119,076,212-119,102,218  (3x 1000G hg38 exomes)"
echo ""
