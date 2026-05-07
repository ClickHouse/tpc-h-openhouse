-- https://github.com/ClickHouse/ClickHouse/blob/master/tests/benchmarks/tpc-h/init.sql

CREATE OR REPLACE TABLE nation (
    n_nationkey  INT64 NOT NULL,
    n_name       STRING,
    n_regionkey  INT64,
    n_comment    STRING,
    PRIMARY KEY (n_nationkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE region (
    r_regionkey  INT64 NOT NULL,
    r_name       STRING,
    r_comment    STRING,
    PRIMARY KEY (r_regionkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE part (
    p_partkey     INT64 NOT NULL,
    p_name        STRING,
    p_mfgr        STRING,
    p_brand       STRING,
    p_type        STRING,
    p_size        INT64,
    p_container   STRING,
    p_retailprice NUMERIC(12,2),
    p_comment     STRING,
    PRIMARY KEY (p_partkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE supplier (
    s_suppkey     INT64 NOT NULL,
    s_name        STRING,
    s_address     STRING,
    s_nationkey   INT64,
    s_phone       STRING,
    s_acctbal     NUMERIC(12,2),
    s_comment     STRING,
    PRIMARY KEY (s_suppkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE partsupp (
    ps_partkey     INT64 NOT NULL,
    ps_suppkey     INT64 NOT NULL,
    ps_availqty    INT64,
    ps_supplycost  NUMERIC(12,2),
    ps_comment     STRING,
    PRIMARY KEY (ps_partkey, ps_suppkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE customer (
    c_custkey     INT64 NOT NULL,
    c_name        STRING,
    c_address     STRING,
    c_nationkey   INT64,
    c_phone       STRING,
    c_acctbal     NUMERIC(12,2),
    c_mktsegment  STRING,
    c_comment     STRING,
    PRIMARY KEY (c_custkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE orders (
    o_orderkey       INT64 NOT NULL,
    o_custkey        INT64,
    o_orderstatus    STRING,
    o_totalprice     NUMERIC(12,2),
    o_orderdate      DATE,
    o_orderpriority  STRING,
    o_clerk          STRING,
    o_shippriority   INT64,
    o_comment        STRING,
    PRIMARY KEY (o_orderkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE lineitem (
    l_orderkey       INT64 NOT NULL,
    l_partkey        INT64,
    l_suppkey        INT64,
    l_linenumber     INT64 NOT NULL,
    l_quantity       NUMERIC(12,2),
    l_extendedprice  NUMERIC(12,2),
    l_discount       NUMERIC(12,2),
    l_tax            NUMERIC(12,2),
    l_returnflag     STRING,
    l_linestatus     STRING,
    l_shipdate       DATE,
    l_commitdate     DATE,
    l_receiptdate    DATE,
    l_shipinstruct   STRING,
    l_shipmode       STRING,
    l_comment        STRING,
    PRIMARY KEY (l_orderkey, l_linenumber) NOT ENFORCED
);
