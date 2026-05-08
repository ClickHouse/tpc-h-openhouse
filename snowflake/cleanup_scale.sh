cat > cleanup_scale.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Drop all TPC-H tables for one scale schema.
#
# Usage:
#   ./cleanup_scale.sh <sf10|sf100|sf1000>
#
# Optional env:
#   DBNAME=TPCH_BENCH
#
# Requires:
#   SNOWSQL_ACCOUNT
#   SNOWSQL_USER
#   SNOWSQL_PWD

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <sf10|sf100|sf1000>" >&2
  exit 1
fi

SCALE_RAW="$1"
SCALE="${SCALE_RAW^^}"
DBNAME="${DBNAME:-TPCH_BENCH}"

: "${SNOWSQL_ACCOUNT:?Set SNOWSQL_ACCOUNT}"
: "${SNOWSQL_USER:?Set SNOWSQL_USER}"
: "${SNOWSQL_PWD:?Set SNOWSQL_PWD}"

case "$SCALE" in
  SF10|SF100|SF1000)
    ;;
  *)
    echo "ERROR: Invalid scale '${SCALE_RAW}'. Expected sf10, sf100, or sf1000." >&2
    exit 1
    ;;
esac

command -v snowsql >/dev/null 2>&1 || {
  echo "ERROR: snowsql not found in PATH" >&2
  exit 1
}

echo "→ Dropping TPC-H tables in ${DBNAME}.${SCALE} ..." >&2

snowsql \
  --accountname "$SNOWSQL_ACCOUNT" \
  --username "$SNOWSQL_USER" \
  -o exit_on_error=true \
  -o timing=true \
  --query "
USE ROLE ACCOUNTADMIN;
USE DATABASE ${DBNAME};
USE SCHEMA ${SCALE};

DROP TABLE IF EXISTS lineitem;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS partsupp;
DROP TABLE IF EXISTS supplier;
DROP TABLE IF EXISTS part;
DROP TABLE IF EXISTS nation;
DROP TABLE IF EXISTS region;
"

echo "→ Done. Dropped TPC-H tables from ${DBNAME}.${SCALE}." >&2
EOF

chmod +x cleanup_scale.sh