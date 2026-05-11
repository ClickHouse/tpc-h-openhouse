#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# summarize_results.py — Stage 3: Build final ClickBench-style result JSON
#
# Produces a minimal ClickBench-compatible result file:
# {
#   "system": "Databricks Serverless SQL warehouse",
#   "date": "YYYY-MM-DD",
#   "machine": "<machine>",
#   "proprietary": "yes",
#   "tuned": "no",
#   "tags": ["Databricks", "Photon", "Serverless"],
#   "load_time": 0,
#   "data_size": 0,
#   "result": [[run1, run2, run3], ...]
# }
# -----------------------------------------------------------------------------


import argparse
import json
from datetime import date


def main():
    parser = argparse.ArgumentParser(
        description="Summarize Databricks TPC-H metrics into benchmark JSON."
    )
    parser.add_argument(
        "--machine",
        required=True,
        help='Machine label, e.g. "4X-Large".',
    )
    parser.add_argument(
        "--cluster-size",
        required=True,
        type=float,
        help="DBU/hour value for the warehouse, emitted as cluster_size.",
    )
    parser.add_argument(
        "--scale",
        required=True,
        choices=["sf10", "sf100", "sf1000"],
        help="TPC-H scale factor.",
    )
    parser.add_argument(
        "--schema",
        default=None,
        help="Schema/database. Default: tpch_<scale>.",
    )
    parser.add_argument(
        "--input",
        required=True,
        help="Metrics JSON from collect_metrics_v2.py.",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Final benchmark JSON output path.",
    )
    args = parser.parse_args()

    schema = args.schema or f"tpch_{args.scale}"

    print(f"Loading metrics from {args.input}")
    print(f"Machine      : {args.machine}")
    print(f"Cluster size : {args.cluster_size}")
    print(f"Scale        : {args.scale}")
    print(f"Schema       : {schema}")
    print(f"Output       : {args.output}")

    with open(args.input, "r", encoding="utf-8") as f:
        runs = json.load(f)

    by_query = {}
    for r in runs:
        q_idx = int(r["query_index"])
        by_query.setdefault(q_idx, []).append(r)

    result = []
    for q_idx in range(1, 23):
        q_runs = sorted(by_query.get(q_idx, []), key=lambda x: int(x["run_index"]))
        run_times = []

        for r in q_runs:
            status = r.get("execution_status")
            total_ms = r.get("total_duration_ms")

            if total_ms is None or status not in ("FINISHED", "SUCCESS", None):
                run_times.append(None)
            else:
                run_times.append(round(total_ms / 1000.0, 3))

        result.append(run_times)

    output = {
        "system": "Databricks Serverless SQL warehouse",
        "date": str(date.today()),
        "machine": args.machine,
        "cluster_size": args.cluster_size,
        "comment": "",
        "proprietary": "yes",
        "tuned": "no",
        "tags": ["Databricks", "Photon", "Serverless", "Delta"],
        "load_time": 0,
        "data_size": 0,
        "scale": args.scale.upper(),
        "schema": schema,
        "result": result,
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)

    print(f"\nWrote result JSON to {args.output}")


if __name__ == "__main__":
    main()

