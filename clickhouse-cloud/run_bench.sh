#!/usr/bin/env bash
set -euo pipefail
#
# Run ClickHouse TPC-H queries 3x each and write a JSON doc with results.
# - Reads each *.sql file from ./queries (sorted) as one query (multi-statement OK).
# - Keeps the original timing/grep pipeline intact.
# - Prints progress to stderr; writes the final JSON to BOTH stdout and
#   results/ch_<dataset>[_dqp]_<ts>.json (override dir with RESULTS_DIR env).
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

# Default SET statement applied to EVERY query (baseline and DQP runs alike).
# Edit / extend the SQL below in-place — no env var or CLI flag needed.
# Leave as an empty string to disable the default prefix entirely.
DEFAULT_SETTINGS_SQL="SET enable_parallel_replicas = 0; "

# Extra SET statement appended after DEFAULT_SETTINGS_SQL when DQP_FLAG=1.
DQP_SETTINGS_SQL="SET make_distributed_plan=1, enable_parallel_replicas=0, \
rewrite_in_to_join=1, correlated_subqueries_use_in_memory_buffer=0, \
allow_experimental_correlated_subqueries=1, \
enable_join_runtime_filters=0, \
query_plan_optimize_join_order_algorithm='dpsize greedy', \
allow_statistic_optimize=1, \
use_join_disjunctions_push_down=1, \
distributed_plan_prefer_replicas_over_workers=1, \
distributed_plan_default_shuffle_join_bucket_count=5, \
distributed_plan_default_reader_bucket_count=5;"

SETTINGS_PREFIX=""
[[ -n "$DEFAULT_SETTINGS_SQL" ]] && SETTINGS_PREFIX="${DEFAULT_SETTINGS_SQL} "
if [[ "${DQP_FLAG}" == "1" ]]; then
  SETTINGS_PREFIX="${SETTINGS_PREFIX}${DQP_SETTINGS_SQL} "
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

# --- Collect results, with error detection ------------------------------
# For multi-statement files (e.g. query_15.sql with CREATE/SELECT/DROP VIEW),
# --time prints one decimal per statement; we sum them into a single number.
# A run is considered FAILED if either:
#   - clickhouse client exits non-zero, or
#   - no timing decimal is found in the output (likely a parser/server error).
# On first failure for a given query we print the full client output to
# stderr, record `null` for that try AND for any remaining tries (no
# retries), then move on to the next query so the rest of the suite still
# completes.
FAIL_LOG="$(mktemp -t ch_bench_fail.XXXXXX)"
trap 'rm -f "$FAIL_LOG"' EXIT

RESULT_RAW="$(
for f in "${QUERY_FILES[@]}"; do
    name="$(basename "$f" .sql)"
    query="$(<"$f")"
    full_query="${SETTINGS_PREFIX}${query}"
    echo "Running ${name}..." >&2
    echo -n "["
    ARRAY_VALUES=()
    failed=0
    for i in $(seq 1 $TRIES); do
        if (( failed == 1 )); then
            # Earlier try failed for this query; skip remaining tries.
            val="null"
            ARRAY_VALUES+=("$val")
            echo -n "$val"
            [[ "$i" != $TRIES ]] && echo -n ", "
            continue
        fi

        tmp_out="$(mktemp -t ch_bench_out.XXXXXX)"
        set +e
        "$CLIENT_BIN" client -c "$CLIENT_CONFIG" --database "$DATASET" \
          --time --format=Null --progress 0 --multiquery \
          --query="$full_query" >"$tmp_out" 2>&1
        rc=$?
        set -e

        val=$(awk '
            /^[0-9]+\.[0-9]+$/ { sum += $1; n++ }
            END { if (n > 0) printf "%.3f", sum; else printf "null" }
        ' "$tmp_out")

        err_reason=""
        if (( rc != 0 )); then
            err_reason="exit=${rc}"
        elif [[ "$val" == "null" ]]; then
            err_reason="no-timing"
        fi

        if [[ -n "$err_reason" ]]; then
            val="null"
            failed=1
            {
              echo
              echo "!!! ${name} run ${i}/${TRIES} FAILED (${err_reason}). Skipping remaining tries. Client output:"
              sed 's/^/    | /' "$tmp_out"
              echo
            } >&2
            echo "${name} run ${i}/${TRIES} FAILED (${err_reason})" >> "$FAIL_LOG"
        fi

        rm -f "$tmp_out"

        ARRAY_VALUES+=("$val")
        echo -n "$val"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
    echo "→ [${ARRAY_VALUES[*]}]" >&2
done
)"

if [[ -s "$FAIL_LOG" ]]; then
    fail_count=$(wc -l < "$FAIL_LOG" | tr -d ' ')
    echo >&2
    echo "============================================================" >&2
    echo "FAILED RUNS: ${fail_count}" >&2
    sed 's/^/  - /' "$FAIL_LOG" >&2
    echo "============================================================" >&2
fi

# Make valid JSON arrays (drop trailing comma)
RESULT_CLEAN="$(printf "%s\n" "$RESULT_RAW" | sed '$ s/,\s*$//')"

DATE_ISO="$(date -u +%F)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/results}"
mkdir -p "$RESULTS_DIR"
DQP_SUFFIX=""
[[ "${DQP_FLAG}" == "1" ]] && DQP_SUFFIX="_dqp"
OUT_FILE="$RESULTS_DIR/ch_${DATASET}_${MACHINE}${DQP_SUFFIX}_${TS}.json"

echo >&2
tee "$OUT_FILE" <<JSON
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

# --- Console-only summary: best-of-N per query and total time -----------
# Best time = min over the TRIES tries (ignoring `null` / failed runs).
# Total     = sum of per-query best times (queries with all-null tries are
#             excluded from the sum but still listed).
# Use a read loop (not `mapfile`) so this works on macOS' default bash 3.2.
BEST_TIMES=()
while IFS= read -r _bt_line; do
  BEST_TIMES+=("$_bt_line")
done < <(
  printf '%s\n' "$RESULT_CLEAN" | awk '
    {
      line = $0
      gsub(/[\[\],]/, " ", line)
      best = -1
      n = split(line, vals, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        v = vals[i]
        if (v == "" || v == "null") continue
        x = v + 0
        if (best < 0 || x < best) best = x
      }
      if (best < 0) print "null"
      else printf "%.3f\n", best
    }
  '
)

N_QUERIES=${#QUERY_FILES[@]}
TOTAL_SEC="0"
N_VALID=0

for ((idx = 0; idx < N_QUERIES; idx++)); do
  best="${BEST_TIMES[$idx]:-null}"
  if [[ "$best" != "null" ]]; then
    TOTAL_SEC=$(awk -v a="$TOTAL_SEC" -v b="$best" 'BEGIN { printf "%.6f", a + b }')
    N_VALID=$((N_VALID + 1))
  fi
done

echo >&2
echo "============================================================" >&2
echo "SUMMARY (best of ${TRIES} per query, dataset=${DATASET}, dqp=${DQP_FLAG})" >&2
echo "============================================================" >&2
if (( N_VALID == 0 )); then
  echo "Total time:  N/A (no successful queries)" >&2
else
  TOTAL_FMT=$(awk -v t="$TOTAL_SEC" 'BEGIN { printf "%.3f", t }')
  printf "Total time:  %s sec  (sum of best times across %d/%d queries)\n" \
    "$TOTAL_FMT" "$N_VALID" "$N_QUERIES" >&2
fi
echo "============================================================" >&2