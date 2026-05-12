#!/usr/bin/env bash
# Import a single TPC-H table from S3 into ClickHouse.
# Usage: import_table.sh <db> <table>
set -uo pipefail

DB="${1:?db required (sf10|sf100|sf1000)}"
TABLE="${2:?table required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/clickhouse-client.xml"
LOG_DIR="${SCRIPT_DIR}/logs/${DB}"
PROGRESS="${SCRIPT_DIR}/logs/progress.tsv"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/${TABLE}.log"

declare -A FILES=(
  [nation]=nation_0.parquet
  [region]=region_0.parquet
  [part]=part_0.parquet
  [supplier]=supplier_0.parquet
  [partsupp]=partsupp_0.parquet
  [customer]=customer0.parquet
  [orders]=orders_0.parquet
  [lineitem]=lineitem_0.parquet
)

FILE="${FILES[$TABLE]:-}"
if [[ -z "${FILE}" ]]; then
  echo "Unknown table: ${TABLE}" >&2
  exit 2
fi

S3_URL="https://public-pme.s3.amazonaws.com/join_bench/tpc-h/${DB}/${FILE}"

# Per-table SELECT projection. FixedString columns are padded with spaces to
# the exact length, because Parquet stores VARCHAR/CHAR as variable-length
# String and ClickHouse rejects shorter inputs into FixedString(N).
case "${TABLE}" in
  nation)
    SELECT_SQL="
      SELECT
        n_nationkey,
        toFixedString(rpad(n_name, 25, ' '), 25),
        n_regionkey,
        n_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  region)
    SELECT_SQL="
      SELECT
        r_regionkey,
        toFixedString(rpad(r_name, 25, ' '), 25),
        r_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  part)
    SELECT_SQL="
      SELECT
        p_partkey,
        p_name,
        toFixedString(rpad(p_mfgr, 25, ' '), 25),
        toFixedString(rpad(p_brand, 10, ' '), 10),
        p_type,
        p_size,
        toFixedString(rpad(p_container, 10, ' '), 10),
        p_retailprice,
        p_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  supplier)
    SELECT_SQL="
      SELECT
        s_suppkey,
        toFixedString(rpad(s_name, 25, ' '), 25),
        s_address,
        s_nationkey,
        toFixedString(rpad(s_phone, 15, ' '), 15),
        s_acctbal,
        s_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  partsupp)
    SELECT_SQL="
      SELECT
        ps_partkey,
        ps_suppkey,
        ps_availqty,
        ps_supplycost,
        ps_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  customer)
    SELECT_SQL="
      SELECT
        c_custkey,
        c_name,
        c_address,
        c_nationkey,
        toFixedString(rpad(c_phone, 15, ' '), 15),
        c_acctbal,
        toFixedString(rpad(c_mktsegment, 10, ' '), 10),
        c_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  orders)
    SELECT_SQL="
      SELECT
        o_orderkey,
        o_custkey,
        toFixedString(rpad(o_orderstatus, 1, ' '), 1),
        o_totalprice,
        o_orderdate,
        toFixedString(rpad(o_orderpriority, 15, ' '), 15),
        toFixedString(rpad(o_clerk, 15, ' '), 15),
        o_shippriority,
        o_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  lineitem)
    SELECT_SQL="
      SELECT
        l_orderkey,
        l_partkey,
        l_suppkey,
        l_linenumber,
        l_quantity,
        l_extendedprice,
        l_discount,
        l_tax,
        toFixedString(rpad(l_returnflag, 1, ' '), 1),
        toFixedString(rpad(l_linestatus, 1, ' '), 1),
        l_shipdate,
        l_commitdate,
        l_receiptdate,
        toFixedString(rpad(l_shipinstruct, 25, ' '), 25),
        toFixedString(rpad(l_shipmode, 10, ' '), 10),
        l_comment
      FROM s3('${S3_URL}', NOSIGN, 'Parquet')
    " ;;
  *)
    echo "Unknown table: ${TABLE}" >&2
    exit 2
    ;;
esac

CH=(clickhouse-client
    --config-file="${CONFIG}"
    --max_execution_time 0
    --max_insert_threads 16
    --max_threads 16
    --min_insert_block_size_bytes "$((512*1024*1024))"
    --min_insert_block_size_rows 1048576
    --input_format_null_as_default 1
    --input_format_parquet_case_insensitive_column_matching 1
    --s3_max_connections 100
    --send_logs_level error)

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

{
  echo "==== $(ts) START db=${DB} table=${TABLE} url=${S3_URL}"
} >> "${LOG}"

start_epoch=$(date +%s)
status="FAIL"
attempts=3
for i in $(seq 1 ${attempts}); do
  echo "---- $(ts) attempt ${i}/${attempts}: TRUNCATE" >> "${LOG}"
  if ! "${CH[@]}" --query "TRUNCATE TABLE IF EXISTS ${DB}.${TABLE}" >> "${LOG}" 2>&1; then
    echo "---- $(ts) attempt ${i}/${attempts}: TRUNCATE failed" >> "${LOG}"
    sleep 30
    continue
  fi
  echo "---- $(ts) attempt ${i}/${attempts}: INSERT" >> "${LOG}"
  if "${CH[@]}" --query "INSERT INTO ${DB}.${TABLE} ${SELECT_SQL}" >> "${LOG}" 2>&1; then
    status="OK"
    break
  fi
  echo "---- $(ts) attempt ${i}/${attempts}: INSERT failed" >> "${LOG}"
  sleep 30
done

end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))

# Capture row count + on-disk bytes for the progress file.
rows=""
bytes=""
if [[ "${status}" == "OK" ]]; then
  read -r rows bytes < <(clickhouse-client --config-file="${CONFIG}" \
      --query "SELECT total_rows, total_bytes FROM system.tables WHERE database='${DB}' AND name='${TABLE}' FORMAT TSV" 2>>"${LOG}") || true
fi

echo "==== $(ts) END   db=${DB} table=${TABLE} status=${status} rows=${rows:-?} bytes=${bytes:-?} duration_s=${duration}" >> "${LOG}"

# Append to global progress.tsv with a small lock to avoid interleaved writes.
{
  flock 9
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(ts)" "${DB}" "${TABLE}" "${status}" "${rows:-}" "${bytes:-}" "${duration}" >> "${PROGRESS}"
} 9>>"${PROGRESS}.lock"

[[ "${status}" == "OK" ]] || exit 1
exit 0
