#!/usr/bin/env bash
set -euo pipefail

# Create Snowflake benchmark warehouses.
#
# Usage:
#   ./create_warehouses.sh
#
# Requires:
#   SNOWSQL_ACCOUNT
#   SNOWSQL_USER
#   SNOWSQL_PWD
#
# Requires file:
#   create_warehouses.sql

: "${SNOWSQL_ACCOUNT:?Set SNOWSQL_ACCOUNT}"
: "${SNOWSQL_USER:?Set SNOWSQL_USER}"
: "${SNOWSQL_PWD:?Set SNOWSQL_PWD}"

SQL_FILE="${SQL_FILE:-create_warehouses.sql}"

command -v snowsql >/dev/null 2>&1 || {
  echo "ERROR: snowsql not found in PATH" >&2
  exit 1
}

[[ -f "$SQL_FILE" ]] || {
  echo "ERROR: $SQL_FILE not found" >&2
  exit 1
}

echo "→ Creating Snowflake warehouses from ${SQL_FILE} ..." >&2

snowsql \
  --accountname "$SNOWSQL_ACCOUNT" \
  --username "$SNOWSQL_USER" \
  -o exit_on_error=true \
  -o timing=true \
  -f "$SQL_FILE"

echo "→ Verifying warehouses ..." >&2

for wh in \
  BENCH2COST_MEDIUM \
  BENCH2COST_4XLARGE \
  BENCH2COST_4XLARGE_GEN2
do
  echo "→ Verifying ${wh} ..." >&2

  if snowsql \
    --accountname "$SNOWSQL_ACCOUNT" \
    --username "$SNOWSQL_USER" \
    --warehouse "$wh" \
    -o quiet=true \
    -o friendly=false \
    -o exit_on_error=true \
    --query "SELECT 1;" >/dev/null; then
    echo "✓ ${wh}" >&2
  else
    echo "ERROR: Warehouse ${wh} does not exist or is not usable by ${SNOWSQL_USER}." >&2
    exit 1
  fi
done

echo "→ Done." >&2