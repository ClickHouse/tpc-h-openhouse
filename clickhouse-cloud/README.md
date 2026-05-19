# TPC-H on ClickHouse Cloud

Loads the TPC-H dataset (`sf10` / `sf100` / `sf1000`) from a public S3 bucket into ClickHouse Cloud, plus the standard 22-query benchmark suite under `./queries`.

## Prerequisites

- `clickhouse` client binary on disk. The benchmark harness reads `CLIENT_BIN` (default: `$HOME/work/clickhouse-dist/clickhouse`).
- A populated `clickhouse-client.xml` with `host` / `user` / `password` / `secure=true`. Override the path via `CLIENT_CONFIG`:

```xml
<config>
    <host>your-host.clickhouse-staging.com</host>
    <user>your-user</user>
    <password>your-password</password>
    <secure>true</secure>
</config>
```

- `tmux` (used by `import/run_import.sh` to keep the load running across SSH disconnects).

## Loading the data (one-time)

(You probably don't need to do this — the data is already loaded into the cluster. These are the instructions anyway.)

1. Create databases + tables by running [setup/init.sql](setup/init.sql) once per scale factor:

```bash
for db in sf10 sf100 sf1000; do
  clickhouse-client --config-file=clickhouse-client.xml \
    --query "CREATE DATABASE IF NOT EXISTS ${db}"
  clickhouse-client --config-file=clickhouse-client.xml \
    --database "${db}" --multiquery < setup/init.sql
done
```

2. Kick off the import (tmux session, sequential per scale factor, parallel per table):

```bash
./import/run_import.sh
```

Watch progress with either of:

```bash
tmux attach -t tpch_import
tail -f import/logs/master.log
tail -f import/logs/<db>/<table>.log
cat import/logs/progress.tsv
```

3. Verify row counts vs expected TPC-H cardinalities:

```bash
./import/verify.sh
```

Everything streams from `s3('https://public-pme.s3.amazonaws.com/join_bench/tpc-h/<db>/<file>.parquet', NOSIGN, 'Parquet')` — no AWS credentials needed (public bucket).

### What the loader does

1. For each `(db, table)` pair: `TRUNCATE TABLE <db>.<table>` then `INSERT INTO <db>.<table> SELECT ... FROM s3(...)`. The SELECT wraps every `CHAR(N)`-origin column with `toFixedString(rpad(col, N, ' '), N)` because Parquet only carries variable-length strings and ClickHouse rejects shorter inputs into `FixedString(N)`.
2. Up to 3 attempts per table with 30s backoff on failure.
3. Per-table logs go to `import/logs/<db>/<table>.log`; final row/byte counts and durations are appended to `import/logs/progress.tsv`.

## Running the benchmark

`run_bench.sh` runs each of the 22 queries 3 times, writes the timing JSON to `results/ch_<dataset>_<machine>[_dqp]_<ts>.json`, and prints a per-query best-of-3 summary to stderr.

Required positional args: `<system> <machine_desc> <cluster_size> <base_comment> <dqp_flag>`. Set `DATASET` to pick which database to query (`sf10` / `sf100` / `sf1000`).

Scale factor 10:

```bash
DATASET=sf10 ./run_bench.sh "ClickHouse Cloud (AWS)" "236GiB" 3 "TPC-H" 0 \
  2>&1 | tee logs/bench_$(date -u +%Y%m%dT%H%M%SZ).log
```

Scale factor 100:

```bash
DATASET=sf100 ./run_bench.sh "ClickHouse Cloud (AWS)" "236GiB" 3 "TPC-H" 0 \
  2>&1 | tee logs/bench_$(date -u +%Y%m%dT%H%M%SZ).log
```

Scale factor 1000:

```bash
DATASET=sf1000 ./run_bench.sh "ClickHouse Cloud (AWS)" "236GiB" 3 "TPC-H" 0 \
  2>&1 | tee logs/bench_$(date -u +%Y%m%dT%H%M%SZ).log
```

Last positional arg is the DQP flag. Set it to `1` to enable the distributed query plan settings (see Gotchas below):

```bash
DATASET=sf100 ./run_bench.sh "ClickHouse Cloud (AWS)" "236GiB" 3 "TPC-H" 1 \
  2>&1 | tee logs/bench_$(date -u +%Y%m%dT%H%M%SZ).log
```

The `tee` captures full stdout/stderr to a timestamped log so you can inspect per-run timings and any client errors after the fact.

## Gotchas

- **DQP settings (experimental).** Distributed query plan mode is experimental — when `dqp_flag=1`, the harness prepends a long `SET` block (`make_distributed_plan=1`, `enable_parallel_replicas=0`, `rewrite_in_to_join=1`, etc. — see the top of [run_bench.sh](run_bench.sh)) before every query. With `dqp_flag=0` the queries run with server defaults.
