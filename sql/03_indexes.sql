-- Purpose: add and verify indexes for user-level and user-product funnel queries.
-- Status as of 2026-08-06:
--   1. idx_events_user_time was created and verified with EXPLAIN.
--   2. idx_events_user_product_time was created and verified with EXPLAIN.
--   3. idx_events_type_time remains an unapproved candidate and has not been created.
-- Do not rerun the executed CREATE INDEX statements on the current database.
-- On a newly reproduced database, run the first two statements separately after
-- sql/02_import_validation.sql passes. Evaluate the third index against the final
-- event-trend query before deciding whether to create it.

USE rees46_funnel_analysis;

CREATE INDEX idx_events_user_time
    ON events (user_id, event_time);

CREATE INDEX idx_events_user_product_time
    ON events (user_id, product_id, event_time);

-- Pending candidate; intentionally not executed:
-- CREATE INDEX idx_events_type_time
--     ON events (event_type, event_time);

SHOW INDEX FROM events;
