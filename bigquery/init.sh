#!/usr/bin/env bash
set -euo pipefail

export PROJECT_ID=$(gcloud config get-value project)
export USER_EMAIL=$(gcloud config get-value account)


gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="user:$USER_EMAIL" \
    --role="roles/bigquery.user"

bq mk --dataset tpch_10
bq query --use_legacy_sql=false --dataset_id=tpch_10 < init.sql

bq mk --dataset tpch_100
bq query --use_legacy_sql=false --dataset_id=tpch_100 < init.sql

bq mk --dataset tpch_1000
bq query --use_legacy_sql=false --dataset_id=tpch_1000 < init.sql

