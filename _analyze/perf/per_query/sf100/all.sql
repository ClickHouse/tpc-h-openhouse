WITH
sel AS
(


   SELECT '01' AS id, 'ClickHouse 1 x 59 Cores' AS bar_label, 'ClickHouse%' AS system_pat,
           'Enterprise' AS tier, 'default' AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, '236GiB' AS machine, '1' AS cluster_size

    UNION ALL
    SELECT '02' AS id, 'Snowflake Small' AS bar_label, 'Snowflake%' AS system_pat,
           'enterprise' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'Gen2 Small' AS machine, '2.7' AS cluster_size

    UNION ALL
    SELECT '03' AS id, 'Snowflake Medium' AS bar_label, 'Snowflake%' AS system_pat,
           'enterprise' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'Gen2 Medium' AS machine, '5.4' AS cluster_size

    UNION ALL
    SELECT '04' AS id, 'Snowflake Large' AS bar_label, 'Snowflake%' AS system_pat,
           'enterprise' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'Gen2 Large' AS machine, '10.8' AS cluster_size

    UNION ALL
    SELECT '05' AS id, 'Snowflake 4X-L' AS bar_label, 'Snowflake%' AS system_pat,
           'enterprise' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'Gen2 4X-Large' AS machine, '172.8' AS cluster_size



        UNION ALL
    SELECT '06' AS id, 'Databricks Small' AS bar_label, 'Databricks%' AS system_pat,
           'premium' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'serverless' AS machine, 'Small' AS cluster_size


            UNION ALL
    SELECT '07' AS id, 'Databricks Medium' AS bar_label, 'Databricks%' AS system_pat,
           'premium' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'serverless' AS machine, 'Medium' AS cluster_size


    UNION ALL
        SELECT '08' AS id, 'Databricks Large' AS bar_label, 'Databricks%' AS system_pat,
           'premium' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'serverless' AS machine, 'Large' AS cluster_size


--  UNION ALL
--     SELECT '09' AS id, 'Databricks X-Large' AS bar_label, 'Databricks%' AS system_pat,
--         'premium' AS tier, NULL AS compute_model, 'aws' AS provider, 'us-east-1' AS region, 'serverless' AS machine, 'X-Large' AS cluster_size

    UNION ALL
    SELECT '09' AS id, 'Databricks 4X-Large' AS bar_label, 'Databricks%' AS system_pat,
           'premium' AS tier, NULL AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'serverless' AS machine, '4X-Large' AS cluster_size

    UNION ALL
    SELECT '10' AS id, 'BigQuery 2000 slots' AS bar_label, 'Bigquery' AS system_pat,
           'Enterprise' AS tier, 'capacity' AS compute_model,
           'gcp' AS provider, 'us-east-1' AS region, 'serverless' AS machine, 'serverless' AS cluster_size

    UNION ALL
    SELECT '11' AS id, 'Redshift Serverless 128 RPU' AS bar_label, 'Redshift%' AS system_pat,
           'Standard' AS tier, 'capacity' AS compute_model,
           'aws' AS provider, 'us-east-1' AS region, 'serverless' AS machine, 'serverless' AS cluster_size


),

rows AS
(
    SELECT
        s.id,
        s.bar_label,
        replaceRegexpOne(
            replaceRegexpOne(
                replaceRegexpOne(c.system, '^Redshift.*$', 'Redshift'),
                '^ClickHouse.*$', 'ClickHouse'
            ),
            '^Databricks.*$', 'Databricks'
        ) AS system,
        c.tier AS tier,
        c.compute_model AS compute_model,
        c.provider AS provider,
        c.region AS region,
        c.machine AS machine,
        c.cluster_size AS cluster_size,
        c.result AS result
    FROM sel s
    INNER JOIN
    (
        SELECT
            system,
            tier,
            compute_model,
            provider,
            region,
            machine,
            cluster_size,
            result
        FROM bench2cost_tcph_sf100.costs
    ) c
        ON lowerUTF8(c.system) LIKE lowerUTF8(s.system_pat)
       AND ifNull(c.tier, '') = s.tier
       AND ifNull(c.compute_model, 'default') = ifNull(s.compute_model, 'default')
       AND lowerUTF8(ifNull(c.provider, '')) = lowerUTF8(s.provider)
       AND replaceAll(lowerUTF8(ifNull(c.region, '')), '-', '') =
           replaceAll(lowerUTF8(s.region), '-', '')
       AND c.machine LIKE concat('%', s.machine)
       AND ifNull(nullIf(c.cluster_size, 'null'), 'serverless')
           = ifNull(s.cluster_size, 'serverless')
),

per_query AS
(
    SELECT
        id,
        system,
        tier,
        compute_model,
        bar_label,
        idx AS query_id,
        arrayElement(result, idx) AS rt,
        arrayMin(arrayFilter(x -> isNotNull(x), [rt.1, rt.2, rt.3])) AS rt_hot
    FROM rows
    ARRAY JOIN arrayEnumerate(result) AS idx
)

SELECT
    id,
    system,
    tier,
    compute_model,
    bar_label,
    query_id,
    concat('Q', leftPad(toString(query_id), 2, '0')) AS query_label,
    round(rt_hot, 3) AS rt_hot
FROM per_query
WHERE isNotNull(rt_hot)
ORDER BY
    query_id,
    id
FORMAT JSONEachRow