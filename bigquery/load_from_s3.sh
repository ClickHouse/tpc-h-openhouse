#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

# Load .env locally (skip if PROJECT_ID already provided, e.g. when running remotely)
if [ -z "${PROJECT_ID:-}" ] && [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${PROJECT_ID:?set PROJECT_ID to your GCP project (.env or env var)}"
SF="${SF:-10}"
MODE="${1:-}"

DATASET="tpch_${SF}"
BUCKET="gs://${PROJECT_ID}-tpch-${SF}-staging"
VM_NAME="tpch-loader"
VM_ZONE="${VM_ZONE:-us-central1-a}"

# --cleanup: remove staging bucket and any leftover stage_ tables.
# Run after verifying the loaded data looks right.
if [ "${MODE}" = "--cleanup" ]; then
  export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
  echo "Deleting staging bucket ${BUCKET}..."
  gcloud storage rm --recursive "${BUCKET}" --quiet || true
  echo "Dropping any leftover stage_ tables in ${DATASET}..."
  for t in nation region part supplier partsupp customer orders lineitem; do
    bq rm -f -t "${DATASET}.stage_${t}" 2>/dev/null || true
  done
  echo "--- cleanup done ---"
  exit 0
fi

# --vm-delete: tear down the loader VM after you're done.
if [ "${MODE}" = "--vm-delete" ]; then
  export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"
  echo "Deleting VM ${VM_NAME} in ${VM_ZONE}..."
  gcloud compute instances delete "${VM_NAME}" --zone="${VM_ZONE}" --quiet
  exit 0
fi

# --vm: create a small GCE VM (or reuse existing), copy the script,
# run it in tmux. SSH disconnect doesn't kill the load.
if [ "${MODE}" = "--vm" ]; then
  export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"

  # Project must allow SSH ingress from IAP range for --tunnel-through-iap.
  # Default networks have 'default-allow-ssh'; custom VPCs often don't.
  # We check for either the rule we'd create or the default network's rule.
  if ! gcloud compute firewall-rules describe allow-ssh-iap >/dev/null 2>&1 \
     && ! gcloud compute firewall-rules describe default-allow-ssh >/dev/null 2>&1; then
    cat <<'FIREWALL_HELP'
ERROR: No firewall rule found that allows SSH ingress from IAP (35.235.240.0/20).
Create one (one-time, project-level), then re-run this script:

  gcloud compute firewall-rules create allow-ssh-iap \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --description="ssh ingress from IAP only"
FIREWALL_HELP
    exit 1
  fi

  if ! gcloud compute instances describe "${VM_NAME}" \
       --zone="${VM_ZONE}" >/dev/null 2>&1; then
    echo "Creating VM ${VM_NAME} in ${VM_ZONE}..."
    gcloud compute instances create "${VM_NAME}" \
      --zone="${VM_ZONE}" \
      --machine-type=e2-medium \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --boot-disk-size=20GB \
      --scopes=cloud-platform
    # Pre-generate the gcloud SSH key non-interactively, otherwise the
    # wait loop below will hang silently on the passphrase prompt.
    if [ ! -f "${HOME}/.ssh/google_compute_engine" ]; then
      echo "Generating SSH key for gcloud (no passphrase)..."
      ssh-keygen -t rsa -b 2048 -N "" \
        -f "${HOME}/.ssh/google_compute_engine" -q
    fi

    echo -n "Waiting for SSH"
    for i in $(seq 1 60); do
      if gcloud compute ssh "${VM_NAME}" --zone="${VM_ZONE}" --tunnel-through-iap \
           --ssh-flag="-oConnectTimeout=5" \
           --command="true" </dev/null >/dev/null 2>&1; then
        echo " ready."
        break
      fi
      printf "."
      sleep 3
    done
  else
    echo "Reusing existing VM ${VM_NAME}."
  fi

  # Don't overwrite the script while bash is mid-execution inside an
  # existing tmux session — that causes phantom line-offset errors.
  TMUX_RUNNING=$(gcloud compute ssh "${VM_NAME}" --zone="${VM_ZONE}" \
    --tunnel-through-iap --ssh-flag="-oConnectTimeout=10" \
    --command "tmux has-session -t tpch 2>/dev/null && echo running || echo none" \
    2>/dev/null | tr -d '[:space:]' || echo "none")

  if [ "${TMUX_RUNNING}" = "running" ]; then
    echo "Existing tmux session 'tpch' is running; skipping script copy."
    echo "(To pick up local edits, exit/kill the tmux session first.)"
  else
    echo "Copying script to VM..."
    gcloud compute scp "$0" "${VM_NAME}:~/tpch_loader.sh" \
      --zone="${VM_ZONE}" --tunnel-through-iap
  fi

  echo "Attaching to load session (tmux)..."
  REMOTE_CMD=$(cat <<EOF
chmod +x ~/tpch_loader.sh
if ! command -v tmux >/dev/null || ! command -v aws >/dev/null; then
  echo "Installing tmux + awscli..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tmux awscli
fi
if ! tmux has-session -t tpch 2>/dev/null; then
  echo "Starting new tmux session 'tpch'..."
  tmux new-session -d -s tpch "PROJECT_ID='${PROJECT_ID}' SF='${SF}' bash ~/tpch_loader.sh 2>&1 | tee ~/tpch_${SF}.log; echo; echo '*** finished. Press Enter to close. ***'; read"
else
  echo "Reattaching to existing tmux session 'tpch'..."
fi
tmux attach -t tpch
EOF
)
  exec gcloud compute ssh "${VM_NAME}" --zone="${VM_ZONE}" --tunnel-through-iap \
    --ssh-flag="-t" \
    --ssh-flag="-oServerAliveInterval=30" \
    --ssh-flag="-oServerAliveCountMax=20" \
    --command "$REMOTE_CMD"
fi

# --remote: copy script to Cloud Shell, run in a tmux session so it
# survives SSH disconnects, and attach to view progress.
if [ "${MODE}" = "--remote" ]; then
  echo "Copying script to Cloud Shell..."
  gcloud cloud-shell ssh --authorize-session --command \
    "cat > ~/tpch_loader.sh && chmod +x ~/tpch_loader.sh" < "$0"

  echo "Attaching to load session (tmux)..."
  REMOTE_CMD=$(cat <<EOF
if ! tmux has-session -t tpch 2>/dev/null; then
  echo "Starting new tmux session 'tpch'..."
  tmux new-session -d -s tpch "PROJECT_ID='${PROJECT_ID}' SF='${SF}' bash ~/tpch_loader.sh 2>&1 | tee ~/tpch_${SF}.log; echo; echo '*** finished. Press Enter to close. ***'; read"
else
  echo "Reattaching to existing tmux session 'tpch'..."
fi
tmux attach -t tpch
EOF
)
  exec gcloud cloud-shell ssh --authorize-session \
    --ssh-flag="-oServerAliveInterval=30" \
    --ssh-flag="-oServerAliveCountMax=20" \
    --command "$REMOTE_CMD"
fi

# Bootstrap awscli in Cloud Shell (not installed by default there)
if ! command -v aws >/dev/null 2>&1; then
  if [ "${CLOUD_SHELL:-}" = "true" ]; then
    echo "Installing awscli in Cloud Shell..."
    pip install --user --quiet awscli
    export PATH="${HOME}/.local/bin:${PATH}"
  else
    echo "ERROR: aws cli not found locally. Install it (pip install --user awscli)"
    echo "or run with --remote to delegate to Cloud Shell."
    exit 1
  fi
fi

export CLOUDSDK_CORE_PROJECT="${PROJECT_ID}"

S3_BASE="s3://public-pme/join_bench/tpc-h/sf${SF}"

TABLES=(nation region part supplier partsupp customer orders lineitem)

if gcloud storage buckets describe "${BUCKET}" >/dev/null 2>&1; then
  echo "--- using existing staging bucket ${BUCKET} ---"
else
  echo "--- creating staging bucket ${BUCKET} ---"
  gcloud storage buckets create "${BUCKET}" \
    --location=us \
    --uniform-bucket-level-access
fi

echo "--- listing parquet files in S3 ---"
ALL_FILES="$(aws s3 ls --no-sign-request "${S3_BASE}/" \
  | awk '{print $4}' | grep '\.parquet$' || true)"

# size_in_s3 <key>
size_in_s3() {
  aws s3api head-object --no-sign-request \
    --bucket public-pme --key "join_bench/tpc-h/sf${SF}/$1" \
    --query 'ContentLength' --output text 2>/dev/null
}

# size_in_gcs <gs://...>
size_in_gcs() {
  gcloud storage objects describe "$1" --format='value(size)' 2>/dev/null
}

echo "--- streaming S3 → GCS ---"
for t in "${TABLES[@]}"; do
  # Match files starting with "<table>" followed by underscore or digit.
  # This naturally separates 'part' (part_*) from 'partsupp' (partsupp_*)
  # and handles sf10's 'customer0.parquet' as well as 'customer_0.parquet'.
  files="$(echo "${ALL_FILES}" | grep -E "^${t}[_0-9]" || true)"
  if [ -z "${files}" ]; then
    echo "  ${t}: no files matched"
    continue
  fi
  echo "  ${t}"
  while IFS= read -r f; do
    dest="${BUCKET}/${t}/${f}"
    expected="$(size_in_s3 "${f}")"
    actual="$(size_in_gcs "${dest}" || true)"
    if [ -n "${actual}" ] && [ "${expected}" = "${actual}" ]; then
      echo "    $f (already uploaded, skipping)"
      continue
    fi
    echo "    $f"
    success=0
    for attempt in 1 2 3 4 5; do
      if aws s3 cp --no-sign-request --only-show-errors "${S3_BASE}/${f}" - \
        | gcloud storage cp - "${dest}" --quiet; then
        success=1; break
      fi
      echo "    attempt ${attempt} failed, retrying in 10s..."
      sleep 10
    done
    if [ "${success}" != "1" ]; then
      echo "    ERROR: failed to upload ${f} after 5 attempts"
      exit 1
    fi
  done <<< "${files}"
done

echo "--- loading parquet to staging tables ---"
for t in "${TABLES[@]}"; do
  echo "  ${DATASET}.stage_${t}"
  bq load --source_format=PARQUET --replace \
    "${DATASET}.stage_${t}" "${BUCKET}/${t}/*.parquet"
done

echo "--- transforming staging → final (BYTES → STRING casts, NULs stripped) ---"
echo "Target tables must already exist (run init.sql first if they don't)."
# CHAR(N) columns arrive as FIXED_LEN_BYTE_ARRAY in the parquet, NUL-padded
# to width N. CAST(BYTES AS STRING) preserves the NULs, so we REPLACE them
# out — otherwise WHERE col = 'literal' never matches.
bq query --use_legacy_sql=false --dataset_id="${DATASET}" --format=none \
  --project_id="${PROJECT_ID}" "$(cat <<'SQL'
TRUNCATE TABLE nation;
INSERT INTO nation
SELECT n_nationkey, REPLACE(CAST(n_name AS STRING), CHR(0), ''), n_regionkey, n_comment
FROM stage_nation;
DROP TABLE stage_nation;

TRUNCATE TABLE region;
INSERT INTO region
SELECT r_regionkey, REPLACE(CAST(r_name AS STRING), CHR(0), ''), r_comment
FROM stage_region;
DROP TABLE stage_region;

TRUNCATE TABLE part;
INSERT INTO part
SELECT
  p_partkey, p_name,
  REPLACE(CAST(p_mfgr AS STRING), CHR(0), ''),
  REPLACE(CAST(p_brand AS STRING), CHR(0), ''),
  p_type, p_size,
  REPLACE(CAST(p_container AS STRING), CHR(0), ''),
  p_retailprice, p_comment
FROM stage_part;
DROP TABLE stage_part;

TRUNCATE TABLE supplier;
INSERT INTO supplier
SELECT
  s_suppkey,
  REPLACE(CAST(s_name AS STRING), CHR(0), ''),
  s_address, s_nationkey,
  REPLACE(CAST(s_phone AS STRING), CHR(0), ''),
  s_acctbal, s_comment
FROM stage_supplier;
DROP TABLE stage_supplier;

TRUNCATE TABLE partsupp;
INSERT INTO partsupp
SELECT ps_partkey, ps_suppkey, ps_availqty, ps_supplycost, ps_comment
FROM stage_partsupp;
DROP TABLE stage_partsupp;

TRUNCATE TABLE customer;
INSERT INTO customer
SELECT
  c_custkey, c_name, c_address, c_nationkey,
  REPLACE(CAST(c_phone AS STRING), CHR(0), ''),
  c_acctbal,
  REPLACE(CAST(c_mktsegment AS STRING), CHR(0), ''),
  c_comment
FROM stage_customer;
DROP TABLE stage_customer;

TRUNCATE TABLE orders;
INSERT INTO orders
SELECT
  o_orderkey, o_custkey,
  REPLACE(CAST(o_orderstatus AS STRING), CHR(0), ''),
  o_totalprice, o_orderdate,
  REPLACE(CAST(o_orderpriority AS STRING), CHR(0), ''),
  REPLACE(CAST(o_clerk AS STRING), CHR(0), ''),
  o_shippriority, o_comment
FROM stage_orders;
DROP TABLE stage_orders;

TRUNCATE TABLE lineitem;
INSERT INTO lineitem
SELECT
  l_orderkey, l_partkey, l_suppkey, l_linenumber,
  l_quantity, l_extendedprice, l_discount, l_tax,
  REPLACE(CAST(l_returnflag AS STRING), CHR(0), ''),
  REPLACE(CAST(l_linestatus AS STRING), CHR(0), ''),
  l_shipdate, l_commitdate, l_receiptdate,
  REPLACE(CAST(l_shipinstruct AS STRING), CHR(0), ''),
  REPLACE(CAST(l_shipmode AS STRING), CHR(0), ''),
  l_comment
FROM stage_lineitem;
DROP TABLE stage_lineitem;
SQL
)"

echo "--- done ---"
echo
echo "Verify the loaded data, then run:"
echo "  SF=${SF} ${0##*/} --cleanup"
echo "to delete the staging bucket and any leftover stage_ tables."
