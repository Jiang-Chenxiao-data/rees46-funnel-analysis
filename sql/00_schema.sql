-- Project: E-commerce User Funnel and Retention Analysis
-- MySQL: 8.0.46 Community Server
-- Purpose: create the database and the cleaned event-level table.
-- Grain: one retained user behavior event after exact-row deduplication.
-- Timezone: event_time is stored as UTC, although MySQL DATETIME has no timezone metadata.

CREATE DATABASE IF NOT EXISTS rees46_funnel_analysis
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE rees46_funnel_analysis;

CREATE TABLE IF NOT EXISTS events (
    event_time   DATETIME      NOT NULL COMMENT 'Event timestamp in UTC',
    event_type   VARCHAR(20)   NOT NULL COMMENT 'Raw event type',
    product_id   BIGINT        NOT NULL COMMENT 'Product identifier',
    category_id  BIGINT        NOT NULL COMMENT 'Category identifier; may contain 19 digits',
    price        DECIMAL(12,2) NOT NULL COMMENT 'Recorded event price; zero and negative values retained',
    user_id      BIGINT        NOT NULL COMMENT 'User identifier and primary analysis entity',
    user_session CHAR(36)      NULL     COMMENT 'Original session UUID; missing values retained as NULL'
) ENGINE = InnoDB
  COMMENT = 'Cleaned REES46 user behavior events';

SHOW CREATE TABLE events;
