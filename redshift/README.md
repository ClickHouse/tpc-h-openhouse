# TPC-H on Redshift

Runs the TPC-H benchmark on Redshift Serverless.

## Prerequisites

- `aws` CLI authenticated (`aws configure` or `aws sso login`).
- `psql` client.
- `clickhouse` (for `clickhouse local`) — `brew install clickhouse`. Used to convert the source parquet (which has `FixedString` columns Redshift can't read) into Redshift-compatible parquet before COPY.
- A region with a default VPC (the workgroup needs ≥3 subnets across AZs).

## Run the benchmark

The 22 TPC-H queries live in `queries/query_01.sql` … `queries/query_22.sql` (Redshift port of the BigQuery versions — `INTERVAL N UNIT` rewritten as `INTERVAL 'N unit'`). `run.sh` reads a flat `queries.sql` (one query per line); regenerate it whenever you edit a query file:

```bash
./setup/gen_queries.sh
```

Run a benchmark, picking the schema by setting `search_path` via `PGOPTIONS` (no `run.sh` change needed — psql honours it on every connection):

```bash
export FQDN=tpch-wg.244449518788.eu-west-3.redshift-serverless.amazonaws.com
export PGOPTIONS="-c search_path=tpch_10"
./run.sh 2>&1 | tee logs/sf10.log
```

Switch SF by changing the `PGOPTIONS` value (`tpch_100`, `tpch_1000`) and the log filename.

## Enrich with pricing

Multiply `billed_times` by the RPU rate (and add monthly storage cost) to produce per-query dollar figures:

```bash
./enrich.sh results/serverless_100b.json pricings/serverless.json us-east1 > results_enriched_sf10/results_enriched.json
```

The output is the input JSON plus a `costs[]` array — one entry per pricing tier — where `compute_costs` mirrors `billed_times` shape but in USD, and `storage_costs` is a one-shot monthly figure for `data_size`.


## Provision the infra

Set the admin password (and any other overrides) in `.env` or as env vars:

```bash
cat > redshift/.env <<EOF
ADMIN_PASSWORD=<choose-something-strong>
REGION=eu-west-3
BASE_CAPACITY=128
EOF
```

Then:

```bash
cd redshift
./setup/provision.sh
```

This creates:

- IAM role `RedshiftTpchS3` (trust for `redshift-serverless`, attached `AmazonS3ReadOnlyAccess`) — required by `COPY` even though the source bucket is public.
- Security group `redshift-tpch-sg` in the default VPC, with port 5439 open to your current public IP only.
- Namespace `tpch` (DB `dev`, admin `dev`).
- Workgroup `tpch-wg` at 128 RPU base capacity, publicly accessible.
- An entry in `~/.pgpass` so `psql` can connect without prompts.

It prints the workgroup endpoint when done. Connect with:

```bash
psql -h <endpoint> -U dev -d dev -p 5439
```

## Initialize schemas and tables

```bash
ENDPOINT=tpch-wg.244449518788.eu-west-3.redshift-serverless.amazonaws.com
  for sf in 10 100 1000; do
    psql -h $ENDPOINT -U dev -d dev -p 5439 \
         -v ON_ERROR_STOP=1 -v schema=tpch_$sf \
         -f redshift/setup/init.sql
  done
```

## Load data

Loads parquet from `s3://public-pme/join_bench/tpc-h/sf${SF}/` into the matching `tpch_${SF}` schema. Run per scale factor:

```bash
SF=10   ./setup/load.sh
SF=100  ./setup/load.sh
SF=1000 ./setup/load.sh
```

For sf1000 the laptop conversion is slow — re-encode on a same-region EC2 instead, then run `load.sh` from your laptop (the convert step skips files already in the staging bucket and only issues TRUNCATE+COPY):

```bash
SF=1000 ./setup/ec2-convert.sh up      # provision + start tmux conversion
        ./setup/ec2-convert.sh attach  # watch progress; Ctrl-B D to detach
        ./setup/ec2-convert.sh down    # terminate
SF=1000 ./setup/load.sh                # back on laptop: TRUNCATE+COPY only
```

Defaults to `c7i.4xlarge` in `eu-west-3` (~$0.81/hr). Access is via AWS SSM (no SSH key, no inbound port). Install the SSM plugin if you don't have it: `brew install --cask session-manager-plugin`.

For each file: `clickhouse local` reads the public-pme parquet, casts `FixedString → String` and widens integers to `Int64`, writes snappy-compressed parquet to stdout, and pipes to `aws s3 cp -` into a staging bucket (`tpch-redshift-<account>-<region>`) under per-table prefixes like `data/sf10/nation/`. Then Redshift `COPY` reads the converted prefix straight into the final table — no manifests, no stage tables.

If a `COPY` fails:

```sql
SELECT * FROM SYS_LOAD_ERROR_DETAIL ORDER BY start_time DESC LIMIT 5;
```

## Tear down

```bash
./setup/teardown.sh
```

Deletes the workgroup → namespace → IAM role → staging bucket → security group, in that order. Idempotent.

## Cost notes

- Compute is only billed while queries run; idle workgroup ≈ $0.
- At 128 RPU, ~$0.36/RPU-hr ≈ $46/hr while actively benchmarking.
- Storage is billed regardless but is pennies/month for TPC-H sf10/100.
- `teardown.sh` removes everything; nothing keeps billing after that.
