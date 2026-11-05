-- MySQL 8.0.46. Read-only import reconciliation, restored 2026-09-22.
-- Based on handoff 19.3 and full clean-Parquet verification.
-- Previous index-test text: archive/02_import_validation.index_test_before_20260922.sql.
-- Historical MySQL checks were reported passed; this restored SQL has not been run here.
-- All twelve *_pass fields must equal 1 before continuing on the fixed archive dataset.
USE rees46_funnel_analysis;

WITH actual AS (
    SELECT COUNT(*) AS row_count,
        COALESCE(SUM(event_type = 'view'), 0) AS view_rows,
        COALESCE(SUM(event_type = 'cart'), 0) AS cart_rows,
        COALESCE(SUM(event_type = 'remove_from_cart'), 0) AS remove_from_cart_rows,
        COALESCE(SUM(event_type = 'purchase'), 0) AS purchase_rows,
        COALESCE(SUM(user_session IS NULL), 0) AS null_session_rows,
        COALESCE(SUM(price = 0), 0) AS zero_price_rows,
        COALESCE(SUM(price < 0), 0) AS negative_price_rows,
        MIN(price) AS min_price, MAX(price) AS max_price,
        MIN(event_time) AS min_event_time_utc, MAX(event_time) AS max_event_time_utc
    FROM events
)
SELECT actual.*,
    row_count = 19583742 AS row_count_pass,
    view_rows = 9656790 AS view_rows_pass,
    cart_rows = 5652991 AS cart_rows_pass,
    remove_from_cart_rows = 2987859 AS remove_from_cart_rows_pass,
    purchase_rows = 1286102 AS purchase_rows_pass,
    null_session_rows = 4085 AS null_session_rows_pass,
    zero_price_rows = 86326 AS zero_price_rows_pass,
    negative_price_rows = 124 AS negative_price_rows_pass,
    min_price = -79.37 AS min_price_pass,
    max_price = 327.78 AS max_price_pass,
    min_event_time_utc = '2019-10-01 00:00:00' AS min_event_time_pass,
    max_event_time_utc = '2020-02-29 23:59:59' AS max_event_time_pass
FROM actual;

SELECT UTC_TIMESTAMP(6) AS validation_completed_at_utc;
