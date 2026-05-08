#!/usr/bin/env bash
# Spin up an EC2 in the same region as your Redshift workgroup, run
# convert.sh on it (multi-Gbps S3 throughput), then tear it down.
#
# Conversion only — does NOT touch Redshift. After it finishes, run
# `./load.sh` from your laptop; the convert step there will skip every
# file (already in the staging bucket) and just issue TRUNCATE+COPY.
#
# Usage:
#   SF=1000 ./ec2-convert.sh up      # provision + start tmux conversion
#           ./ec2-convert.sh attach  # SSM into the running tmux
#           ./ec2-convert.sh down    # terminate the instance
#
# Requires the AWS Session Manager plugin for `attach`:
#   brew install --cask session-manager-plugin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${REGION:=eu-west-3}"
: "${INSTANCE_TYPE:=c7i.4xlarge}"
: "${INSTANCE_NAME:=tpch-convert}"
: "${EC2_ROLE_NAME:=EC2TpchConvert}"
: "${EC2_INSTANCE_PROFILE:=EC2TpchConvert}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STAGING_BUCKET="${STAGING_BUCKET:-tpch-redshift-${ACCOUNT_ID}-${REGION}}"

MODE="${1:-up}"

# Find a non-terminated instance with our Name tag (returns empty if none).
find_instance_id() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null \
    | tr -d '\n' | awk '$1!="None"{print $1}'
}

case "$MODE" in
  up)
    : "${SF:?set SF (10, 100, or 1000)}"

    [ -f "${SCRIPT_DIR}/convert.sh" ] || {
      echo "ERROR: ${SCRIPT_DIR}/convert.sh not found" >&2
      exit 1
    }

    EXISTING=$(find_instance_id)
    if [ -n "$EXISTING" ]; then
      echo "Instance ${EXISTING} already exists (Name=${INSTANCE_NAME})."
      echo "Use '$0 attach' or '$0 down' first."
      exit 1
    fi

    # 1. Staging bucket (idempotent).
    if ! aws s3api head-bucket --bucket "$STAGING_BUCKET" --region "$REGION" 2>/dev/null; then
      echo "Creating staging bucket ${STAGING_BUCKET}..."
      if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$STAGING_BUCKET" --region "$REGION" >/dev/null
      else
        aws s3api create-bucket --bucket "$STAGING_BUCKET" --region "$REGION" \
          --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
      fi
    fi

    # 2. Upload bootstrap files (convert.sh + .env if present).
    echo "Uploading bootstrap files to s3://${STAGING_BUCKET}/bootstrap/ ..."
    aws s3 cp "${SCRIPT_DIR}/convert.sh" \
      "s3://${STAGING_BUCKET}/bootstrap/convert.sh" \
      --region "$REGION" --quiet
    if [ -f "${SCRIPT_DIR}/.env" ]; then
      aws s3 cp "${SCRIPT_DIR}/.env" \
        "s3://${STAGING_BUCKET}/bootstrap/.env" \
        --region "$REGION" --quiet
    fi

    # 3. IAM role + instance profile (S3FullAccess + SSM core).
    if ! aws iam get-role --role-name "$EC2_ROLE_NAME" >/dev/null 2>&1; then
      echo "Creating IAM role ${EC2_ROLE_NAME}..."
      aws iam create-role --role-name "$EC2_ROLE_NAME" \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
        }' >/dev/null
      aws iam attach-role-policy --role-name "$EC2_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
      aws iam attach-role-policy --role-name "$EC2_ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    fi
    if ! aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null 2>&1; then
      echo "Creating instance profile ${EC2_INSTANCE_PROFILE}..."
      aws iam create-instance-profile \
        --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null
      aws iam add-role-to-instance-profile \
        --instance-profile-name "$EC2_INSTANCE_PROFILE" \
        --role-name "$EC2_ROLE_NAME"
      # IAM is eventually consistent; brief wait avoids run-instances 400.
      sleep 10
    fi

    # 4. Latest Amazon Linux 2023 *standard* AMI (x86_64). Use the SSM-published
    #    public parameter so we don't accidentally match the al2023-ami-minimal-*
    #    images, which don't ship the SSM agent (instances would never register
    #    with SSM and 'attach' / 'tail' would never work).
    echo "Looking up latest AL2023 AMI..."
    AMI_ID=$(aws ssm get-parameter --region "$REGION" \
      --name '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64' \
      --query 'Parameter.Value' --output text)
    [ -n "$AMI_ID" ] && [ "$AMI_ID" != "None" ] || { echo "No AL2023 AMI found"; exit 1; }
    echo "  AMI: $AMI_ID"

    # 5. UserData: install clickhouse + tmux, fetch convert.sh, run in tmux.
    USER_DATA=$(cat <<USERDATA
#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1
echo "[user-data] start \$(date)"

dnf install -y tmux pv

cd /tmp
curl -sL https://clickhouse.com/ | bash
mv ./clickhouse /usr/local/bin/
chmod +x /usr/local/bin/clickhouse

mkdir -p /opt/convert
aws s3 cp s3://${STAGING_BUCKET}/bootstrap/convert.sh /opt/convert/convert.sh --region ${REGION}
aws s3 cp s3://${STAGING_BUCKET}/bootstrap/.env /opt/convert/.env --region ${REGION} || true
chmod +x /opt/convert/convert.sh

# Start convert in a detached tmux session (root). On finish, hold the
# pane open so the operator can see exit messages on attach.
tmux new-session -d -s convert "SF=${SF} REGION=${REGION} STAGING_BUCKET=${STAGING_BUCKET} bash /opt/convert/convert.sh 2>&1 | tee /tmp/convert.log; echo; echo '*** convert finished — press Enter to close ***'; read"

echo "[user-data] done \$(date)"
USERDATA
)

    # 6. Launch.
    echo "Launching ${INSTANCE_TYPE} in ${REGION}..."
    INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
      --image-id "$AMI_ID" \
      --instance-type "$INSTANCE_TYPE" \
      --iam-instance-profile "Name=${EC2_INSTANCE_PROFILE}" \
      --user-data "$USER_DATA" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
      --query 'Instances[0].InstanceId' --output text)
    echo "  Instance: $INSTANCE_ID"

    ts() { date -u +%H:%M:%SZ; }

    echo "[$(ts)] Waiting for instance running..."
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "[$(ts)] Instance running."

    echo "[$(ts)] Waiting for SSM agent (1–3 min typical)..."
    START_TS=$(date +%s)
    while true; do
      STATUS=$(aws ssm describe-instance-information --region "$REGION" \
        --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo None)
      ELAPSED=$(( $(date +%s) - START_TS ))
      if [ "$STATUS" = "Online" ]; then
        echo "[$(ts)] SSM ready (after ${ELAPSED}s)."
        break
      fi
      printf "[%s] still waiting (%ds elapsed, status=%s)\n" "$(ts)" "$ELAPSED" "$STATUS"
      sleep 15
    done

    cat <<MSG

