#!/usr/bin/env bash
set -euo pipefail

#
# Run Snowflake TPC-H benchmark and emit JSON runtimes to stdout.
#
# Usage:
#   WAREHOUSE=<warehouse> ./run.sh <scale> <db> <machine> <cluster_size>
#
# Example:
#   WAREHOUSE=BENCH2COST_MEDIUM ./run.sh sf10 TPCH_BENCH "Medium" 4 \
#     > results/snowflake_sf10_medium.json
#
#   WAREHOUSE=BENCH2COST_4XLARGE ./run.sh sf10 TPCH_BENCH "4X-Large" 128 \
#     > results/snowflake_sf10_4xlarge.json
#
# Optional env:
#   QUERY_DIR=queries
#   TRIES=3
#
# Required env:
#   WAREHOUSE
#   SNOWSQL_ACCOUNT
#   SNOWSQL_USER
#   SNOWSQL_PWD
#

if [[ $# -ne 4 ]]; then
  echo "Usage: WAREHOUSE=<warehouse> $0 <sf10|sf100|sf1000> <db> <machine> <cluster_size>" >&2
  exit 1
fi

SCALE_RAW="$1"
DBNAME="$2"
MACHINE="$3"
CLUSTER_SIZE="$4"

WAREHOUSE="${WAREHOUSE:?Set WAREHOUSE, e.g. WAREHOUSE=BENCH2COST_MEDIUM}"
QUERY_DIR="${QUERY_DIR:-queries}"
TRIES="${TRIES:-3}"

SCALE="${SCALE_RAW^^}"

case "$SCALE" in
  SF10|SF100|SF1000)
    ;;
  *)
    echo "ERROR: Invalid scale '${SCALE_RAW}'. Expected sf10, sf100, or sf1000." >&2
    exit 1
    ;;
esac

