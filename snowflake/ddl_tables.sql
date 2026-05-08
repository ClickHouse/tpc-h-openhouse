CREATE OR REPLACE TABLE nation (
    n_nationkey  NUMBER(38,0) NOT NULL,
    n_name       VARCHAR,
    n_regionkey  NUMBER(38,0),
    n_comment    VARCHAR,
    PRIMARY KEY (n_nationkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE region (
    r_regionkey  NUMBER(38,0) NOT NULL,
    r_name       VARCHAR,
    r_comment    VARCHAR,
    PRIMARY KEY (r_regionkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE part (
    p_partkey     NUMBER(38,0) NOT NULL,
    p_name        VARCHAR,
    p_mfgr        VARCHAR,
    p_brand       VARCHAR,
    p_type        VARCHAR,
    p_size        NUMBER(38,0),
    p_container   VARCHAR,
    p_retailprice NUMBER(12,2),
    p_comment     VARCHAR,
    PRIMARY KEY (p_partkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE supplier (
    s_suppkey     NUMBER(38,0) NOT NULL,
    s_name        VARCHAR,
    s_address     VARCHAR,
    s_nationkey   NUMBER(38,0),
    s_phone       VARCHAR,
    s_acctbal     NUMBER(12,2),
    s_comment     VARCHAR,
    PRIMARY KEY (s_suppkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE partsupp (
    ps_partkey     NUMBER(38,0) NOT NULL,
    ps_suppkey     NUMBER(38,0) NOT NULL,
    ps_availqty    NUMBER(38,0),
    ps_supplycost  NUMBER(12,2),
    ps_comment     VARCHAR,
    PRIMARY KEY (ps_partkey, ps_suppkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE customer (
    c_custkey     NUMBER(38,0) NOT NULL,
    c_name        VARCHAR,
    c_address     VARCHAR,
    c_nationkey   NUMBER(38,0),
    c_phone       VARCHAR,
    c_acctbal     NUMBER(12,2),
    c_mktsegment  VARCHAR,
    c_comment     VARCHAR,
    PRIMARY KEY (c_custkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE orders (
    o_orderkey       NUMBER(38,0) NOT NULL,
    o_custkey        NUMBER(38,0),
    o_orderstatus    VARCHAR,
    o_totalprice     NUMBER(12,2),
    o_orderdate      DATE,
    o_orderpriority  VARCHAR,
    o_clerk          VARCHAR,
    o_shippriority   NUMBER(38,0),
    o_comment        VARCHAR,
    PRIMARY KEY (o_orderkey) NOT ENFORCED
);

CREATE OR REPLACE TABLE lineitem (
    l_orderkey       NUMBER(38,0) NOT NULL,
    l_partkey        NUMBER(38,0),
    l_suppkey        NUMBER(38,0),
    l_linenumber     NUMBER(38,0) NOT NULL,
    l_quantity       NUMBER(12,2),
    l_extendedprice  NUMBER(12,2),
    l_discount       NUMBER(12,2),
    l_tax            NUMBER(12,2),
    l_returnflag     VARCHAR,
    l_linestatus     VARCHAR,
    l_shipdate       DATE,
    l_commitdate     DATE,
    l_receiptdate    DATE,
    l_shipinstruct   VARCHAR,
    l_shipmode       VARCHAR,
    l_comment        VARCHAR,
    PRIMARY KEY (l_orderkey, l_linenumber) NOT ENFORCED
);