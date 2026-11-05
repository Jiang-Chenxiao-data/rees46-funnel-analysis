USE rees46_funnel_analysis;

EXPLAIN
SELECT
    user_id,
    product_id,
    event_time,
    event_type
FROM events
ORDER BY
    user_id,
    product_id,
    event_time
LIMIT 1000;

CREATE INDEX idx_events_user_product_time
ON events (user_id, product_id, event_time);

SHOW INDEX FROM events;

EXPLAIN
SELECT
    user_id,
    product_id,
    event_time,
    event_type
FROM events
ORDER BY
    user_id,
    product_id,
    event_time
LIMIT 1000;