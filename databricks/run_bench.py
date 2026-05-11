#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# run_bench.py — Stage 1: Execute benchmark queries and collect statement_ids
#
# This script runs each ClickBench query (optionally multiple times) against
# Databricks SQL, records its statement_id, and writes the results to
# runs_<machine>.json.
#
# Why this is a separate stage:
# - system.query.history entries can take 4–10 minutes to appear after a query
#   finishes, depending on Databricks' telemetry refresh cycle.
# - If we immediately tried to fetch metrics after each query, we’d spend most
#   of the time idling on polling and API waits.
# - Instead, we first record all statement_ids as soon as queries complete,
#   then resolve them later in bulk (in collect_metrics.py).
#
# This two-phase approach:
#   ✅ avoids idle time between queries
#   ✅ allows deferred metric collection
#   ✅ makes re-running metric collection possible without re-running queries
#
# Output: runs_<machine>.json — one record per (query_index, run_index)
# -----------------------------------------------------------------------------
import argparse
import json
import os
import sys
from pathlib import Path
from databricks import sql


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        print(f"ERROR: Set {name}", file=sys.stderr)
        sys.exit(1)
    return value


def load_query_files(query_dir: str):
    files = []
    for i in range(1, 23):
        path = Path(query_dir) / f"query_{i:02d}.sql"
        if not path.exists():
            raise FileNotFoundError(f"Missing query file: {path}")
        files.append(path)

    queries = []
    for idx, path in enumerate(files, start=1):
        q = path.read_text(encoding="utf-8").strip()
        if q.endswith(";"):
            q = q[:-1].strip()
        queries.append((idx, str(path), q))

    return queries


def main():
    parser = argparse.ArgumentParser(
        description="Run Databricks TPC-H queries and collect statement_ids."
    )
    parser.add_argument(
        "--scale",
        required=True,
        choices=["sf10", "sf100", "sf1000"],
        help="TPC-H scale factor to run against.",
    )
    parser.add_argument(
        "--machine",
        required=True,
        help='Machine label, e.g. "4X-Large".',
    )
    parser.add_argument(
        "--query-dir",
        default="queries",
        help="Directory containing query_01.sql ... query_22.sql.",
    )
    parser.add_argument(
        "--schema",
        default=None,
        help="Schema/database to USE. Default: tpch_<scale>, e.g. tpch_sf10.",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=3,
        help="Number of runs per query. Default: 3.",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output runs JSON. Default: runs_<scale>_<machine>.json.",
    )
    args = parser.parse_args()

    host = require_env("DATABRICKS_SERVER_HOSTNAME")
    http_path = require_env("DATABRICKS_HTTP_PATH")
    token = require_env("DATABRICKS_TOKEN")

    scale = args.scale
    schema = args.schema or f"tpch_{scale}"
    machine = args.machine
    runs_per_query = args.runs
    output_file = args.output or f"runs_{scale}_{machine}.json"

    queries = load_query_files(args.query_dir)

    print(f"Scale          : {scale}")
    print(f"Schema         : {schema}")
    print(f"Machine        : {machine}")
    print(f"Query dir      : {args.query_dir}")
    print(f"Queries        : {len(queries)}")
    print(f"Runs/query     : {runs_per_query}")
    print(f"Output file    : {output_file}")

    runs = []

    with sql.connect(
        server_hostname=host,
        http_path=http_path,
        access_token=token,
    ) as conn:
        with conn.cursor() as cur:
            print("→ Checking Databricks connection")
            cur.execute("SELECT 1")
            cur.fetchall()

            print("→ Disabling Databricks result cache for this session")
            cur.execute("SET use_cached_result=false")
            try:
                cur.fetchall()
            except Exception:
                pass

            print(f"→ Using schema {schema}")
            cur.execute(f"USE {schema}")
            try:
                cur.fetchall()
            except Exception:
                pass

            for query_index, query_file, query_text in queries:
                for run_index in range(1, runs_per_query + 1):
                    print(f"\n[Q{query_index:02d} run {run_index}/{runs_per_query}] {query_file}")

                    cur.execute(query_text)
                    cur.fetchall()

                    statement_id = cur.query_id
                    print(f"  statement_id: {statement_id}")

                    runs.append(
                        {
                            "query_index": query_index,
                            "run_index": run_index,
                            "query_file": query_file,
                            "original_query": query_text,
                            "rewritten_query": query_text,
                            "statement_id": statement_id,
                            "scale": scale,
                            "schema": schema,
                            "machine": machine,
                        }
                    )

    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(runs, f, indent=2)

    print(
        f"\nSaved {len(runs)} runs to {output_file} "
        f"({len(queries)} queries × {runs_per_query} runs)."
    )


if __name__ == "__main__":
    main()
