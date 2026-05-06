# TPC-H on BigQuery

Loads the TPC-H dataset (sf10 / sf100 / sf1000) from a public S3 bucket into BigQuery, plus the standard 22-query benchmark suite (fetched from ClickHouse's repo, lightly patched for BigQuery syntax).

The S3 → BigQuery hop runs on a small GCE VM rather than your laptop — the parquet files are large (sf100 lineitem alone is ~23 GB) and a wifi connection is the wrong place for that data to go.

## Files

| File | Purpose |
|---|---|
| `init.sh` | Creates the `tpch_10`, `tpch_100`, `tpch_1000` datasets and runs `init.sql` against each. |
| `init.sql` | Canonical TPC-H schemas (STRING + `PRIMARY KEY ... NOT ENFORCED`). `CREATE OR REPLACE TABLE`, so it's idempotent. |
| `load_from_s3.sh` | Streams parquet from S3 → GCS, two-stage `bq load` with BYTES→STRING casts, populates the schemas. Has `--vm` / `--cleanup` / `--vm-delete` modes (see below). |
| `strip_nul_padding.sql` | Alternative to reloading — strips trailing `\0` from string columns in-place. Run if you loaded before the loader script grew the `REPLACE(..., CHR(0), '')` step. |
| `fetch_tpch_queries.sh` | Downloads the 22 TPC-H query files from `ClickHouse/ClickHouse`, applies BigQuery-syntax patches, writes them to `queries/`. |
| `queries.sql` / `queries/` | The benchmark queries. |

## Prerequisites

- `gcloud` CLI authenticated (`gcloud auth login`) and a default project set.
- `bq` CLI (ships with the Cloud SDK).

## End-to-end load

1. Create datasets + schemas (idempotent)

```bash
./init.sh
```


2. One-time project firewall rule allowing SSH ingress from IAP. The script will detect this and print the command if missing:

```bash
gcloud compute firewall-rules create allow-ssh-iap \
--direction=INGRESS --action=ALLOW --rules=tcp:22 \
--source-ranges=35.235.240.0/20 \
--description="ssh ingress from IAP only"
```

3. Load data (one-shot per scale factor; runs on a GCE VM)

```bash
SF=10  ./load_from_s3.sh --vm
SF=100 ./load_from_s3.sh --vm
```

4. Verify

```bash
unset DATASET
bq query --nouse_legacy_sql --dataset_id=tpch_10  --use_cache=false 'SELECT COUNT(*) FROM lineitem'
bq query --nouse_legacy_sql --dataset_id=tpch_100 --use_cache=false 'SELECT COUNT(*) FROM lineitem'
# expected: 59,986,052  /  600,037,902
```

5. Tear down (when you're done)

```bash
SF=10  ./load_from_s3.sh --cleanup    # delete sf10 GCS staging bucket
SF=100 ./load_from_s3.sh --cleanup    # delete sf100 GCS staging bucket
./load_from_s3.sh --vm-delete         # delete the VM (SF arg ignored)
```

`--vm` is resumable: if the SSH session drops or the VM is killed mid-load, just rerun. The script:
- Reuses the existing VM if it's there.
- Skips uploads where the GCS object size already matches S3.
- Uses a `tmux` session on the VM so SSH disconnects don't kill the load.

To watch a running load without re-attaching: `tmux attach -t tpch` from inside the VM, or `tail -f ~/tpch_${SF}.log`.

## What the loader does

1. Streams each parquet file from `s3://public-pme/join_bench/tpc-h/sf${SF}/` straight to `gs://${PROJECT_ID}-tpch-${SF}-staging/<table>/` — no local disk hop, no AWS credentials needed (public bucket).
2. `bq load --replace` into `stage_<table>` tables (BigQuery infers the schema from parquet — produces a mix of BYTES and STRING columns).
3. `TRUNCATE TABLE <table>; INSERT INTO <table> SELECT [casts] FROM stage_<table>` with explicit `CAST(... AS STRING)` and `REPLACE(..., CHR(0), '')` for the `CHAR(N)`-origin columns. Target tables keep their canonical `init.sql` schema (STRING + PK).
4. `DROP TABLE stage_<table>`.

The staging GCS bucket is *not* deleted automatically — that's `--cleanup`'s job. This is deliberate so you can re-run the cast/transform step without re-streaming from S3.

## Running the benchmark

The benchmark harness lives in [`ClickHouse/Bench2Cost`](https://github.com/ClickHouse/Bench2Cost). Clone it once, then point it at the queries directory in this repo:

```bash
git clone git@github.com:ClickHouse/Bench2Cost.git

DATASET=tpch_100 \
  /path/to/Bench2Cost/bigquery/clickbench/bigquery_extended/run_bq_bench.sh \
  $(pwd)/queries \
  2>&1 | tee bench_$(date -u +%Y%m%dT%H%M%SZ).log
```

`DATASET` selects which BigQuery dataset to query (`tpch_10` / `tpch_100` / `tpch_1000`). The harness runs each of the 22 queries 3 times, captures `runtime_sec` / `billed_slot_sec` / `billed_bytes` per run, and writes a JSON results file to `Bench2Cost/bigquery/clickbench/bigquery_extended/results/`.

The `tee` captures full stdout/stderr to a timestamped log so you can inspect query plans, raw output, and per-run timing after the fact.

## Gotchas

**Trailing null bytes in CHAR(N) columns.** ClickHouse's `FixedString(N)` columns serialize to parquet as `byte_array` without a UTF-8 logical type, so BigQuery imports them as `BYTES`. Casting to `STRING` preserves any zero-byte padding, which silently breaks equality comparisons (`n_name = 'GERMANY'` returns no rows). The transform SQL applies `REPLACE(..., CHR(0), '')` to fix this. If your data was loaded before that step existed, run `strip_nul_padding.sql` against each dataset — cheaper than a full reload.

**Q11's fraction parameter.** The TPC-H spec defines Q11's HAVING threshold as `total * (0.0001 / SF)`. ClickHouse's published query files hardcode `0.0001` (correct only at sf1). At sf100 the threshold ends up 100× too high and Q11 returns zero rows even when the data is correct. Patch the harness to substitute the right fraction per scale factor (`0.00001` at sf10, `0.000001` at sf100, etc.).

**`bq load --replace` clobbers schemas.** Don't run `bq load --replace tpch_10.nation gs://...` directly — it'll re-infer the schema from parquet (BYTES + STRING mix) and drop your `init.sql` types and PK constraints. The two-stage load above exists precisely to avoid this.

**Cloud Shell weekly limit.** The `--remote` mode (using Google Cloud Shell) was the original transport, but Cloud Shell has a per-week cap that's easy to hit. `--vm` is the recommended path now.
