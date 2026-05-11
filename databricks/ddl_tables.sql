CREATE OR REPLACE TABLE nation (
    n_nationkey  BIGINT NOT NULL,
    n_name       STRING,
    n_regionkey  BIGINT,
    n_comment    STRING
) USING DELTA;

CREATE OR REPLACE TABLE region (
    r_regionkey  BIGINT NOT NULL,
    r_name       STRING,
    r_comment    STRING
) USING DELTA;

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
) USING DELTA;

CREATE OR REPLACE TABLE supplier (
    s_suppkey     BIGINT NOT NULL,
    s_name        STRING,
    s_address     STRING,
    s_nationkey   BIGINT,
    s_phone       STRING,
    s_acctbal     DECIMAL(12,2),
    s_comment     STRING
) USING DELTA;

CREATE OR REPLACE TABLE partsupp (
    ps_partkey     BIGINT NOT NULL,
    ps_suppkey     BIGINT NOT NULL,
    ps_availqty    BIGINT,
    ps_supplycost  DECIMAL(12,2),
    ps_comment     STRING
) USING DELTA;

CREATE OR REPLACE TABLE customer (
    c_custkey     BIGINT NOT NULL,
    c_name        STRING,
    c_address     STRING,
    c_nationkey   BIGINT,
    c_phone       STRING,
    c_acctbal     DECIMAL(12,2),
    c_mktsegment  STRING,
    c_comment     STRING
) USING DELTA;

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
) USING DELTA;

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
) USING DELTA;