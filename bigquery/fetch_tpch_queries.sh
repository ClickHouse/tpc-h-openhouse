#!/usr/bin/env bash
set -euo pipefail

# Fetches the TPC-H query suite from ClickHouse/ClickHouse and writes each
# query as an individual file (original filename preserved) into a directory.
# Applies minimal BigQuery-compat patches to queries that use ClickHouse-only
# syntax. Multi-statement files (e.g. query_15.sql) are kept intact and run
# as a script in directory mode by run_bq_bench.sh.
#
# Usage:
#   ./fetch_tpch_queries.sh [output_dir]
# Default output_dir: ./queries

OUT_DIR="${1:-queries}"
API="https://api.github.com/repos/ClickHouse/ClickHouse/contents/tests/benchmarks/tpc-h/queries"
RAW="https://raw.githubusercontent.com/ClickHouse/ClickHouse/master/tests/benchmarks/tpc-h/queries"

need() { command -v "$1" >/dev/null || { echo "ERROR: '$1' not found" >&2; exit 1; }; }
need curl; need jq; need sed

mkdir -p "$OUT_DIR"

echo "Listing queries…" >&2
mapfile -t FILES < <(curl -fsSL "$API" | jq -r '.[].name' | grep -E '\.sql$' | sort)
(( ${#FILES[@]} > 0 )) || { echo "ERROR: no .sql files found" >&2; exit 1; }

# Patch ClickHouse-only syntax to BigQuery-compatible equivalents:
#  1. Strip `-- …` line comments (the bq CLI parses leading `--` as a flag,
#     even inside a quoted query argument, breaking queries that start with
#     comments — query_06, query_11).
#  2. Drop `::Decimal(p,s)` postfix casts (query_06).
#  3. Rewrite `substring(x FROM n FOR m)` → `SUBSTR(x, n, m)` (query_22).
patch_for_bq() {
  sed -E \
    -e '/^[[:space:]]*--/d' \
    -e 's/::Decimal\([0-9]+,[0-9]+\)//g' \
    -e 's/substring\(([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]+FROM[[:space:]]+([0-9]+)[[:space:]]+FOR[[:space:]]+([0-9]+)\)/SUBSTR(\1, \2, \3)/g'
}

# query_15 is CREATE VIEW / SELECT / DROP VIEW. BigQuery requires fully
# qualified table refs inside CREATE VIEW bodies (the `--dataset_id` default
# doesn't apply), so we rewrite it as an equivalent CTE.
Q15_CTE='WITH revenue0 AS (
    SELECT l_suppkey AS supplier_no,
           sum(l_extendedprice * (1 - l_discount)) AS total_revenue
    FROM lineitem
    WHERE l_shipdate >= date '"'"'1996-01-01'"'"'
      AND l_shipdate < date '"'"'1996-01-01'"'"' + INTERVAL 3 MONTH
    GROUP BY l_suppkey
)
SELECT s_suppkey, s_name, s_address, s_phone, total_revenue
FROM supplier, revenue0
WHERE s_suppkey = supplier_no
  AND total_revenue = (SELECT max(total_revenue) FROM revenue0)
ORDER BY s_suppkey;
'

KEPT=0
for f in "${FILES[@]}"; do
  if [[ "$f" == *_sf*.sql ]]; then
    echo "  - $f (skipped: SF-specific variant)" >&2
    continue
  fi
  if [[ "$f" == "query_15.sql" ]]; then
    echo "  + $f (rewritten as CTE)" >&2
    printf '%s' "$Q15_CTE" > "$OUT_DIR/$f"
  else
    echo "  + $f" >&2
    curl -fsSL "$RAW/$f" | patch_for_bq > "$OUT_DIR/$f"
  fi
  KEPT=$((KEPT+1))
done

echo "Wrote $KEPT files → $OUT_DIR/" >&2
