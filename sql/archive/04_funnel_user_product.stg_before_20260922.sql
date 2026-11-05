-- Purpose: build the no-window user-product funnel with persistent checkpoint tables.
-- Grain: one row per user_id + product_id that has at least one view event.
-- Funnel: view -> cart -> purchase, with strictly increasing event times.
-- Notes:
--   1. These are regular InnoDB tables, not TEMPORARY tables. They remain available
--      after a Navicat disconnect or a MySQL session change.
--   2. Run one numbered section at a time. If a later section fails, fix it and
--      resume from that section; the earlier checkpoint tables will still exist.
--   3. DROP TABLE makes a rerun reproducible, but it also replaces the previous
--      checkpoint table. Do not rerun a completed section unless rebuilding it is intended.

USE rees46_funnel_analysis;

-- 1. First view for each user-product pair
DROP TABLE IF EXISTS stg_first_view;

CREATE TABLE stg_first_view
ENGINE = InnoDB
AS
SELECT
    user_id,
    product_id,
    MIN(event_time) AS view_time
FROM events
WHERE event_type = 'view'
GROUP BY
    user_id,
    product_id;

SELECT COUNT(*) AS row_first_view
FROM stg_first_view;


-- 2. First cart event strictly after the first view for the same user and product
DROP TABLE IF EXISTS stg_view_cart;

CREATE TABLE stg_view_cart
ENGINE = InnoDB
AS
SELECT
    v.user_id,
    v.product_id,
    v.view_time,
    MIN(e.event_time) AS cart_time
FROM stg_first_view AS v
LEFT JOIN events AS e
    ON v.user_id = e.user_id
   AND v.product_id = e.product_id
   AND e.event_type = 'cart'
   AND v.view_time < e.event_time
GROUP BY
    v.user_id,
    v.product_id,
    v.view_time;

SELECT
    (SELECT COUNT(*) FROM stg_first_view) AS row_view,
    (SELECT COUNT(*) FROM stg_view_cart) AS row_cart;

SELECT
    COUNT(*) AS total_paths,
    SUM(cart_time IS NOT NULL) AS reached_cart_paths,
    SUM(cart_time IS NULL) AS no_cart_paths
FROM stg_view_cart;

SELECT COUNT(*) AS invalid_cart_time_paths
FROM stg_view_cart
WHERE cart_time <= view_time;


-- 3. First purchase strictly after the first view for the same user and product
--    This field also supports the later view -> purchase branch analysis.
DROP TABLE IF EXISTS stg_after_view_purchase;

CREATE TABLE stg_after_view_purchase
ENGINE = InnoDB
AS
SELECT
    vc.user_id,
    vc.product_id,
    vc.view_time,
    vc.cart_time,
    MIN(e.event_time) AS view_purchase_time
FROM stg_view_cart AS vc
LEFT JOIN events AS e
    ON vc.user_id = e.user_id
   AND vc.product_id = e.product_id
   AND e.event_type = 'purchase'
   AND vc.view_time < e.event_time
GROUP BY
    vc.user_id,
    vc.product_id,
    vc.view_time,
    vc.cart_time;


-- 4. First purchase strictly after the qualifying cart for the same user and product
DROP TABLE IF EXISTS stg_after_cart_purchase;

CREATE TABLE stg_after_cart_purchase
ENGINE = InnoDB
AS
SELECT
    vp.user_id,
    vp.product_id,
    vp.view_time,
    vp.cart_time,
    vp.view_purchase_time,
    MIN(e.event_time) AS cart_purchase_time
FROM stg_after_view_purchase AS vp
LEFT JOIN events AS e
    ON vp.user_id = e.user_id
   AND vp.product_id = e.product_id
   AND e.event_type = 'purchase'
   AND vp.cart_time IS NOT NULL
   AND vp.cart_time < e.event_time
GROUP BY
    vp.user_id,
    vp.product_id,
    vp.view_time,
    vp.cart_time,
    vp.view_purchase_time;

SELECT
    (SELECT COUNT(*) FROM stg_view_cart) AS row_cart,
    (SELECT COUNT(*) FROM stg_after_view_purchase) AS row_view_purchase,
    (SELECT COUNT(*) FROM stg_after_cart_purchase) AS row_cart_purchase;

SELECT
    SUM(cart_time IS NOT NULL AND cart_time <= view_time) AS invalid_cart_order,
    SUM(view_purchase_time IS NOT NULL
        AND view_purchase_time <= view_time) AS invalid_view_purchase_order,
    SUM(cart_purchase_time IS NOT NULL
        AND (cart_time IS NULL OR cart_purchase_time <= cart_time))
        AS invalid_cart_purchase_order,
    SUM(cart_purchase_time IS NOT NULL
        AND (view_purchase_time IS NULL
             OR view_purchase_time > cart_purchase_time))
        AS invalid_purchase_relation
FROM stg_after_cart_purchase;


-- 5. Persistent user-product funnel table
DROP TABLE IF EXISTS funnel_user_product;

CREATE TABLE funnel_user_product
ENGINE = InnoDB
AS
SELECT
    user_id,
    product_id,
    view_time,
    cart_time,
    view_purchase_time,
    cart_purchase_time,
    1 AS reached_view,
    (cart_time IS NOT NULL) AS reached_cart,
    (view_purchase_time IS NOT NULL) AS reached_view_purchase,
    (cart_purchase_time IS NOT NULL) AS reached_cart_purchase
FROM stg_after_cart_purchase;


-- 6. Final validation checks
SELECT
    (SELECT COUNT(*) FROM stg_first_view) AS row_first_view,
    (SELECT COUNT(*) FROM stg_view_cart) AS row_view_cart,
    (SELECT COUNT(*) FROM stg_after_view_purchase) AS row_after_view_purchase,
    (SELECT COUNT(*) FROM stg_after_cart_purchase) AS row_after_cart_purchase,
    (SELECT COUNT(*) FROM funnel_user_product) AS row_funnel;

-- Expected result: no rows.
SELECT
    user_id,
    product_id,
    COUNT(*) AS path_count
FROM funnel_user_product
GROUP BY
    user_id,
    product_id
HAVING COUNT(*) > 1;

-- Expected result: 0.
SELECT COUNT(*) AS invalid_strict_purchase_paths
FROM funnel_user_product
WHERE reached_cart = 0
  AND reached_cart_purchase = 1;

-- Expected result: all values are 0.
SELECT
    SUM(reached_view <> 1) AS invalid_view_flag,
    SUM(reached_cart_purchase = 1 AND reached_cart <> 1)
        AS purchase_without_cart_flag,
    SUM(cart_time IS NOT NULL AND cart_time <= view_time)
        AS invalid_cart_time,
    SUM(cart_purchase_time IS NOT NULL
        AND (cart_time IS NULL OR cart_purchase_time <= cart_time))
        AS invalid_purchase_time
FROM funnel_user_product;
