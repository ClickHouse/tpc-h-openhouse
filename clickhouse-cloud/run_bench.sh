#!/usr/bin/env bash
set -euo pipefail

#
# Run ClickHouse Cloud TPC-H queries 3x each and emit JSON to stdout.
#
# Usage:
#   ./run.sh --database DB <system> <machine_desc> <cluster_size> <base_comment> <parallel_replicas_flag> [data_size]
#
# Example:
#   ./run.sh --database sf10 "ClickHouse Cloud (AWS)" "236GiB" 3 "TPC-H SF10" 0 \
#     > results_sf10/clickhouse_cloud_sf10.json
#
# Optional env:
#   QUERY_DIR=queries
#   TRIES=3
#   FQDN=<clickhouse-cloud-host>
#   PASSWORD=<clickhouse-password>
#

DATABASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --database)
      DATABASE="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "$DATABASE" ]]; then
  echo "ERROR: --database is required, e.g. --database sf10" >&2
  exit 1
fi

if [[ $# -lt 5 ]]; then
  echo "Usage: $0 --database DB <system> <machine_desc> <cluster_size> <base_comment> <parallel_replicas_flag> [data_size]" >&2
  exit 1
fi

SYSTEM="$1"
MACHINE="$2"
CLUSTER_SIZE="$3"
BASE_COMMENT="$4"
PARALLEL_FLAG="$5"
DATA_SIZE="${6:-0}"

QUERY_DIR="${QUERY_DIR:-queries}"
TRIES="${TRIES:-3}"

COMMENT="${BASE_COMMENT} (enable_parallel_replicas=${PARALLEL_FLAG})"
PROPRIETARY="yes"
TUNED="no"
TAGS='["C++","column-oriented","ClickHouse derivative","managed","aws"]'
LOAD_TIME=0

FQDN="${FQDN:=localhost}"
PASSWORD="${PASSWORD:=}"

CLIENT_BASE=(
 clickhouse-client
  --host "$FQDN"
  --user "$CLICKHOUSE_USER"
  --database "$DATABASE"
)

if [[ -n "$PASSWORD" ]]; then
  CLIENT_BASE+=(--secure --password "$PASSWORD")
fi

EXTRA_SETTINGS=(
  --enable_parallel_replicas="${PARALLEL_FLAG}"
  --max_parallel_replicas="${CLUSTER_SIZE}"
)

command -v clickhouse-client >/dev/null 2>&1 || {
  echo "ERROR: clickhouse-client not found in PATH" >&2
  exit 1
}

[[ -d "$QUERY_DIR" ]] || {
  echo "ERROR: Query directory '${QUERY_DIR}' not found" >&2
  exit 1
}

if ! [[ "$CLUSTER_SIZE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "ERROR: cluster_size must be numeric because it is emitted as JSON number. Got: ${CLUSTER_SIZE}" >&2
  exit 1
fi

echo "→ Checking ClickHouse connection/database ${DATABASE} ..." >&2

if ! "${CLIENT_BASE[@]}" --query "SELECT 1" >/dev/null; then
  echo "ERROR: Could not connect to ClickHouse database '${DATABASE}' on host '${FQDN}'." >&2
  exit 1
fi

VERSION="$(
  "${CLIENT_BASE[@]}" \
    --format=TSV \
    --query="SELECT version()" 2>/dev/null | tr -d '[:space:]'
)"

if [[ -z "$VERSION" ]]; then
  VERSION="unknown"
fi

QUERY_FILES=()
for i in $(seq -w 1 22); do
  q="${QUERY_DIR}/query_${i}.sql"
  [[ -f "$q" ]] || {
    echo "ERROR: Missing query file: ${q}" >&2
    exit 1
  }
  QUERY_FILES+=("$q")
done

echo "→ ClickHouse version: ${VERSION}" >&2
echo "→ Database: ${DATABASE}" >&2
echo "→ Query dir: ${QUERY_DIR}" >&2
echo "→ Queries: ${#QUERY_FILES[@]}" >&2
echo "→ Machine metadata: ${MACHINE}" >&2
echo "→ Cluster size metadata: ${CLUSTER_SIZE}" >&2
echo "→ Parallel replicas flag: ${PARALLEL_FLAG}" >&2
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
    val="$(
      (
        "${CLIENT_BASE[@]}" \
          --time \
          --format=Null \
          --query="$query" \
          --progress 0 \
          "${EXTRA_SETTINGS[@]}" 2>&1 \
          | grep -o -P '^\d+\.\d+$' \
          || echo -n "null"
      ) | tr -d '\n'
    )"

    arr+=("$val")
    echo -n "$val"
    [[ "$try" != "$TRIES" ]] && echo -n ", "
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
  "version": "$VERSION",
  "date": "$DATE_ISO",
  "machine": "$MACHINE",
  "cluster_size": $CLUSTER_SIZE,
  "proprietary": "$PROPRIETARY",
  "tuned": "$TUNED",
  "comment": "$COMMENT",
  "tags": $TAGS,
  "load_time": $LOAD_TIME,
  "data_size": $DATA_SIZE,
  "database": "$DATABASE",
  "result": [
$RESULT_CLEAN
  ]
}
JSON