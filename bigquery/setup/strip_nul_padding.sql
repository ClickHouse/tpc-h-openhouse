-- Strip trailing NUL-byte padding from CHAR(N) columns that were loaded
-- from parquet via BYTES → STRING cast. After running this once per dataset,
-- TPC-H queries with literal string comparisons (n_name = 'GERMANY' etc.)
-- will match the data again.
--
-- Run with:
--   bq query --use_legacy_sql=false --dataset_id=tpch_10 < strip_nul_padding.sql

CREATE OR REPLACE TABLE nation AS
SELECT n_nationkey,
       REPLACE(n_name, CHR(0), '') AS n_name,
       n_regionkey, n_comment
FROM nation;

CREATE OR REPLACE TABLE region AS
SELECT r_regionkey,
       REPLACE(r_name, CHR(0), '') AS r_name,
       r_comment
FROM region;

CREATE OR REPLACE TABLE part AS
SELECT p_partkey, p_name,
       REPLACE(p_mfgr, CHR(0), '') AS p_mfgr,
       REPLACE(p_brand, CHR(0), '') AS p_brand,
       p_type, p_size,
       REPLACE(p_container, CHR(0), '') AS p_container,
       p_retailprice, p_comment
FROM part;

CREATE OR REPLACE TABLE supplier AS
SELECT s_suppkey,
       REPLACE(s_name, CHR(0), '') AS s_name,
       s_address, s_nationkey,
       REPLACE(s_phone, CHR(0), '') AS s_phone,
       s_acctbal, s_comment
FROM supplier;

CREATE OR REPLACE TABLE customer AS
SELECT c_custkey, c_name, c_address, c_nationkey,
       REPLACE(c_phone, CHR(0), '') AS c_phone,
       c_acctbal,
       REPLACE(c_mktsegment, CHR(0), '') AS c_mktsegment,
       c_comment
FROM customer;

CREATE OR REPLACE TABLE orders AS
SELECT o_orderkey, o_custkey,
       REPLACE(o_orderstatus, CHR(0), '') AS o_orderstatus,
       o_totalprice, o_orderdate,
       REPLACE(o_orderpriority, CHR(0), '') AS o_orderpriority,
       REPLACE(o_clerk, CHR(0), '') AS o_clerk,
       o_shippriority, o_comment
FROM orders;

CREATE OR REPLACE TABLE lineitem AS
SELECT l_orderkey, l_partkey, l_suppkey, l_linenumber,
       l_quantity, l_extendedprice, l_discount, l_tax,
       REPLACE(l_returnflag, CHR(0), '') AS l_returnflag,
       REPLACE(l_linestatus, CHR(0), '') AS l_linestatus,
       l_shipdate, l_commitdate, l_receiptdate,
       REPLACE(l_shipinstruct, CHR(0), '') AS l_shipinstruct,
       REPLACE(l_shipmode, CHR(0), '') AS l_shipmode,
       l_comment
FROM lineitem;
