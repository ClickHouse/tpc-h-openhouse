#!/usr/bin/env bash
# Load TPC-H parquet from the public-pme bucket into Redshift.
#
# Why the conversion step: ClickHouse wrote the source files with FixedString
# columns, which become FIXED_LEN_BYTE_ARRAY (no UTF8 logical type) in parquet.
# Redshift's COPY won't read that into any string-like column. So we stream
# each file through clickhouse-local, CAST(FixedString -> String) and widen
# UInt/Int -> Int64, output snappy parquet, and pipe to aws s3 cp into the
# staging bucket under a per-table prefix. Then COPY by prefix straight into
# the final table — no manifests, no stage tables.
#
# Run per scale factor:
#   SF=10   ./load.sh
#   SF=100  ./load.sh
#   SF=1000 ./load.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${REGION:=eu-west-3}"
: "${WORKGROUP:=tpch-wg}"
: "${ADMIN_USER:=dev}"
: "${DB_NAME:=dev}"
: "${ROLE_NAME:=RedshiftTpchS3}"
: "${SF:?set SF (10, 100, or 1000)}"
: "${SOURCE_BUCKET:=public-pme}"
: "${SOURCE_PREFIX:=join_bench/tpc-h/sf${SF}}"

if ! command -v clickhouse >/dev/null 2>&1; then
  echo "ERROR: clickhouse not found. Install via 'brew install clickhouse'." >&2
  exit 1
fi

SCHEMA="tpch_${SF}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
STAGING_BUCKET="${STAGING_BUCKET:-tpch-redshift-${ACCOUNT_ID}-${REGION}}"

# Staging bucket: holds the converted parquet files.
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

ENDPOINT=$(aws redshift-serverless get-workgroup --region "$REGION" \
  --workgroup-name "$WORKGROUP" \
  --query 'workgroup.endpoint.address' --output text)
echo "Endpoint: ${ENDPOINT}"
echo "Schema:   ${SCHEMA}"

PSQL=(psql -h "$ENDPOINT" -U "$ADMIN_USER" -d "$DB_NAME" -p 5439 -v ON_ERROR_STOP=1)

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

# List source files once.
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

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    src_url="https://s3.${REGION}.amazonaws.com/${SOURCE_BUCKET}/${SOURCE_PREFIX}/${f}"
    dst_url="s3://${STAGING_BUCKET}/${dst_prefix}${f}"
    echo "  convert ${f}..."
    clickhouse local -q "
      SELECT ${SELECTS[$t]}
      FROM s3('${src_url}', NOSIGN, 'Parquet')
      FORMAT Parquet
      SETTINGS output_format_parquet_compression_method='snappy'
    " | aws s3 cp - "${dst_url}" --quiet
  done <<< "$files"

  echo "  COPY ${SCHEMA}.${t} ..."
  "${PSQL[@]}" -c "COPY ${SCHEMA}.${t} \
    FROM 's3://${STAGING_BUCKET}/${dst_prefix}' \
    IAM_ROLE '${ROLE_ARN}' \
    FORMAT AS PARQUET \
    REGION '${REGION}';"
done

echo "--- done loading sf${SF} ---"
echo
echo "If COPY fails: SELECT * FROM SYS_LOAD_ERROR_DETAIL ORDER BY start_time DESC LIMIT 5;"
