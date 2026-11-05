-- MySQL 8.0.46. Read-only validation for 04/05; no tables are changed here.
-- Supplemental checks for the user's actual tem_* tables and *_cn columns.
-- These supplemental queries have not been executed in MySQL during this archive.
-- All *_pass columns must equal 1, all invalid/duplicate counts must equal 0.
-- Save actual result sets and SELECT UTC_TIMESTAMP(6) with each future MySQL run.
-- Sections 1-8 inspect derived data; section 9 independently queries events
-- and can be expensive on 19.6 million events. Existing core indexes are required.

USE rees46_funnel_analysis;

-- 1. Source path uniqueness and strict order.
SELECT COUNT(*) AS duplicate_user_product_groups
FROM (
    SELECT user_id, product_id FROM tem_after_cart_purchase
    GROUP BY user_id, product_id HAVING COUNT(*) > 1
) AS duplicates;

SELECT
    COUNT(*) AS source_paths,
    COALESCE(SUM(user_id IS NULL OR product_id IS NULL OR view_time IS NULL), 0) AS invalid_keys,
    COALESCE(SUM(cart_time IS NOT NULL AND cart_time <= view_time), 0) AS invalid_cart_order,
    COALESCE(SUM(view_purchase_time IS NOT NULL AND view_purchase_time <= view_time), 0)
        AS invalid_view_purchase_order,
    COALESCE(SUM(cart_purchase_time IS NOT NULL
        AND (cart_time IS NULL OR cart_purchase_time <= cart_time)), 0) AS invalid_strict_order,
    COALESCE(SUM(cart_purchase_time IS NOT NULL
        AND (view_purchase_time IS NULL OR view_purchase_time > cart_purchase_time)), 0)
        AS invalid_purchase_branch_relation
FROM tem_after_cart_purchase;

-- 2. Fixed right-truncation boundary, including real boundary counts.
-- Python full-data reference: total 6899164, eligible 6574154, excluded 325010,
-- exactly at cutoff 1. These are PATH counts, not user counts.
SELECT
    COUNT(*) AS all_first_view_paths,
    COALESCE(SUM(view_time <= '2020-02-22 23:59:59'), 0) AS eligible_7d_paths,
    COALESCE(SUM(view_time > '2020-02-22 23:59:59'), 0) AS excluded_right_truncated_paths,
    COALESCE(SUM(view_time = '2020-02-22 23:59:59'), 0) AS paths_starting_exactly_at_cutoff,
    COUNT(*) = 6899164 AS total_path_count_pass,
    COALESCE(SUM(view_time <= '2020-02-22 23:59:59'), 0) = 6574154 AS eligible_path_count_pass,
    COALESCE(SUM(view_time > '2020-02-22 23:59:59'), 0) = 325010 AS excluded_path_count_pass
FROM tem_after_cart_purchase;

SELECT
    (SELECT COUNT(*) FROM tem_funnel_7d_path)
       = (SELECT COUNT(*) FROM tem_after_cart_purchase
          WHERE view_time >= '2019-10-01 00:00:00'
            AND view_time <= '2020-02-22 23:59:59') AS eligible_row_count_pass,
    COALESCE(SUM(view_time < '2019-10-01 00:00:00'
        OR view_time > '2020-02-22 23:59:59'), 0) AS invalid_start_paths,
    COALESCE(SUM(cart_time = view_time + INTERVAL 7 DAY), 0) AS cart_paths_exactly_at_7d,
    COALESCE(SUM(cart_purchase_time = view_time + INTERVAL 7 DAY), 0)
        AS strict_purchase_paths_exactly_at_7d
FROM tem_funnel_7d_path;

-- 3. One row per path, complete flags and identical source times.
SELECT COUNT(*) AS duplicate_7d_path_groups
FROM (
    SELECT user_id, product_id FROM tem_funnel_7d_path
    GROUP BY user_id, product_id HAVING COUNT(*) > 1
) AS duplicates;

SELECT COUNT(*) AS invalid_path_flags
FROM tem_funnel_7d_path
WHERE NOT (reached_view_7d <=> 1)
   OR NOT (reached_cart_7d <=> CASE WHEN cart_time IS NOT NULL
                 AND cart_time <= view_time + INTERVAL 7 DAY THEN 1 ELSE 0 END)
   OR NOT (reached_view_purchase_7d <=> CASE WHEN view_purchase_time IS NOT NULL
                 AND view_purchase_time <= view_time + INTERVAL 7 DAY THEN 1 ELSE 0 END)
   OR NOT (reached_strict_purchase_7d <=> CASE WHEN cart_purchase_time IS NOT NULL
                 AND cart_purchase_time <= view_time + INTERVAL 7 DAY THEN 1 ELSE 0 END)
   OR (reached_strict_purchase_7d = 1 AND reached_cart_7d <> 1);

