#!/usr/bin/env bash
# Tear down everything provision.sh created. Safe to re-run.
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
: "${ROLE_NAME:=RedshiftTpchS3}"
: "${SG_NAME:=redshift-tpch-sg}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STAGING_BUCKET="${STAGING_BUCKET:-tpch-redshift-${ACCOUNT_ID}-${REGION}}"

echo "Region: ${REGION}"

# 1. Workgroup. Must go first; namespace can't be deleted while a workgroup
#    references it.
if aws redshift-serverless get-workgroup --region "$REGION" \
    --workgroup-name "$WORKGROUP" >/dev/null 2>&1; then
  echo "Deleting workgroup ${WORKGROUP}..."
  aws redshift-serverless delete-workgroup --region "$REGION" \
    --workgroup-name "$WORKGROUP" >/dev/null
  echo "Waiting for workgroup deletion..."
  while aws redshift-serverless get-workgroup --region "$REGION" \
      --workgroup-name "$WORKGROUP" >/dev/null 2>&1; do
    sleep 10
  done
else
  echo "Workgroup ${WORKGROUP} not present."
fi

# 2. Namespace. By default no final snapshot is taken.
if aws redshift-serverless get-namespace --region "$REGION" \
    --namespace-name "$NAMESPACE" >/dev/null 2>&1; then
  echo "Deleting namespace ${NAMESPACE}..."
  aws redshift-serverless delete-namespace --region "$REGION" \
    --namespace-name "$NAMESPACE" >/dev/null
  while aws redshift-serverless get-namespace --region "$REGION" \
      --namespace-name "$NAMESPACE" >/dev/null 2>&1; do
    sleep 10
  done
else
  echo "Namespace ${NAMESPACE} not present."
fi

# 3. IAM role.
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Detaching + deleting IAM role ${ROLE_NAME}..."
  aws iam detach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME"
else
  echo "IAM role ${ROLE_NAME} not present."
fi

# 4. Staging bucket (manifests). Empty + delete.
if aws s3api head-bucket --bucket "$STAGING_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Emptying + deleting staging bucket ${STAGING_BUCKET}..."
  aws s3 rm "s3://${STAGING_BUCKET}" --recursive --quiet --region "$REGION" || true
  aws s3api delete-bucket --bucket "$STAGING_BUCKET" --region "$REGION"
else
  echo "Staging bucket ${STAGING_BUCKET} not present."
fi

# 5. Security group.
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo None)
if [ "$VPC_ID" != "None" ] && [ -n "$VPC_ID" ]; then
  SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
  if [ "$SG_ID" != "None" ] && [ -n "$SG_ID" ]; then
    echo "Deleting security group ${SG_ID}..."
    aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID"
  else
    echo "Security group ${SG_NAME} not present."
  fi
fi

echo "--- teardown done ---"
