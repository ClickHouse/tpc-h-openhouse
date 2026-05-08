```sql
dev=#  SELECT schema, "table", size AS size_mb
  FROM SVV_TABLE_INFO
  WHERE schema LIKE 'tpch_%'
  ORDER BY schema, size DESC;
  schema   |  table   | size_mb
-----------+----------+---------
 tpch_10   | orders   |    3328
 tpch_10   | part     |    3072
 tpch_10   | customer |    2816
 tpch_10   | supplier |    2560
 tpch_10   | lineitem |    2544
 tpch_10   | partsupp |    1280
 tpch_10   | nation   |      14
 tpch_10   | region   |      12
 tpch_100  | lineitem |   25542
 tpch_100  | orders   |    8579
 tpch_100  | partsupp |    6145
 tpch_100  | customer |    3712
 tpch_100  | part     |    3584
 tpch_100  | supplier |    2560
 tpch_100  | nation   |      14
 tpch_100  | region   |      12
 tpch_1000 | lineitem |  261734
 tpch_1000 | orders   |   68342
 tpch_1000 | partsupp |   46421
 tpch_1000 | customer |   14592
 tpch_1000 | part     |   11520
 tpch_1000 | supplier |    2944
 tpch_1000 | nation   |      14
 tpch_1000 | region   |      12
(24 rows)
```

```sql
dev=# SELECT schema,
         SUM(size) AS size_mb,
         ROUND(SUM(size) / 1024.0, 1) AS size_gb
  FROM SVV_TABLE_INFO
  WHERE schema LIKE 'tpch_%'
  GROUP BY schema
  ORDER BY schema;
  schema   | size_mb | size_gb
-----------+---------+---------
 tpch_10   |   15626 |    15.3
 tpch_100  |   50148 |    49.0
 tpch_1000 |  405579 |   396.1
```