SELECT COUNT(*) AS invalid_path_source_links
FROM tem_funnel_7d_path AS p
LEFT JOIN tem_after_cart_purchase AS s
    ON s.user_id = p.user_id AND s.product_id = p.product_id
WHERE s.user_id IS NULL
   OR NOT (p.view_time <=> s.view_time)
   OR NOT (p.cart_time <=> s.cart_time)
   OR NOT (p.view_purchase_time <=> s.view_purchase_time)
   OR NOT (p.cart_purchase_time <=> s.cart_purchase_time);

-- 4. User grain and monotonicity.
SELECT
    COUNT(*) AS row_count,
    COUNT(DISTINCT user_id) AS user_count,
    SUM(reached_view_7d_cn) AS view_users,
    COUNT(*) = COUNT(DISTINCT user_id) AS unique_user_pass,
    COUNT(*) = 1529295 AS expected_user_count_pass,
    SUM(reached_view_7d_cn) >= SUM(reached_cart_7d_cn)
        AND SUM(reached_cart_7d_cn) >= SUM(reached_strict_purchase_7d_cn) AS monotonicity_pass,
    COALESCE(SUM(
        user_id IS NULL
        OR reached_view_7d_cn IS NULL OR reached_view_7d_cn <> 1
        OR reached_cart_7d_cn IS NULL OR reached_cart_7d_cn NOT IN (0,1)
        OR reached_view_purchase_7d_cn IS NULL OR reached_view_purchase_7d_cn NOT IN (0,1)
        OR reached_strict_purchase_7d_cn IS NULL OR reached_strict_purchase_7d_cn NOT IN (0,1)
        OR reached_strict_purchase_7d_cn > reached_cart_7d_cn
        OR reached_strict_purchase_7d_cn > reached_view_purchase_7d_cn
    ), 0) AS invalid_users
FROM tem_funnel_7d_user;

-- Recompute flags from source timestamps (does not reuse the 7d flags).
WITH direct AS (
    SELECT
        COUNT(DISTINCT user_id) AS view_users,
        COUNT(DISTINCT CASE WHEN cart_time <= view_time + INTERVAL 7 DAY
                            THEN user_id END) AS cart_users,
        COUNT(DISTINCT CASE WHEN view_purchase_time <= view_time + INTERVAL 7 DAY
                            THEN user_id END) AS view_purchase_users,
        COUNT(DISTINCT CASE WHEN cart_purchase_time <= view_time + INTERVAL 7 DAY
                            THEN user_id END) AS strict_purchase_users
    FROM tem_after_cart_purchase
    WHERE view_time >= '2019-10-01 00:00:00' AND view_time <= '2020-02-22 23:59:59'
), aggregated AS (
    SELECT SUM(reached_view_7d_cn) AS view_users, SUM(reached_cart_7d_cn) AS cart_users,
           SUM(reached_view_purchase_7d_cn) AS view_purchase_users,
           SUM(reached_strict_purchase_7d_cn) AS strict_purchase_users
    FROM tem_funnel_7d_user
)
SELECT d.*,
       d.view_users = a.view_users AS view_reconciliation_pass,
       d.cart_users = a.cart_users AS cart_reconciliation_pass,
       d.view_purchase_users = a.view_purchase_users AS view_purchase_reconciliation_pass,
       d.strict_purchase_users = a.strict_purchase_users AS strict_purchase_reconciliation_pass
FROM direct AS d CROSS JOIN aggregated AS a;

-- 5. Reported counts; tem_funnel_a is ONE aggregate row, not one row per user.
SELECT
    COUNT(*) = 1 AS aggregate_grain_pass,
    MIN(view_cnt) <=> 1597754 AS view_count_pass,
    MIN(cart_cnt) <=> 280595 AS cart_count_pass,
    MIN(after_view_purchase_cnt) <=> 95198 AS branch_count_pass,
    MIN(after_cart_purchase_cnt) <=> 87330 AS strict_count_pass
FROM tem_funnel_a;

SELECT
    COUNT(*) = 1529295 AS view_count_pass,
    SUM(reached_cart_7d_cn) <=> 268258 AS cart_count_pass,
    SUM(reached_view_purchase_7d_cn) <=> 88980 AS branch_count_pass,
    SUM(reached_strict_purchase_7d_cn) <=> 80366 AS strict_count_pass
FROM tem_funnel_7d_user;

