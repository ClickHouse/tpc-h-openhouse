-- Transform: stage -> final, stripping NUL padding from FixedString columns.
-- Mirrors bigquery/load_from_s3.sh's REPLACE(CHR(0), '') step.
--
-- Invoke as: psql ... -v schema=tpch_10 -f transform.sql

SET search_path TO :schema;

TRUNCATE TABLE region;
INSERT INTO region
SELECT r_regionkey,
       REPLACE(CAST(r_name AS VARCHAR(MAX)), CHR(0), ''),
       r_comment
FROM stage_region;
DROP TABLE stage_region;

TRUNCATE TABLE nation;
INSERT INTO nation
SELECT n_nationkey,
       REPLACE(CAST(n_name AS VARCHAR(MAX)), CHR(0), ''),
       n_regionkey,
       n_comment
FROM stage_nation;
DROP TABLE stage_nation;

TRUNCATE TABLE part;
INSERT INTO part
SELECT p_partkey,
       p_name,
       REPLACE(CAST(p_mfgr      AS VARCHAR(MAX)), CHR(0), ''),
       REPLACE(CAST(p_brand     AS VARCHAR(MAX)), CHR(0), ''),
       p_type,
       p_size,
       REPLACE(CAST(p_container AS VARCHAR(MAX)), CHR(0), ''),
       p_retailprice,
       p_comment
FROM stage_part;
DROP TABLE stage_part;

TRUNCATE TABLE supplier;
INSERT INTO supplier
SELECT s_suppkey,
       REPLACE(CAST(s_name  AS VARCHAR(MAX)), CHR(0), ''),
       s_address,
       s_nationkey,
       REPLACE(CAST(s_phone AS VARCHAR(MAX)), CHR(0), ''),
       s_acctbal,
       s_comment
FROM stage_supplier;
DROP TABLE stage_supplier;

TRUNCATE TABLE partsupp;
INSERT INTO partsupp
SELECT ps_partkey, ps_suppkey, ps_availqty, ps_supplycost, ps_comment
FROM stage_partsupp;
DROP TABLE stage_partsupp;

TRUNCATE TABLE customer;
INSERT INTO customer
SELECT c_custkey,
       c_name,
       c_address,
       c_nationkey,
       REPLACE(CAST(c_phone      AS VARCHAR(MAX)), CHR(0), ''),
       c_acctbal,
       REPLACE(CAST(c_mktsegment AS VARCHAR(MAX)), CHR(0), ''),
       c_comment
FROM stage_customer;
DROP TABLE stage_customer;

TRUNCATE TABLE orders;
INSERT INTO orders
SELECT o_orderkey,
       o_custkey,
       REPLACE(CAST(o_orderstatus   AS VARCHAR(MAX)), CHR(0), ''),
       o_totalprice,
       o_orderdate,
       REPLACE(CAST(o_orderpriority AS VARCHAR(MAX)), CHR(0), ''),
       REPLACE(CAST(o_clerk         AS VARCHAR(MAX)), CHR(0), ''),
       o_shippriority,
       o_comment
FROM stage_orders;
DROP TABLE stage_orders;

TRUNCATE TABLE lineitem;
INSERT INTO lineitem
SELECT l_orderkey,
       l_partkey,
       l_suppkey,
       l_linenumber,
       l_quantity,
       l_extendedprice,
       l_discount,
       l_tax,
       REPLACE(CAST(l_returnflag   AS VARCHAR(MAX)), CHR(0), ''),
       REPLACE(CAST(l_linestatus   AS VARCHAR(MAX)), CHR(0), ''),
       l_shipdate,
       l_commitdate,
       l_receiptdate,
       REPLACE(CAST(l_shipinstruct AS VARCHAR(MAX)), CHR(0), ''),
       REPLACE(CAST(l_shipmode     AS VARCHAR(MAX)), CHR(0), ''),
       l_comment
FROM stage_lineitem;
DROP TABLE stage_lineitem;
