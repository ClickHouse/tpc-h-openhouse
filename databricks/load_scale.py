#!/usr/bin/env python3
import argparse
import os
import sys
from databricks import sql


TABLE_FILES = {
    "nation": "nation_0.parquet",
    "region": "region_0.parquet",
    "part": "part_0.parquet",
    "supplier": "supplier_0.parquet",
    "partsupp": "partsupp_0.parquet",
    "customer": "customer0.parquet",
    "orders": "orders_0.parquet",
    "lineitem": "lineitem_0.parquet",
}


DDL = {
    "nation": """
CREATE OR REPLACE TABLE nation (
    n_nationkey  BIGINT NOT NULL,
    n_name       STRING,
    n_regionkey  BIGINT,
    n_comment    STRING
) USING DELTA
""",
    "region": """
CREATE OR REPLACE TABLE region (
    r_regionkey  BIGINT NOT NULL,
    r_name       STRING,
    r_comment    STRING
) USING DELTA
""",
    "part": """
CREATE OR REPLACE TABLE part (
    p_partkey     BIGINT NOT NULL,
    p_name        STRING,
    p_mfgr        STRING,
    p_brand       STRING,
    p_type        STRING,
    p_size        BIGINT,
    p_container   STRING,
    p_retailprice DECIMAL(12,2),
    p_comment     STRING
) USING DELTA
""",
    "supplier": """
CREATE OR REPLACE TABLE supplier (
    s_suppkey     BIGINT NOT NULL,
    s_name        STRING,
    s_address     STRING,
    s_nationkey   BIGINT,
    s_phone       STRING,
    s_acctbal     DECIMAL(12,2),
    s_comment     STRING
) USING DELTA
""",
    "partsupp": """
CREATE OR REPLACE TABLE partsupp (
    ps_partkey     BIGINT NOT NULL,
    ps_suppkey     BIGINT NOT NULL,
    ps_availqty    BIGINT,
    ps_supplycost  DECIMAL(12,2),
    ps_comment     STRING
) USING DELTA
""",
    "customer": """
CREATE OR REPLACE TABLE customer (
    c_custkey     BIGINT NOT NULL,
    c_name        STRING,
    c_address     STRING,
    c_nationkey   BIGINT,
    c_phone       STRING,
    c_acctbal     DECIMAL(12,2),
    c_mktsegment  STRING,
    c_comment     STRING
) USING DELTA
""",
    "orders": """
CREATE OR REPLACE TABLE orders (
    o_orderkey       BIGINT NOT NULL,
    o_custkey        BIGINT,
    o_orderstatus    STRING,
    o_totalprice     DECIMAL(12,2),
    o_orderdate      DATE,
    o_orderpriority  STRING,
    o_clerk          STRING,
    o_shippriority   BIGINT,
    o_comment        STRING
) USING DELTA
""",
    "lineitem": """
CREATE OR REPLACE TABLE lineitem (
    l_orderkey       BIGINT NOT NULL,
    l_partkey        BIGINT,
    l_suppkey        BIGINT,
    l_linenumber     BIGINT NOT NULL,
    l_quantity       DECIMAL(12,2),
    l_extendedprice  DECIMAL(12,2),
    l_discount       DECIMAL(12,2),
    l_tax            DECIMAL(12,2),
    l_returnflag     STRING,
    l_linestatus     STRING,
    l_shipdate       DATE,
    l_commitdate     DATE,
    l_receiptdate    DATE,
    l_shipinstruct   STRING,
    l_shipmode       STRING,
    l_comment        STRING
) USING DELTA
""",
}


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
        description="Create and load TPC-H Delta tables in Databricks."
    )
    parser.add_argument("scale", choices=["sf10", "sf100", "sf1000"])
    parser.add_argument(
        "--schema",
        default=None,
        help="Target schema/database. Default: tpch_<scale>, e.g. tpch_sf10",
    )
    parser.add_argument(
        "--s3-base",
        default="s3://public-pme/join_bench/tpc-h",
        help="Base S3 path containing sf10/sf100/sf1000 folders",
    )
    args = parser.parse_args()

    server_hostname = require_env("DATABRICKS_SERVER_HOSTNAME")
    http_path = require_env("DATABRICKS_HTTP_PATH")
    access_token = require_env("DATABRICKS_TOKEN")

    schema = args.schema or f"tpch_{args.scale}"
    s3_prefix = f"{args.s3_base.rstrip('/')}/{args.scale}"

    print(f"→ Schema: {schema}", file=sys.stderr)
    print(f"→ Source: {s3_prefix}/", file=sys.stderr)

    with sql.connect(
        server_hostname=server_hostname,
        http_path=http_path,
        access_token=access_token,
    ) as conn:
        with conn.cursor() as cur:
            run(cur, "SELECT 1", "Checking Databricks connection")

            run(cur, f"CREATE SCHEMA IF NOT EXISTS {schema}", f"Creating schema {schema}")
            run(cur, f"USE {schema}", f"Using schema {schema}")

            for table, filename in TABLE_FILES.items():
                run(cur, DDL[table], f"Creating table {table}")

                file_path = f"{s3_prefix}/{filename}"
                run(
                    cur,
                    f"""
INSERT INTO {table}
SELECT *
FROM parquet.`{file_path}`
""",
                    f"Loading {table} from {file_path}",
                )

            print("→ Row counts", file=sys.stderr)
            cur.execute("""
SELECT 'nation' AS table_name, COUNT(*) AS row_count FROM nation
UNION ALL SELECT 'region', COUNT(*) FROM region
UNION ALL SELECT 'part', COUNT(*) FROM part
UNION ALL SELECT 'supplier', COUNT(*) FROM supplier
UNION ALL SELECT 'partsupp', COUNT(*) FROM partsupp
UNION ALL SELECT 'customer', COUNT(*) FROM customer
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'lineitem', COUNT(*) FROM lineitem
ORDER BY table_name
""")
            for table_name, row_count in cur.fetchall():
                print(f"{table_name:10s} {row_count}", file=sys.stderr)


if __name__ == "__main__":
    main()