-- Recount the no-window metrics directly from source timestamps.
SELECT
    COUNT(DISTINCT user_id) = 1597754 AS view_pass,
    COUNT(DISTINCT CASE WHEN cart_time IS NOT NULL THEN user_id END) = 280595 AS cart_pass,
    COUNT(DISTINCT CASE WHEN view_purchase_time IS NOT NULL THEN user_id END) = 95198 AS branch_pass,
    COUNT(DISTINCT CASE WHEN cart_purchase_time IS NOT NULL THEN user_id END) = 87330 AS strict_pass
FROM tem_after_cart_purchase;

-- 6. First-completed strict purchase and duration checks.
SELECT COUNT(*) = 87330 AS first_strict_rows_pass,
    COUNT(*) = COUNT(DISTINCT user_id) AS first_strict_unique_user_pass,
    COALESCE(SUM(time_step IS NULL OR time_step <= 0
        OR time_step <> TIMESTAMPDIFF(SECOND, view_time, cart_purchase_time)), 0) AS invalid_duration_rows,
    MIN(time_step) = 25 AS min_duration_pass,
    MAX(time_step) = 12718992 AS max_duration_pass
FROM tem_user_first_strict;

-- Earliest tuple via grouped minima, avoiding repeated unindexed correlated scans.
WITH earliest_purchase AS (
    SELECT user_id, MIN(cart_purchase_time) AS buy_time
    FROM tem_after_cart_purchase
    WHERE cart_time IS NOT NULL AND cart_purchase_time IS NOT NULL
    GROUP BY user_id
), earliest_view AS (
    SELECT p.user_id, e.buy_time, MIN(p.view_time) AS view_time
    FROM tem_after_cart_purchase AS p
    JOIN earliest_purchase AS e ON p.user_id = e.user_id AND p.cart_purchase_time = e.buy_time
    GROUP BY p.user_id, e.buy_time
), earliest_cart AS (
    SELECT p.user_id, e.buy_time, e.view_time, MIN(p.cart_time) AS cart_time
    FROM tem_after_cart_purchase AS p
    JOIN earliest_view AS e ON p.user_id = e.user_id
       AND p.cart_purchase_time = e.buy_time AND p.view_time = e.view_time
    GROUP BY p.user_id, e.buy_time, e.view_time
)
SELECT COUNT(*) AS invalid_first_purchase_tuples
FROM tem_user_first_strict AS f
LEFT JOIN earliest_cart AS e ON e.user_id = f.user_id
WHERE e.user_id IS NULL
   OR NOT (f.cart_purchase_time <=> e.buy_time)
   OR NOT (f.view_time <=> e.view_time)
   OR NOT (f.cart_time <=> e.cart_time);

-- Quantiles independently use nearest rank, rather than the original CUME_DIST.
WITH ordered AS (
    SELECT time_step, ROW_NUMBER() OVER (ORDER BY time_step, user_id) AS rn,
           COUNT(*) OVER () AS n
    FROM tem_user_first_strict
)
SELECT
    MIN(CASE WHEN rn >= CEIL(0.50 * n) THEN time_step END) = 4338 AS p50_pass,
    MIN(CASE WHEN rn >= CEIL(0.75 * n) THEN time_step END) = 162335 AS p75_pass,
    MIN(CASE WHEN rn >= CEIL(0.90 * n) THEN time_step END) = 1123050 AS p90_pass,
    MIN(CASE WHEN rn >= CEIL(0.95 * n) THEN time_step END) = 2354352 AS p95_pass
FROM ordered;

SELECT COUNT(*) = 87330 AS converted_denominator_pass,
    SUM(time_step <= 86400) = 61520 AS coverage_1d_pass,
    SUM(time_step <= 604800) = 74608 AS coverage_7d_pass,
    SUM(time_step <= 1209600) = 79119 AS coverage_14d_pass,
    SUM(time_step <= 2592000) = 83403 AS coverage_30d_pass
FROM tem_user_first_strict;

-- 7. Existing no-window ratios are fractions rounded to FOUR decimal places.
SELECT COUNT(*) = 1 AS no_window_grain_pass,
    MIN(view_cnt) = 1597754 AND MIN(cart_cnt) = 280595
        AND MIN(after_view_purchase_cnt) = 95198
        AND MIN(after_cart_purchase_cnt) = 87330 AS no_window_counts_pass,
    MIN(cart_view) <=> ROUND(280595 / 1597754.0, 4) AS view_cart_rate_pass,
    MIN(any_purchase_view) <=> ROUND(95198 / 1597754.0, 4) AS branch_rate_pass,
    MIN(strict_purchase_cart) <=> ROUND(87330 / 280595.0, 4) AS cart_strict_rate_pass,
    MIN(strict_purchase_view) <=> ROUND(87330 / 1597754.0, 4) AS overall_rate_pass
FROM tem_funnel_no_w;

