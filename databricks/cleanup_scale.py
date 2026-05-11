#!/usr/bin/env python3
import argparse
import os
import sys
from databricks import sql


TABLES = [
    "lineitem",
    "orders",
    "customer",
    "partsupp",
    "supplier",
    "part",
    "nation",
    "region",
]


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        print(f"ERROR: Set {name}", file=sys.stderr)
        sys.exit(1)
    return value


def run(cur, sql_text: str, label: str | None = None):
    if label:
        print(f"→ {label}", file=sys.stderr)
    cur.execute(sql_text)


def main():
    parser = argparse.ArgumentParser(
        description="Drop all TPC-H Delta tables for one Databricks scale schema."
    )
    parser.add_argument("scale", choices=["sf10", "sf100", "sf1000"])
    parser.add_argument(
        "--schema",
        default=None,
        help="Target schema/database. Default: tpch_<scale>, e.g. tpch_sf10",
    )
    parser.add_argument(
        "--drop-schema",
        action="store_true",
        help="Also drop the schema/database after dropping the tables.",
    )
    args = parser.parse_args()

    server_hostname = require_env("DATABRICKS_SERVER_HOSTNAME")
    http_path = require_env("DATABRICKS_HTTP_PATH")
    access_token = require_env("DATABRICKS_TOKEN")

    schema = args.schema or f"tpch_{args.scale}"

    print(f"→ Schema: {schema}", file=sys.stderr)
    print("→ Dropping TPC-H tables", file=sys.stderr)

    with sql.connect(
        server_hostname=server_hostname,
        http_path=http_path,
        access_token=access_token,
    ) as conn:
        with conn.cursor() as cur:
            run(cur, "SELECT 1", "Checking Databricks connection")

            run(cur, f"USE {schema}", f"Using schema {schema}")

            for table in TABLES:
                run(cur, f"DROP TABLE IF EXISTS {table}", f"Dropping table {table}")

            if args.drop_schema:
                run(cur, f"DROP SCHEMA IF EXISTS {schema}", f"Dropping schema {schema}")

    print("→ Done.", file=sys.stderr)


if __name__ == "__main__":
    main()