#!/usr/bin/env bash
# Provision Redshift Serverless infra for the TPC-H benchmark.
# Idempotent: skips resources that already exist.
#
# Usage:
#   ADMIN_PASSWORD='...' ./provision.sh
#
# Or put values in redshift/.env:
#   ADMIN_PASSWORD=...
#   REGION=eu-west-3
#   BASE_CAPACITY=128

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${REGION:=eu-west-3}"
: "${NAMESPACE:=tpch}"
: "${WORKGROUP:=tpch-wg}"
: "${ADMIN_USER:=dev}"
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD (in .env or env var)}"
: "${DB_NAME:=dev}"
: "${ROLE_NAME:=RedshiftTpchS3}"
: "${BASE_CAPACITY:=128}"
: "${SG_NAME:=redshift-tpch-sg}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "AWS account=${ACCOUNT_ID} region=${REGION}"

# 1. IAM role for COPY (S3 read-only). Even though the source bucket is public,
#    Redshift COPY requires an IAM role to assume.
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role ${ROLE_NAME} exists."
else
  echo "Creating IAM role ${ROLE_NAME}..."
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${SCRIPT_DIR}/trust-policy.json" >/dev/null
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
fi

# 2. Default VPC + subnets (Redshift Serverless workgroups need ≥3 subnets in
#    different AZs; the default VPC always provides this).
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "ERROR: no default VPC in ${REGION}." >&2
  exit 1
fi
echo "Default VPC: ${VPC_ID}"

# Read as space-separated for passing as an unquoted CLI arg list later.
SUBNET_IDS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ' ')

# 3. Security group: ingress on 5439 from current public IP only.
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
  echo "Creating security group ${SG_NAME}..."
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" \
    --description "Redshift TPC-H access" \
    --vpc-id "$VPC_ID" \
    --query GroupId --output text)
fi
echo "Security group: ${SG_ID}"

MY_IP="$(curl -fsS https://checkip.amazonaws.com)/32"
echo "Authorising 5439 from ${MY_IP}..."
aws ec2 authorize-security-group-ingress --region "$REGION" \
  --group-id "$SG_ID" \
  --protocol tcp --port 5439 --cidr "$MY_IP" 2>/dev/null \
  || echo "  (rule already present)"

# 4. Namespace (logical container: DB, admin user, attached IAM roles).
if aws redshift-serverless get-namespace --region "$REGION" \
    --namespace-name "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace ${NAMESPACE} exists."
else
  echo "Creating namespace ${NAMESPACE}..."
  aws redshift-serverless create-namespace --region "$REGION" \
    --namespace-name "$NAMESPACE" \
    --admin-username "$ADMIN_USER" \
    --admin-user-password "$ADMIN_PASSWORD" \
    --db-name "$DB_NAME" \
    --iam-roles "$ROLE_ARN" \
    --default-iam-role-arn "$ROLE_ARN" >/dev/null
fi

# 5. Workgroup (compute). Public + SG-restricted so we can connect from psql
#    on this machine.
if aws redshift-serverless get-workgroup --region "$REGION" \
    --workgroup-name "$WORKGROUP" >/dev/null 2>&1; then
  echo "Workgroup ${WORKGROUP} exists."
else
  echo "Creating workgroup ${WORKGROUP} (base capacity ${BASE_CAPACITY} RPU)..."
  # shellcheck disable=SC2086  # SUBNET_IDS must be word-split here.
  aws redshift-serverless create-workgroup --region "$REGION" \
    --workgroup-name "$WORKGROUP" \
    --namespace-name "$NAMESPACE" \
    --base-capacity "$BASE_CAPACITY" \
    --publicly-accessible \
    --security-group-ids "$SG_ID" \
    --subnet-ids ${SUBNET_IDS} >/dev/null
fi

echo "Waiting for workgroup AVAILABLE..."
while true; do
  STATUS=$(aws redshift-serverless get-workgroup --region "$REGION" \
    --workgroup-name "$WORKGROUP" \
    --query 'workgroup.status' --output text)
  echo "  status=${STATUS}"
  [ "$STATUS" = "AVAILABLE" ] && break
  sleep 15
done

ENDPOINT=$(aws redshift-serverless get-workgroup --region "$REGION" \
  --workgroup-name "$WORKGROUP" \
  --query 'workgroup.endpoint.address' --output text)

# 6. ~/.pgpass so psql can connect without prompts.
PGPASS="${HOME}/.pgpass"
touch "$PGPASS"
chmod 600 "$PGPASS"
LINE="${ENDPOINT}:5439:${DB_NAME}:${ADMIN_USER}:${ADMIN_PASSWORD}"
grep -qF "$LINE" "$PGPASS" || echo "$LINE" >> "$PGPASS"
chmod 600 "$PGPASS"

cat <<EOF

----
FQDN=${ENDPOINT}
ROLE_ARN=${ROLE_ARN}
----

Connect with:
  psql -h ${ENDPOINT} -U ${ADMIN_USER} -d ${DB_NAME} -p 5439

Tear down with:
  ./teardown.sh
EOF