SELECT
    ROUND(SUM(reached_cart_7d_cn) * 100.0 / NULLIF(COUNT(*), 0), 2) = 17.54 AS view_cart_pct_pass,
    ROUND(SUM(reached_strict_purchase_7d_cn) * 100.0 / NULLIF(SUM(reached_cart_7d_cn), 0), 2)
        = 29.96 AS cart_strict_pct_pass,
    ROUND(SUM(reached_strict_purchase_7d_cn) * 100.0 / NULLIF(COUNT(*), 0), 2) = 5.26 AS overall_pct_pass
FROM tem_funnel_7d_user;

-- 8. Synthetic timestamp controls. Not actual users; expected all *_pass = 1.
SELECT
    CAST('2020-02-29 23:59:59' AS DATETIME)
        <= CAST('2020-02-22 23:59:59' AS DATETIME) + INTERVAL 7 DAY AS exact_7d_included_pass,
    NOT (CAST('2020-01-08 00:00:01' AS DATETIME)
        <= CAST('2020-01-01 00:00:00' AS DATETIME) + INTERVAL 7 DAY) AS after_7d_excluded_pass,
    CAST('2020-02-22 23:59:59' AS DATETIME)
        <= CAST('2020-02-29 23:59:59' AS DATETIME) - INTERVAL 7 DAY AS cutoff_included_pass,
    NOT (CAST('2020-02-23 00:00:00' AS DATETIME)
        <= CAST('2020-02-29 23:59:59' AS DATETIME) - INTERVAL 7 DAY) AS late_start_excluded_pass,
    NOT (CAST('2020-01-01 00:00:00' AS DATETIME)
        > CAST('2020-01-01 00:00:00' AS DATETIME)) AS tied_step_rejected_pass;

-- 9. Optional expensive EVENTS-level independent SQL.
-- Does not read funnel paths or flags: first views + existence of ANY valid
-- same-product cart/purchase chain. Existence is equivalent to the earliest-cart
-- construction, but uses a different query formulation.
-- Only four event columns are used; remove_from_cart does not invalidate a chain.
WITH first_views AS (
    SELECT user_id, product_id, MIN(event_time) AS view_time
    FROM events
    WHERE event_type = 'view'
    GROUP BY user_id, product_id
    HAVING MIN(event_time) >= '2019-10-01 00:00:00'
       AND MIN(event_time) <= '2020-02-22 23:59:59'
), direct_flags AS (
    SELECT v.user_id,
        EXISTS (
            SELECT 1 FROM events AS c
            WHERE c.user_id = v.user_id AND c.product_id = v.product_id AND c.event_type = 'cart'
              AND c.event_time > v.view_time AND c.event_time <= v.view_time + INTERVAL 7 DAY
        ) AS cart_flag,
        EXISTS (
            SELECT 1 FROM events AS p
            WHERE p.user_id = v.user_id AND p.product_id = v.product_id AND p.event_type = 'purchase'
              AND p.event_time > v.view_time AND p.event_time <= v.view_time + INTERVAL 7 DAY
        ) AS view_purchase_flag,
        EXISTS (
            SELECT 1 FROM events AS c
            WHERE c.user_id = v.user_id AND c.product_id = v.product_id AND c.event_type = 'cart'
              AND c.event_time > v.view_time AND c.event_time <= v.view_time + INTERVAL 7 DAY
              AND EXISTS (
                  SELECT 1 FROM events AS p
                  WHERE p.user_id = c.user_id AND p.product_id = c.product_id
                    AND p.event_type = 'purchase' AND p.event_time > c.event_time
                    AND p.event_time <= v.view_time + INTERVAL 7 DAY
              )
        ) AS strict_purchase_flag
    FROM first_views AS v
)
SELECT
    COUNT(DISTINCT user_id) AS view_users,
    COUNT(DISTINCT CASE WHEN cart_flag = 1 THEN user_id END) AS cart_users,
    COUNT(DISTINCT CASE WHEN view_purchase_flag = 1 THEN user_id END) AS view_purchase_users,
    COUNT(DISTINCT CASE WHEN strict_purchase_flag = 1 THEN user_id END) AS strict_purchase_users,
    COUNT(DISTINCT user_id) = 1529295 AS view_pass,
    COUNT(DISTINCT CASE WHEN cart_flag = 1 THEN user_id END) = 268258 AS cart_pass,
    COUNT(DISTINCT CASE WHEN view_purchase_flag = 1 THEN user_id END) = 88980 AS branch_pass,
    COUNT(DISTINCT CASE WHEN strict_purchase_flag = 1 THEN user_id END) = 80366 AS strict_pass
FROM direct_flags;

SELECT UTC_TIMESTAMP(6) AS validation_completed_at_utc;

