# tpc-h-openhouse

**An open benchmark of the full TPC-H workload across the major cloud data warehouses — measuring both raw runtime and cost-performance on a join-heavy workload.**

This repository contains the scripts, queries, configurations, and raw results behind the TPC-H benchmark comparing ClickHouse Cloud against Snowflake, Databricks, BigQuery, and Redshift. The benchmark runs the full 22-query TPC-H workload — including the correlated-subquery queries that older ClickHouse releases could not run — and reports both runtime and cost.

📊 **[Read the benchmark write-up →](https://clickhouse.com/blog/tpc-h-clickhouse-cloud-vs-snowflake-databricks-bigquery-redshift)**

---

## Why TPC-H, and why now

TPC-H is the canonical join-heavy analytical benchmark: 22 queries over a normalized schema that exercises hash joins, correlated subqueries, multi-way joins, and join ordering. It is the workload that, for years, was easiest to use to dismiss ClickHouse: "fast, but not for joins."

After two years of focused join engineering — parallel hash join improvements, correlated subquery support, lazy column replication, runtime filters, and statistics-based join reordering — ClickHouse now runs the full TPC-H workload, with default settings, and competes head-to-head with the other major cloud data warehouses.

This repository publishes the benchmark behind that claim so it can be reproduced and inspected.

## What this benchmark measures

For each system, the benchmark records:

- **Raw hot runtime** — best of three runs, result caches disabled, per query and summed across all 22 queries.
- **Compute cost** — runtime translated into dollars using each vendor's public billing model, assuming per-second compute metering, in comparable US East regions.
- **Cost-performance score** — `compute cost × runtime` (smaller is better), collapsing the two dimensions into a single ranking.

The benchmark focuses on **hot runtime**. Cold-start behavior varies widely across cloud warehouses and cannot be standardized fairly across vendors, so cold runs are not part of the headline comparison.

## Systems covered

The same TPC-H workload runs against five cloud data warehouses:

- **ClickHouse Cloud** — one AWS Graviton3 compute node, 59 cores, 236 GiB
- **Snowflake** — Small, Medium, Large, and 4X-Large Gen2 warehouses
- **Databricks (SQL Serverless)** — Small, Medium, Large, and 4X-Large warehouses
- **Google BigQuery** — 2,000 slots (and on-demand pricing for cost comparison)
- **Amazon Redshift Serverless** — 128 RPUs

Each vendor's actual compute billing model is applied to the measured runtimes, so cost numbers reflect what each workload would really be charged at Enterprise-tier pricing.

## Methodology in brief

- **Workload.** Standard TPC-H, all 22 queries, including the correlated-subquery queries (Q2, Q4, Q13, Q17, Q20–Q22) that ClickHouse previously could not run out of the box.
- **Scales.** Main result reported at **SF100** (100 GB, 866M rows). **SF10** (86M rows) is included to show the "TPC-H for less than a cent" result on a single small ClickHouse Cloud node.
- **No tuning.** Default settings on each system. No engine-specific query rewrites, no materialized views, no hand-picked join orders.
- **Hot runtimes, result caches disabled.** Best of three runs; query result caches disabled everywhere they exist, so the benchmark measures real query execution rather than cached-result return.
- **Real billing models.** Each vendor's actual compute pricing is applied per query, normalized to per-second metering for a clean comparison. Pricing assumptions and conversion logic live in the repo.
- **Single cost-performance metric.** `cost-performance score = compute cost × runtime` (smaller is better). The best system is the 1× baseline; everything else is reported as N× worse.

The companion blog posts (linked below) walk through the full methodology, configuration choices, and per-vendor billing logic.

## Headline results

**SF100 (866M rows, 22 join-heavy queries).** With one 59-core compute node, ClickHouse Cloud finishes the workload in 19.8s for $0.063 — **first on cost-performance**. The next-closest configurations (Snowflake Large and Medium) are about 2× worse; the larger Snowflake and Databricks warehouses fall into the 25× – 57× range as cost outpaces speedup.

**SF10 (86M rows).** On the same ClickHouse Cloud configuration, the full 22-query workload runs in **2.9 seconds for $0.009** — TPC-H for less than a cent — and is both the fastest and cheapest tested configuration.

Full per-query runtimes, costs, and ranking details are in the blog post and in the raw result files in this repo.

## Repository layout

```
clickhouse-cloud/   # ClickHouse Cloud scripts, queries, configs, and results
snowflake/          # Snowflake scripts, queries, configs, and results (Small → 4X-Large)
databricks/         # Databricks SQL Serverless setup and results
bigquery/           # BigQuery (2,000 slots) setup and results
redshift/           # Redshift Serverless (128 RPUs) setup and results
_analyze/           # Result aggregation and cost-performance analysis
_viz/               # Chart generation for the blog post
```

Each vendor directory contains the storage/loading scripts, the TPC-H query files as run on that system, the configuration used, and the raw JSON result files with per-query runtimes and costs.

## Open and reproducible

Benchmark claims should be inspectable. This repository publishes:

- the TPC-H query set, per system, exactly as run,
- the storage and loading scripts for each warehouse,
- per-vendor configurations and warehouse sizes,
- pricing models and assumptions used for cost calculation,
- raw result files with per-query runtimes and compute cost,
- the analysis scripts that produce the cost-performance ranking and charts.

If a result looks surprising, the setup that produced it is right there. If a configuration can be improved, issues and pull requests are welcome.

## Read more

- **[TPC-H for less than a cent: ClickHouse Cloud vs. Snowflake, Databricks, BigQuery, and Redshift](https://clickhouse.com/blog/tpc-h-clickhouse-cloud-vs-snowflake-databricks-bigquery-redshift)** — the benchmark results, runtime and cost-performance rankings at SF100 and SF10.
- **[How ClickHouse became fast at joins](https://clickhouse.com/blog/clickhouse-fast-joins)** — the two-year engineering story behind the benchmark: correlated subqueries, lazy column replication, runtime filters, and statistics-based join reordering.
- **[CostBench](https://github.com/ClickHouse/CostBench)** — the related cost-performance benchmark over a ClickBench-style real-time analytical workload, covering the same five cloud data warehouses.

## Roadmap

- **TPC-H SF1000 and beyond.** SF100 fits a single 59-core ClickHouse Cloud node; larger scale factors need join execution to scale across multiple nodes. Multi-stage distributed query execution for large distributed joins is where the engineering team is focusing next.
- **Additional configurations.** More warehouse sizes, tiers, and pricing options as they become relevant.
- **Open table formats.** A separate benchmark comparing engines over Delta Lake, Apache Iceberg, and Apache Hudi.

## Contributing

This repository is open precisely so configurations, queries, and pricing assumptions can be reviewed in the open. If you spot a setup that can be improved, a pricing detail that should be updated, or a vendor configuration worth adding, please open an issue or pull request.

## License

See [LICENSE](LICENSE) in this repository.
