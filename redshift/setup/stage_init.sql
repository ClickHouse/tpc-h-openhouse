-- Stage tables for the TPC-H parquet load. Mirror the parquet column types
-- exactly: ClickHouse FixedString(N) is FIXED_LEN_BYTE_ARRAY[N] in parquet,
-- which Redshift's COPY reader maps to CHAR(N). transform.sql then casts
-- to VARCHAR and strips the trailing NUL padding.
--
-- Invoke as: psql ... -v schema=tpch_10 -f stage_init.sql

CREATE SCHEMA IF NOT EXISTS :schema;
SET search_path TO :schema;

DROP TABLE IF EXISTS stage_lineitem;
DROP TABLE IF EXISTS stage_orders;
DROP TABLE IF EXISTS stage_customer;
DROP TABLE IF EXISTS stage_partsupp;
DROP TABLE IF EXISTS stage_supplier;
DROP TABLE IF EXISTS stage_part;
DROP TABLE IF EXISTS stage_nation;
DROP TABLE IF EXISTS stage_region;

CREATE TABLE stage_nation (
    n_nationkey  BIGINT,
    n_name       CHAR(25),
    n_regionkey  BIGINT,
    n_comment    VARCHAR(MAX)
);

CREATE TABLE stage_region (
    r_regionkey  BIGINT,
    r_name       CHAR(25),
    r_comment    VARCHAR(MAX)
);

CREATE TABLE stage_part (
    p_partkey     BIGINT,
    p_name        VARCHAR(MAX),
    p_mfgr        CHAR(25),
    p_brand       CHAR(10),
    p_type        VARCHAR(MAX),
    p_size        BIGINT,
    p_container   CHAR(10),
    p_retailprice NUMERIC(12,2),
    p_comment     VARCHAR(MAX)
);

CREATE TABLE stage_supplier (
    s_suppkey     BIGINT,
    s_name        CHAR(25),
    s_address     VARCHAR(MAX),
    s_nationkey   BIGINT,
    s_phone       CHAR(15),
    s_acctbal     NUMERIC(12,2),
    s_comment     VARCHAR(MAX)
);

CREATE TABLE stage_partsupp (
    ps_partkey    BIGINT,
    ps_suppkey    BIGINT,
    ps_availqty   BIGINT,
    ps_supplycost NUMERIC(12,2),
    ps_comment    VARCHAR(MAX)
);

CREATE TABLE stage_customer (
    c_custkey    BIGINT,
    c_name       VARCHAR(MAX),
    c_address    VARCHAR(MAX),
    c_nationkey  BIGINT,
    c_phone      CHAR(15),
    c_acctbal    NUMERIC(12,2),
    c_mktsegment CHAR(10),
    c_comment    VARCHAR(MAX)
);

CREATE TABLE stage_orders (
    o_orderkey      BIGINT,
    o_custkey       BIGINT,
    o_orderstatus   CHAR(1),
    o_totalprice    NUMERIC(12,2),
    o_orderdate     DATE,
    o_orderpriority CHAR(15),
    o_clerk         CHAR(15),
    o_shippriority  BIGINT,
    o_comment       VARCHAR(MAX)
);

CREATE TABLE stage_lineitem (
    l_orderkey      BIGINT,
    l_partkey       BIGINT,
    l_suppkey       BIGINT,
    l_linenumber    BIGINT,
    l_quantity      NUMERIC(12,2),
    l_extendedprice NUMERIC(12,2),
    l_discount      NUMERIC(12,2),
    l_tax           NUMERIC(12,2),
    l_returnflag    CHAR(1),
    l_linestatus    CHAR(1),
    l_shipdate      DATE,
    l_commitdate    DATE,
    l_receiptdate   DATE,
    l_shipinstruct  CHAR(25),
    l_shipmode      CHAR(10),
    l_comment       VARCHAR(MAX)
);
