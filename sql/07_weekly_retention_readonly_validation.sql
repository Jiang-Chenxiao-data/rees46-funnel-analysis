-- 真实 MySQL 留存核对：只读，不创建、不修改、不删除数据。
-- 在 Navicat 中完整执行本文件，导出最后这个结果集为 CSV。
-- 建议保存到：
-- E:/GitHub Projects/rees46-funnel-analysis/sql/周留存核对结果.csv
USE rees46_funnel_analysis;

WITH
user_week_duplicates AS (
    SELECT user_id, active_week, COUNT(*) AS rows_per_key
    FROM tem_user_week_cohort_distinct
    GROUP BY user_id, active_week
    HAVING COUNT(*) > 1
),
diff_duplicates AS (
    SELECT user_id, active_week, COUNT(*) AS rows_per_key
    FROM tem_user_week_cohort_diff
    GROUP BY user_id, active_week
    HAVING COUNT(*) > 1
),
detail_duplicates AS (
    SELECT first_week, retention_week, COUNT(*) AS rows_per_key
    FROM tem_cohort_retention_rate
    GROUP BY first_week, retention_week
    HAVING COUNT(*) > 1
),
checks AS (
    SELECT 'user_week_duplicate_groups' AS check_name,
           COUNT(*) AS check_value
    FROM user_week_duplicates
    UNION ALL
    SELECT 'user_week_duplicate_extra_rows',
           COALESCE(SUM(rows_per_key - 1), 0)
    FROM user_week_duplicates
    UNION ALL
    SELECT 'diff_duplicate_groups', COUNT(*)
    FROM diff_duplicates
    UNION ALL
    SELECT 'detail_duplicate_groups', COUNT(*)
    FROM detail_duplicates
    UNION ALL
    SELECT 'user_week_rows', COUNT(*)
    FROM tem_user_week_cohort_distinct
    UNION ALL
    SELECT 'diff_rows', COUNT(*)
    FROM tem_user_week_cohort_diff
    UNION ALL
    SELECT 'first_seen_user_rows', COUNT(*)
    FROM tem_user_week_cohort_first
    UNION ALL
    SELECT 'retention_detail_rows', COUNT(*)
    FROM tem_cohort_retention_rate
),
overall AS (
    SELECT
        retention_week,
        SUM(count_first) AS cohort_users,
        SUM(retained_users) AS retained_users,
        ROUND(
            SUM(retained_users) * 100.0
            / NULLIF(SUM(count_first), 0), 2
        ) AS retention_rate
    FROM tem_cohort_retention_rate
    GROUP BY retention_week
)
SELECT
    'check' AS record_type,
    c.check_name,
    CAST(NULL AS DATE) AS first_week,
    CAST(NULL AS SIGNED) AS retention_week,
    CAST(NULL AS SIGNED) AS cohort_users,
    CAST(NULL AS SIGNED) AS retained_users,
    CAST(NULL AS DECIMAL(12, 2)) AS retention_rate,
    c.check_value
FROM checks AS c

UNION ALL

SELECT
    'detail', NULL, first_week, retention_week,
    count_first, retained_users, retention_rate, NULL
FROM tem_cohort_retention_rate

UNION ALL

SELECT
    'overall', NULL, NULL, retention_week,
    cohort_users, retained_users, retention_rate, NULL
FROM overall
ORDER BY record_type, first_week, retention_week, check_name;