if ! [[ "$CLUSTER_SIZE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "ERROR: cluster_size must be numeric because it is emitted as a JSON number. Got: ${CLUSTER_SIZE}" >&2
  exit 1
fi

SCHEMA="$SCALE"

: "${SNOWSQL_ACCOUNT:?Set SNOWSQL_ACCOUNT}"
: "${SNOWSQL_USER:?Set SNOWSQL_USER}"
: "${SNOWSQL_PWD:?Set SNOWSQL_PWD}"

SYSTEM="Snowflake"
PROPRIETARY="yes"
TUNED="no"
TAGS='["managed","column-oriented"]'
LOAD_TIME=0
DATA_SIZE=0
COMMENT=""

command -v snowsql >/dev/null 2>&1 || {
  echo "ERROR: snowsql not found in PATH" >&2
  exit 1
}

[[ -d "$QUERY_DIR" ]] || {
  echo "ERROR: Query directory '${QUERY_DIR}' not found" >&2
  exit 1
}

echo "→ Waking warehouse ${WAREHOUSE} ..." >&2

if ! snowsql \
  --accountname "$SNOWSQL_ACCOUNT" \
  --username "$SNOWSQL_USER" \
  -o quiet=true \
  -o friendly=false \
  -o exit_on_error=true \
  --query "ALTER WAREHOUSE IF EXISTS ${WAREHOUSE} RESUME IF SUSPENDED;" >/dev/null; then

  echo "ERROR: Warehouse '${WAREHOUSE}' does not exist or cannot be resumed by ${SNOWSQL_USER}." >&2
  echo "Create it first with ./create_warehouses.sh or grant usage on it." >&2
  exit 1
fi

echo "→ Waiting for warehouse ${WAREHOUSE} to accept queries ..." >&2

for attempt in $(seq 1 60); do
  if snowsql \
    --accountname "$SNOWSQL_ACCOUNT" \
    --username "$SNOWSQL_USER" \
    --warehouse "$WAREHOUSE" \
    -o quiet=true \
    -o friendly=false \
    -o exit_on_error=true \
    --query "SELECT 1;" >/dev/null; then

    echo "→ Warehouse ${WAREHOUSE} is ready." >&2
    break
  fi

  if [[ "$attempt" -eq 60 ]]; then
    echo "ERROR: Warehouse '${WAREHOUSE}' did not become ready after 60 attempts." >&2
    exit 1
  fi

  echo "   → still waiting (${attempt}/60) ..." >&2
  sleep 5
done

ARGS=(
  --accountname "$SNOWSQL_ACCOUNT"
  --username "$SNOWSQL_USER"
  --dbname "$DBNAME"
  --schemaname "$SCHEMA"
  --warehouse "$WAREHOUSE"
  -o timing=true
  -o exit_on_error=true
  -o quiet=false
  -o friendly=false
)

echo "→ Checking database/schema connection: ${DBNAME}.${SCHEMA} ..." >&2
snowsql "${ARGS[@]}" --query "SELECT 1;" >/dev/null

echo "→ Disabling result cache for user ${SNOWSQL_USER} ..." >&2
snowsql "${ARGS[@]}" --query "ALTER USER ${SNOWSQL_USER} SET USE_CACHED_RESULT = false;" >/dev/null

QUERY_FILES=()
for i in $(seq -w 1 22); do
  q="${QUERY_DIR}/query_${i}.sql"
  [[ -f "$q" ]] || {
    echo "ERROR: Missing query file: ${q}" >&2
    exit 1
  }
  QUERY_FILES+=("$q")
done

echo "→ Running ${#QUERY_FILES[@]} TPC-H queries on ${DBNAME}.${SCHEMA} using ${WAREHOUSE}" >&2
echo "→ Machine metadata: ${MACHINE}" >&2
echo "→ Cluster size metadata: ${CLUSTER_SIZE}" >&2
echo "→ Tries per query: ${TRIES}" >&2

RESULT_RAW="$(
query_num=1

for query_file in "${QUERY_FILES[@]}"; do
  query="$(sed 's/[[:space:]]*$//' "$query_file")"
  query="$(printf "%s\n" "$query" | sed '$ s/;[[:space:]]*$//')"

  echo "→ Running ${query_file} as query #${query_num} ..." >&2

  echo -n "["
  arr=()

  for try in $(seq 1 "$TRIES"); do
    out="$(snowsql "${ARGS[@]}" --query "$query" 2>&1 || true)"

    val="$(
      printf "%s\n" "$out" \
        | grep -Eo 'Time Elapsed:[[:space:]]*[0-9.]+s' \
        | sed -E 's/.*[[:space:]]([0-9.]+)s/\1/' \
        | tail -n1
    )"

    if [[ -z "$val" ]]; then
      echo "WARNING: Could not extract runtime for ${query_file}, try ${try}" >&2
      echo "$out" >&2
      val="null"
    fi

    arr+=("$val")
    echo -n "$val"
    [[ "$try" != "$TRIES" ]] && echo -n ","
  done

  echo "],"
  echo "   -> [${arr[*]}]" >&2

  query_num=$((query_num + 1))
done
)"

RESULT_CLEAN="$(printf "%s\n" "$RESULT_RAW" | sed '$ s/,\s*$//')"
DATE_ISO="$(date -u +%F)"

cat <<JSON
{
  "system": "$SYSTEM",
  "date": "$DATE_ISO",
  "machine": "$MACHINE",
  "cluster_size": $CLUSTER_SIZE,
  "comment": "$COMMENT",
  "proprietary": "$PROPRIETARY",
  "tuned": "$TUNED",
  "tags": $TAGS,
  "load_time": $LOAD_TIME,
  "data_size": $DATA_SIZE,
  "scale": "$SCALE",
  "database": "$DBNAME",
  "schema": "$SCHEMA",
  "warehouse": "$WAREHOUSE",
  "result": [
$RESULT_CLEAN
  ]
}
JSON
EOF

chmod +x run.sh