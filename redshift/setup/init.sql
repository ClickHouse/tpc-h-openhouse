-- https://github.com/ClickHouse/ClickHouse/blob/master/tests/benchmarks/tpc-h/init.sql
-- Redshift port of the BigQuery DDL. INT64 -> BIGINT, STRING -> VARCHAR(MAX),
-- NUMERIC(12,2) kept (Redshift accepts NUMERIC as DECIMAL), and the
-- "NOT ENFORCED" qualifier dropped (Redshift PKs are never enforced).
--
-- Invoke per scale factor:
--   psql ... -v schema=tpch_10   -f init.sql
--   psql ... -v schema=tpch_100  -f init.sql
--   psql ... -v schema=tpch_1000 -f init.sql

CREATE SCHEMA IF NOT EXISTS :schema;
SET search_path TO :schema;

DROP TABLE IF EXISTS lineitem;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS partsupp;
DROP TABLE IF EXISTS supplier;
DROP TABLE IF EXISTS part;
DROP TABLE IF EXISTS nation;
DROP TABLE IF EXISTS region;

CREATE TABLE nation (
    n_nationkey  BIGINT NOT NULL,
    n_name       VARCHAR(MAX),
    n_regionkey  BIGINT,
    n_comment    VARCHAR(MAX),
    PRIMARY KEY (n_nationkey)
);

CREATE TABLE region (
    r_regionkey  BIGINT NOT NULL,
    r_name       VARCHAR(MAX),
    r_comment    VARCHAR(MAX),
    PRIMARY KEY (r_regionkey)
);

CREATE TABLE part (
    p_partkey     BIGINT NOT NULL,
    p_name        VARCHAR(MAX),
    p_mfgr        VARCHAR(MAX),
    p_brand       VARCHAR(MAX),
    p_type        VARCHAR(MAX),
    p_size        BIGINT,
    p_container   VARCHAR(MAX),
    p_retailprice NUMERIC(12,2),
    p_comment     VARCHAR(MAX),
    PRIMARY KEY (p_partkey)
);

CREATE TABLE supplier (
    s_suppkey     BIGINT NOT NULL,
    s_name        VARCHAR(MAX),
    s_address     VARCHAR(MAX),
    s_nationkey   BIGINT,
    s_phone       VARCHAR(MAX),
    s_acctbal     NUMERIC(12,2),
    s_comment     VARCHAR(MAX),
    PRIMARY KEY (s_suppkey)
);

CREATE TABLE partsupp (
    ps_partkey     BIGINT NOT NULL,
    ps_suppkey     BIGINT NOT NULL,
    ps_availqty    BIGINT,
    ps_supplycost  NUMERIC(12,2),
    ps_comment     VARCHAR(MAX),
    PRIMARY KEY (ps_partkey, ps_suppkey)
);

CREATE TABLE customer (
    c_custkey     BIGINT NOT NULL,
    c_name        VARCHAR(MAX),
    c_address     VARCHAR(MAX),
    c_nationkey   BIGINT,
    c_phone       VARCHAR(MAX),
    c_acctbal     NUMERIC(12,2),
    c_mktsegment  VARCHAR(MAX),
    c_comment     VARCHAR(MAX),
    PRIMARY KEY (c_custkey)
);

CREATE TABLE orders (
    o_orderkey       BIGINT NOT NULL,
    o_custkey        BIGINT,
    o_orderstatus    VARCHAR(MAX),
    o_totalprice     NUMERIC(12,2),
    o_orderdate      DATE,
    o_orderpriority  VARCHAR(MAX),
    o_clerk          VARCHAR(MAX),
    o_shippriority   BIGINT,
    o_comment        VARCHAR(MAX),
    PRIMARY KEY (o_orderkey)
);

CREATE TABLE lineitem (
    l_orderkey       BIGINT NOT NULL,
    l_partkey        BIGINT,
    l_suppkey        BIGINT,
    l_linenumber     BIGINT NOT NULL,
    l_quantity       NUMERIC(12,2),
    l_extendedprice  NUMERIC(12,2),
    l_discount       NUMERIC(12,2),
    l_tax            NUMERIC(12,2),
    l_returnflag     VARCHAR(MAX),
    l_linestatus     VARCHAR(MAX),
    l_shipdate       DATE,
    l_commitdate     DATE,
    l_receiptdate    DATE,
    l_shipinstruct   VARCHAR(MAX),
    l_shipmode       VARCHAR(MAX),
    l_comment        VARCHAR(MAX),
    PRIMARY KEY (l_orderkey, l_linenumber)
);