Instance ${INSTANCE_ID} is up. UserData is installing clickhouse and starting
the conversion in a tmux session ('convert'). Allow ~30–60s for that, then:

  $0 attach        # watch progress, Ctrl-B D to detach, exit when done
  $0 down          # terminate the instance

When the convert finishes, run from your laptop:
  SF=${SF} ./load.sh

(load.sh will skip every already-converted file and just issue TRUNCATE+COPY.)
MSG
    ;;

  attach)
    INSTANCE_ID=$(find_instance_id)
    [ -n "$INSTANCE_ID" ] || { echo "No instance tagged ${INSTANCE_NAME}." >&2; exit 1; }

    if ! command -v session-manager-plugin >/dev/null 2>&1; then
      echo "ERROR: AWS Session Manager plugin not installed." >&2
      echo "Install: brew install --cask session-manager-plugin" >&2
      exit 1
    fi

    aws ssm start-session --region "$REGION" --target "$INSTANCE_ID" \
      --document-name AWS-StartInteractiveCommand \
      --parameters command="sudo tmux attach -t convert"
    ;;

  tail)
    INSTANCE_ID=$(find_instance_id)
    [ -n "$INSTANCE_ID" ] || { echo "No instance tagged ${INSTANCE_NAME}." >&2; exit 1; }

    LINES="${LINES:-50}"
    CMD_ID=$(aws ssm send-command --region "$REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters "commands=[\"tail -${LINES} /tmp/convert.log\"]" \
      --query 'Command.CommandId' --output text)

    # Poll until the command completes; usually <1s.
    while true; do
      STATUS=$(aws ssm get-command-invocation --region "$REGION" \
        --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --query 'Status' --output text 2>/dev/null || echo "Pending")
      case "$STATUS" in
        Success|Failed|Cancelled|TimedOut) break ;;
      esac
      sleep 1
    done

    aws ssm get-command-invocation --region "$REGION" \
      --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
      --query 'StandardOutputContent' --output text
    ;;

  down)
    INSTANCE_ID=$(find_instance_id)
    [ -n "$INSTANCE_ID" ] || { echo "No instance to terminate."; exit 0; }

    echo "Terminating ${INSTANCE_ID}..."
    aws ec2 terminate-instances --region "$REGION" \
      --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
    echo "Done. (IAM role/profile left in place for reuse.)"
    ;;

  *)
    echo "Usage: $0 [up|attach|tail|down]" >&2
    exit 1
    ;;
esac
