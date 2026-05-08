```sql
  bq query --nouse_legacy_sql '
  SELECT "tpch_10"   AS dataset, ROUND(SUM(size_bytes)/POW(1024,3),1) AS size_gb FROM `tpch_10.__TABLES__`
  UNION ALL
  SELECT "tpch_100"  AS dataset, ROUND(SUM(size_bytes)/POW(1024,3),1) AS size_gb FROM `tpch_100.__TABLES__`
  UNION ALL
  SELECT "tpch_1000" AS dataset, ROUND(SUM(size_bytes)/POW(1024,3),1) AS size_gb FROM `tpch_1000.__TABLES__`
  ORDER BY 1'

❯ +-----------+---------+
  |  dataset  | size_gb |
  +-----------+---------+
  | tpch_10   |    13.3 |
  | tpch_100  |   133.1 |
  | tpch_1000 |  1330.9 |
  +-----------+---------+
  ```

  ```sql
    bq query --nouse_legacy_sql '
  SELECT table_schema AS dataset,
         ROUND(SUM(total_physical_bytes)/POW(1024,3),1) AS physical_gb
  FROM `region-us`.INFORMATION_SCHEMA.TABLE_STORAGE
  WHERE table_schema LIKE "tpch_%"
  GROUP BY 1
  ORDER BY 1'
+-----------+-------------+
|  dataset  | physical_gb |
+-----------+-------------+
| tpch_10   |         9.5 |
| tpch_100  |        73.6 |
| tpch_1000 |       505.1 |
+-----------+-------------+
```