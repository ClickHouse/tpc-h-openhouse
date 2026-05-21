# WAREHOUSES="BENCH2COST_MEDIUM BENCH2COST_4XLARGE BENCH2COST_SMALL" ./cleanup_warehouses.sh

cat > cleanup_warehouses.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Drop Snowflake benchmark warehouses.
#
# Usage:
#   ./cleanup_warehouses.sh
#
# Optional env:
#   WAREHOUSES="BENCH2COST_MEDIUM BENCH2COST_4XLARGE"
#
# Requires:
#   SNOWSQL_ACCOUNT
#   SNOWSQL_USER
#   SNOWSQL_PWD

: "${SNOWSQL_ACCOUNT:?Set SNOWSQL_ACCOUNT}"
: "${SNOWSQL_USER:?Set SNOWSQL_USER}"
: "${SNOWSQL_PWD:?Set SNOWSQL_PWD}"

WAREHOUSES="${WAREHOUSES:-BENCH2COST_MEDIUM BENCH2COST_MEDIUM_GEN2 BENCH2COST_LARGE BENCH2COST_LARGE_GEN2 BENCH2COST_4XLARGE BENCH2COST_4XLARGE_GEN2}"

command -v snowsql >/dev/null 2>&1 || {
  echo "ERROR: snowsql not found in PATH" >&2
  exit 1
}

echo "→ Dropping benchmark warehouses: ${WAREHOUSES}" >&2

SQL="USE ROLE ACCOUNTADMIN;"

for wh in $WAREHOUSES; do
  SQL="${SQL}
DROP WAREHOUSE IF EXISTS ${wh};"
done

snowsql \
  --accountname "$SNOWSQL_ACCOUNT" \
  --username "$SNOWSQL_USER" \
  -o exit_on_error=true \
  -o timing=true \
  --query "$SQL"

echo "→ Verifying warehouses were dropped ..." >&2

for wh in $WAREHOUSES; do
  if snowsql \
    --accountname "$SNOWSQL_ACCOUNT" \
    --username "$SNOWSQL_USER" \
    -o quiet=true \
    -o friendly=false \
    --query "SHOW WAREHOUSES LIKE '${wh}';" \
    | grep -qi "$wh"; then

    echo "ERROR: Warehouse ${wh} still exists." >&2
    exit 1
  else
    echo "✓ ${wh} dropped or absent" >&2
  fi
done

echo "→ Done." >&2
EOF

chmod +x cleanup_warehouses.sh