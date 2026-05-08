#!/usr/bin/env bash
set -euo pipefail

# Usage:
# WAREHOUSE=BENCH2COST_SMALL ./load_scale.sh sf100
#   ./load_scale.sh <scale>
#
# Example:
#   ./load_scale.sh sf100
#
# Requires:
#   SNOWSQL_ACCOUNT, SNOWSQL_USER, SNOWSQL_PWD

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <sf10|sf100|sf1000>" >&2
  exit 1
fi

SCALE_RAW="$1"
SCALE="${SCALE_RAW^^}"          # sf100 -> SF100
SCALE_LOWER="${SCALE_RAW,,}"    # SF100 -> sf100

DBNAME="${DBNAME:-TPCH_BENCH}"
WAREHOUSE="${WAREHOUSE:-BENCH2COST_XSMALL}"
S3_BASE="${S3_BASE:-s3://public-pme/join_bench/tpc-h}"

: "${SNOWSQL_ACCOUNT:?Set SNOWSQL_ACCOUNT}"
: "${SNOWSQL_USER:?Set SNOWSQL_USER}"
: "${SNOWSQL_PWD:?Set SNOWSQL_PWD}"

echo "→ Checking warehouse ${WAREHOUSE} is usable ..." >&2

if ! snowsql \
  --accountname "$SNOWSQL_ACCOUNT" \
  --username "$SNOWSQL_USER" \
  --warehouse "$WAREHOUSE" \
  -o quiet=true \
  -o friendly=false \
  -o exit_on_error=true \
  --query "SELECT 1;" >/dev/null; then

  echo "ERROR: Warehouse '${WAREHOUSE}' does not exist or is not usable by ${SNOWSQL_USER}." >&2
  echo "Create it first with ./create_warehouses.sh or grant usage on it." >&2
  exit 1
fi

[[ -f ddl_tables.sql ]] || { echo "ddl_tables.sql not found" >&2; exit 1; }

TABLES=(
  nation
  region
  part
  supplier
  partsupp
  customer
  orders
  lineitem
)

declare -A FILES=(
  [nation]="nation_0.parquet"
  [region]="region_0.parquet"
  [part]="part_0.parquet"
  [supplier]="supplier_0.parquet"
  [partsupp]="partsupp_0.parquet"
  [customer]="customer0.parquet"
  [orders]="orders_0.parquet"
  [lineitem]="lineitem_0.parquet"
)



TMP_SQL="$(mktemp)"
trap 'rm -f "$TMP_SQL"' EXIT

cat > "$TMP_SQL" <<SQL
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS ${DBNAME};

CREATE FILE FORMAT IF NOT EXISTS ${DBNAME}.PUBLIC.PARQUET_FORMAT
  TYPE = PARQUET
  USE_VECTORIZED_SCANNER = TRUE;

CREATE SCHEMA IF NOT EXISTS ${DBNAME}.${SCALE};

CREATE OR REPLACE STAGE ${DBNAME}.PUBLIC.TPCH_${SCALE}_STAGE
  URL = '${S3_BASE}/${SCALE_LOWER}/'
  FILE_FORMAT = ${DBNAME}.PUBLIC.PARQUET_FORMAT;

USE DATABASE ${DBNAME};
USE SCHEMA ${SCALE};
SQL

cat ddl_tables.sql >> "$TMP_SQL"

for table in "${TABLES[@]}"; do
  cat >> "$TMP_SQL" <<SQL

COPY INTO ${table}
FROM @${DBNAME}.PUBLIC.TPCH_${SCALE}_STAGE/${FILES[$table]}
FILE_FORMAT = (TYPE = PARQUET)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
SQL
done

cat >> "$TMP_SQL" <<SQL

SELECT
  '${SCALE}' AS scale,
  'nation' AS table_name,
  COUNT(*) AS row_count
FROM nation
UNION ALL
SELECT '${SCALE}', 'region', COUNT(*) FROM region
UNION ALL
SELECT '${SCALE}', 'part', COUNT(*) FROM part
UNION ALL
SELECT '${SCALE}', 'supplier', COUNT(*) FROM supplier
UNION ALL
SELECT '${SCALE}', 'partsupp', COUNT(*) FROM partsupp
UNION ALL
SELECT '${SCALE}', 'customer', COUNT(*) FROM customer
UNION ALL
SELECT '${SCALE}', 'orders', COUNT(*) FROM orders
UNION ALL
SELECT '${SCALE}', 'lineitem', COUNT(*) FROM lineitem
ORDER BY table_name;
SQL

echo "→ Loading ${DBNAME}.${SCALE} from ${S3_BASE}/${SCALE_LOWER}/" >&2

snowsql \
  --accountname "$SNOWSQL_ACCOUNT" \
  --username "$SNOWSQL_USER" \
  --warehouse "$WAREHOUSE" \
  -o exit_on_error=true \
  -o timing=true \
  -f "$TMP_SQL"