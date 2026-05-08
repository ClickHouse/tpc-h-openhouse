#!/usr/bin/env bash
# Re-encode the public-pme TPC-H parquet into Redshift-compatible parquet
# in your staging bucket. The source files use parquet types Redshift's
# COPY won't accept:
#
#   - FIXED_LEN_BYTE_ARRAY[N] without a STRING/UTF8 annotation
#       -> rewrite as BYTE_ARRAY+UTF8 (CAST(... AS String))
#   - INT32 with UINT_32 annotation
#       -> rewrite as plain INT64    (toInt64(...))
#   - DATE32
#       -> rewrite as DATE           (toDate(...))
#   - LZ4 compression
#       -> rewrite as SNAPPY         (output_format_parquet_compression_method)
#
# Skip-aware: any file already present at the destination key is left alone.
# Multipart uploads commit atomically, so an object's existence in the
# listing is a sufficient "fully uploaded" signal.
#
# Usage:
#   SF=10  ./convert.sh
#   SF=100 ./convert.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${REGION:=eu-west-3}"
: "${SF:?set SF (10, 100, or 1000)}"
: "${SOURCE_BUCKET:=public-pme}"
: "${SOURCE_PREFIX:=join_bench/tpc-h/sf${SF}}"

if ! command -v clickhouse >/dev/null 2>&1; then
  echo "ERROR: clickhouse not found. Install via 'brew install clickhouse'." >&2
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STAGING_BUCKET="${STAGING_BUCKET:-tpch-redshift-${ACCOUNT_ID}-${REGION}}"

# Staging bucket holds the converted parquet files.
if ! aws s3api head-bucket --bucket "$STAGING_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Creating staging bucket ${STAGING_BUCKET}..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$STAGING_BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$STAGING_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
else
  echo "Staging bucket ${STAGING_BUCKET} exists."
fi

# Per-table SELECT lists. CAST(FixedString -> String) for parquet UTF8;
# toInt64() for parquet INT64 -> Redshift BIGINT (clean widening); toDate()
# in case Date32 round-trips inconsistently.
declare -A SELECTS
SELECTS[nation]='toInt64(n_nationkey), CAST(n_name AS String), toInt64(n_regionkey), n_comment'
SELECTS[region]='toInt64(r_regionkey), CAST(r_name AS String), r_comment'
SELECTS[part]='toInt64(p_partkey), p_name, CAST(p_mfgr AS String), CAST(p_brand AS String), p_type, toInt64(p_size), CAST(p_container AS String), p_retailprice, p_comment'
SELECTS[supplier]='toInt64(s_suppkey), CAST(s_name AS String), s_address, toInt64(s_nationkey), CAST(s_phone AS String), s_acctbal, s_comment'
SELECTS[partsupp]='toInt64(ps_partkey), toInt64(ps_suppkey), toInt64(ps_availqty), ps_supplycost, ps_comment'
SELECTS[customer]='toInt64(c_custkey), c_name, c_address, toInt64(c_nationkey), CAST(c_phone AS String), c_acctbal, CAST(c_mktsegment AS String), c_comment'
SELECTS[orders]='toInt64(o_orderkey), toInt64(o_custkey), CAST(o_orderstatus AS String), o_totalprice, toDate(o_orderdate), CAST(o_orderpriority AS String), CAST(o_clerk AS String), toInt64(o_shippriority), o_comment'
SELECTS[lineitem]='toInt64(l_orderkey), toInt64(l_partkey), toInt64(l_suppkey), toInt64(l_linenumber), l_quantity, l_extendedprice, l_discount, l_tax, CAST(l_returnflag AS String), CAST(l_linestatus AS String), toDate(l_shipdate), toDate(l_commitdate), toDate(l_receiptdate), CAST(l_shipinstruct AS String), CAST(l_shipmode AS String), l_comment'

TABLES=(nation region part supplier partsupp customer orders lineitem)

# Warm up the clickhouse self-extracting binary so the decompression message
# goes to /dev/null rather than stdout where it would corrupt the first file.
clickhouse local -q "SELECT 1" >/dev/null 2>&1 || true

# Default multipart chunk size (8 MB) caps single-file uploads at 80 GB.
# sf1000 lineitem can exceed that, so raise the ceiling to 640 GB.
aws configure set default.s3.multipart_chunksize 64MB

echo "Listing s3://${SOURCE_BUCKET}/${SOURCE_PREFIX}/ ..."
ALL_FILES=$(aws s3 ls --no-sign-request "s3://${SOURCE_BUCKET}/${SOURCE_PREFIX}/" \
  | awk '/\.parquet$/ {print $4}')
if [ -z "$ALL_FILES" ]; then
  echo "ERROR: no parquet files at s3://${SOURCE_BUCKET}/${SOURCE_PREFIX}/" >&2
  exit 1
fi

for t in "${TABLES[@]}"; do
  # ^${t}[_0-9] separates 'part' (part_* / part0) from 'partsupp' (partsupp_*).
  files=$(echo "$ALL_FILES" | grep -E "^${t}[_0-9]" || true)
  if [ -z "$files" ]; then
    echo "  ${t}: no files matched ^${t}[_0-9]" >&2
    exit 1
  fi
  count=$(echo "$files" | wc -l | tr -d ' ')
  echo "${t}: ${count} file(s)"

  dst_prefix="data/sf${SF}/${t}/"

  # Already-converted files in the staging bucket. Multipart uploads commit
  # atomically, so any object listed here was fully uploaded.
  existing=$(aws s3 ls "s3://${STAGING_BUCKET}/${dst_prefix}" --region "$REGION" 2>/dev/null \
    | awk '{print $4}' || true)

  # Pipe stage visibility: clickhouse --progress prints rows/bytes read
  # to stderr; pv (if installed) shows bytes flowing into the upload;
  # aws s3 cp without --quiet shows multipart upload progress. All three
  # write to stderr, so the parquet on stdout stays clean.
  pipe_view() {
    if command -v pv >/dev/null 2>&1; then
      pv -N "$1"
    else
      cat
    fi
  }

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if echo "$existing" | grep -qxF -- "$f"; then
      echo "  ${f} (already converted, skipping)"
      continue
    fi
    src_url="https://s3.${REGION}.amazonaws.com/${SOURCE_BUCKET}/${SOURCE_PREFIX}/${f}"
    dst_url="s3://${STAGING_BUCKET}/${dst_prefix}${f}"
    echo "  ${f}: convert + upload..."
    clickhouse local --progress -q "
      SELECT ${SELECTS[$t]}
      FROM s3('${src_url}', NOSIGN, 'Parquet')
      FORMAT Parquet
      SETTINGS output_format_parquet_compression_method='snappy'
    " | pipe_view "${f}" | aws s3 cp - "${dst_url}"
  done <<< "$files"
done

echo "--- conversion done for sf${SF} ---"
