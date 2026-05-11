#!/usr/bin/env bash
set -euo pipefail

# Run full Databricks TPC-H benchmark flow:
#   1. run_bench.py
#   2. collect_metrics_v2.py
#   3. summarize_results.py
#
# Only the final result JSON is kept.
#
# Usage:
#   ./run_full.sh <scale> <machine> <cluster_size> <output_json>
#
# Example:
#   ./run_full.sh sf10 "4X-Large" 528 results_sf10/databricks_sf10_4xlarge.json

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <sf10|sf100|sf1000> <machine> <cluster_size> <output_json>" >&2
  exit 1
fi

SCALE="$1"
MACHINE="$2"
CLUSTER_SIZE="$3"
OUTPUT_JSON="$4"

TRIES="${TRIES:-3}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RUNS_JSON="${TMP_DIR}/runs.json"
METRICS_JSON="${TMP_DIR}/metrics.json"

mkdir -p "$(dirname "$OUTPUT_JSON")"

echo "→ Temporary directory: ${TMP_DIR}" >&2
echo "→ Final output: ${OUTPUT_JSON}" >&2

python run_bench.py \
  --scale "$SCALE" \
  --machine "$MACHINE" \
  --runs "$TRIES" \
  --output "$RUNS_JSON"

python collect_metrics_v2.py \
  --machine "$MACHINE" \
  --input "$RUNS_JSON" \
  --output "$METRICS_JSON"

python summarize_results.py \
  --scale "$SCALE" \
  --machine "$MACHINE" \
  --cluster-size "$CLUSTER_SIZE" \
  --input "$METRICS_JSON" \
  --output "$OUTPUT_JSON"

echo "→ Done. Wrote ${OUTPUT_JSON}" >&2
