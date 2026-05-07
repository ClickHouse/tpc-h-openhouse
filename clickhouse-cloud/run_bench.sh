#!/usr/bin/env bash
set -euo pipefail
#
# Run ClickHouse TPC-H queries 3x each and write a JSON doc with results.
# - Reads each *.sql file from ./queries (sorted) as one query (multi-statement OK).
# - Keeps the original timing/grep pipeline intact.
# - Prints progress to stderr; writes the final JSON to results/ch_<dataset>_<ts>.json.
#
# Required env:
#   DATASET   ClickHouse database to use (e.g. sf10, sf100, sf1000)
#
# Usage:
#   DATASET=<db> ./run_bench.sh <system> <machine_desc> <cluster_size> <base_comment> <dqp_flag>
# Example:
#   DATASET=sf10  ./run_bench.sh "ClickHouse Cloud (AWS)" "236GiB" 3 "1B rows" 0
#   DATASET=sf100 ./run_bench.sh "ClickHouse Cloud (AWS)" "236GiB" 3 "1B rows" 1   # enable distributed query plan
# ---------------------------------------------------------------------------

if [[ $# -lt 5 ]]; then
  echo "Usage: DATASET=<db> $0 <system> <machine_desc> <cluster_size> <base_comment> <dqp_flag>" >&2
  exit 1
fi

if [[ -z "${DATASET:-}" ]]; then
  echo "ERROR: DATASET env var is not set (e.g. DATASET=sf10)." >&2
  echo "Usage: DATASET=<db> $0 <system> <machine_desc> <cluster_size> <base_comment> <dqp_flag>" >&2
  exit 1
fi

SYSTEM="$1"
MACHINE="$2"
CLUSTER_SIZE="$3"
BASE_COMMENT="$4"
DQP_FLAG="${5}" # 0 or 1

COMMENT="${BASE_COMMENT} (dataset=${DATASET}, Distributed_Query_Plans=${DQP_FLAG})"
PROPRIETARY="yes"
TUNED="no"
TAGS='["C++","column-oriented","ClickHouse derivative","managed","aws"]'
LOAD_TIME=0
DATA_SIZE=0

# Client: connection settings come from clickhouse-client.xml (host/user/password/secure).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_BIN="${CLIENT_BIN:-$HOME/work/clickhouse-dist/clickhouse}"
CLIENT_CONFIG="${CLIENT_CONFIG:-$SCRIPT_DIR/clickhouse-client.xml}"

SETTINGS_PREFIX=""
if [[ "${DQP_FLAG}" == "1" ]]; then
  # Enables distributed query plan.
  SETTINGS_PREFIX="SET make_distributed_plan = 1, enable_cascades_optimizer = 1; "
fi

TRIES=3

# --- Collect *.sql files from ./queries (sorted, multi-statement OK) ---
QUERIES_DIR="${QUERIES_DIR:-$SCRIPT_DIR/queries}"
shopt -s nullglob
QUERY_FILES=("$QUERIES_DIR"/*.sql)
shopt -u nullglob
IFS=$'\n' QUERY_FILES=($(printf '%s\n' "${QUERY_FILES[@]}" | sort)); unset IFS

TOTAL=${#QUERY_FILES[@]}
echo "Parsed queries: ${TOTAL} (from ${QUERIES_DIR})" >&2
if (( TOTAL == 0 )); then
  echo "ERROR: No .sql files found in ${QUERIES_DIR}" >&2
  exit 1
fi

# --- Collect results using the original timing/grep pipeline ---
# For multi-statement files (e.g. query_15.sql with CREATE/SELECT/DROP VIEW),
# --time prints one decimal per statement; we sum them into a single number.
RESULT_RAW="$(
for f in "${QUERY_FILES[@]}"; do
    name="$(basename "$f" .sql)"
    query="$(<"$f")"
    full_query="${SETTINGS_PREFIX}${query}"
    echo "Running ${name}..." >&2
    echo -n "["
    ARRAY_VALUES=()
    for i in $(seq 1 $TRIES); do
        val=$(
          "$CLIENT_BIN" client -c "$CLIENT_CONFIG" --database "$DATASET" \
            --time --format=Null --progress 0 --multiquery \
            --query="$full_query" 2>&1 |
            awk '
              /^[0-9]+\.[0-9]+$/ { sum += $1; n++ }
              END { if (n > 0) printf "%.3f", sum; else printf "null" }
            '
        )
        ARRAY_VALUES+=("$val")
        echo -n "$val"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
    echo "→ [${ARRAY_VALUES[*]}]" >&2
done
)"

# Make valid JSON arrays (drop trailing comma)
RESULT_CLEAN="$(printf "%s\n" "$RESULT_RAW" | sed '$ s/,\s*$//')"

DATE_ISO="$(date -u +%F)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results}"
mkdir -p "$RESULTS_DIR"
DQP_SUFFIX=""
[[ "${DQP_FLAG}" == "1" ]] && DQP_SUFFIX="_dqp"
OUT_FILE="$RESULTS_DIR/ch_${DATASET}${DQP_SUFFIX}_${TS}.json"

tee "$OUT_FILE" >/dev/null <<JSON
{
    "system": "$SYSTEM",
    "date": "$DATE_ISO",
    "machine": "$MACHINE",
    "cluster_size": $CLUSTER_SIZE,
    "proprietary": "$PROPRIETARY",
    "tuned": "$TUNED",
    "comment": "$COMMENT",

    "tags": $TAGS,

    "load_time": $LOAD_TIME,
    "data_size": $DATA_SIZE,

    "result": [
$RESULT_CLEAN
    ]
}
JSON

echo "" >&2
echo "Wrote results → $OUT_FILE" >&2