#!/usr/bin/env bash
# Load TPC-H parquet into Redshift. Delegates the parquet re-encode to
# convert.sh (writes Redshift-compatible parquet to the staging bucket)
# and then runs TRUNCATE + COPY per table.
#
# Run per scale factor:
#   SF=10   ./load.sh
#   SF=100  ./load.sh
#   SF=1000 ./load.sh
#
# To do *only* the conversion (e.g. on EC2 ahead of time, with no Redshift
# work), call ./convert.sh directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${REGION:=eu-west-3}"
: "${WORKGROUP:=tpch-wg}"
: "${ADMIN_USER:=dev}"
: "${DB_NAME:=dev}"
: "${ROLE_NAME:=RedshiftTpchS3}"
: "${SF:?set SF (10, 100, or 1000)}"

SCHEMA="tpch_${SF}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
STAGING_BUCKET="${STAGING_BUCKET:-tpch-redshift-${ACCOUNT_ID}-${REGION}}"

# 1. Re-encode parquet into the staging bucket (skips files already present).
"${SCRIPT_DIR}/convert.sh"

ENDPOINT=$(aws redshift-serverless get-workgroup --region "$REGION" \
  --workgroup-name "$WORKGROUP" \
  --query 'workgroup.endpoint.address' --output text)
echo "Endpoint: ${ENDPOINT}"
echo "Schema:   ${SCHEMA}"

PSQL=(psql -h "$ENDPOINT" -U "$ADMIN_USER" -d "$DB_NAME" -p 5439 -v ON_ERROR_STOP=1)

TABLES=(nation region part supplier partsupp customer orders lineitem)

# 2. TRUNCATE + COPY per table from the staging bucket.
for t in "${TABLES[@]}"; do
  dst_prefix="data/sf${SF}/${t}/"
  echo "  COPY ${SCHEMA}.${t} ..."
  "${PSQL[@]}" -c "TRUNCATE TABLE ${SCHEMA}.${t}; \
    COPY ${SCHEMA}.${t} \
    FROM 's3://${STAGING_BUCKET}/${dst_prefix}' \
    IAM_ROLE '${ROLE_ARN}' \
    FORMAT AS PARQUET \
    REGION '${REGION}';"
done

echo "--- done loading sf${SF} ---"
echo
echo "If COPY fails: SELECT * FROM SYS_LOAD_ERROR_DETAIL ORDER BY start_time DESC LIMIT 5;"
