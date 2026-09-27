-- ============================================================
-- init.sql
-- Schema for IoT Soldering Workstation Monitoring
-- PostgreSQL + TimescaleDB
-- ============================================================

-- Enable TimescaleDB extension
CREATE EXTENSION IF NOT EXISTS timescaledb;


-- ============================================================
-- TABLE: devices
-- ============================================================
-- Created first so other tables can reference device_id.
-- No foreign key constraint to sensor_readings to avoid blocking
-- ingestion if a device is not yet pre-registered.

CREATE TABLE IF NOT EXISTS devices (
    device_id           VARCHAR(64)         PRIMARY KEY,
    device_name         VARCHAR(128)        NOT NULL,
    location            VARCHAR(128)        NOT NULL,
    registered_at       TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    active              BOOLEAN             NOT NULL DEFAULT TRUE
);

-- Seed: 3 initial devices for simulation
INSERT INTO devices (device_id, device_name, location) VALUES
    ('device_001', 'Workstation A', 'soldering_area_1'),
    ('device_002', 'Workstation B', 'soldering_area_1'),
    ('device_003', 'Workstation C', 'qc_area')
ON CONFLICT (device_id) DO NOTHING;


-- ============================================================
-- TABLE: sensor_readings
-- ============================================================
-- Main hypertable. TimescaleDB automatically partitions per 1 day interval.
-- Uses explicit DOUBLE PRECISION rather than ambiguous FLOAT.
-- Uses CHECK constraints for physically bounded sensor ranges.
-- location is denormalize deliberately from devices table for these following purpose:
-- 1. Point-in-time snapshot: if device be move to other room, the history of the data remain accurate.
-- 2. Query performance: avoid JOIN on hypertable that has million of rows in Grafana/Spark.
-- 3. Storage overhead will be minimum because the TimescaleDB compression use encodin dictionary.

CREATE TABLE IF NOT EXISTS sensor_readings (

    time                TIMESTAMPTZ         NOT NULL,
    device_id           VARCHAR(64)         NOT NULL,
    location            VARCHAR(128)        NOT NULL,

    -- Temperature and humidity
    temperature         DOUBLE PRECISION    CHECK (temperature BETWEEN -10 AND 100),   -- Celsius
    humidity            DOUBLE PRECISION    CHECK (humidity BETWEEN 0 AND 100),        -- %RH

    -- Accelerometer
    accel_x             DOUBLE PRECISION,   -- m/s²
    accel_y             DOUBLE PRECISION,   -- m/s²
    accel_z             DOUBLE PRECISION,   -- m/s²
    vibration_rms       DOUBLE PRECISION    CHECK (vibration_rms >= 0),               -- m/s²

    -- Solder flux vapor
    flux_ppm            DOUBLE PRECISION    CHECK (flux_ppm >= 0),                    -- ppm
    flux_aqi            INTEGER             CHECK (flux_aqi BETWEEN 0 AND 500),       -- AQI
    voc_level           VARCHAR(16)         CHECK (voc_level IN ('GOOD', 'MODERATE', 'UNHEALTHY', 'HAZARDOUS'))

);

-- Convert to hypertable, partitioned by 1 day interval
SELECT create_hypertable(
    'sensor_readings',
    'time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Index for device-specific time-range queries
CREATE INDEX IF NOT EXISTS idx_sensor_device_time
    ON sensor_readings (device_id, time DESC);

-- Retention policy: drop raw telemetry older than 90 days
-- (Old chunks dropped automatically via TimescaleDB background job)
SELECT add_retention_policy(
    'sensor_readings',
    INTERVAL '90 days',
    if_not_exists => TRUE
);

-- Compression policy: compress chunks older than 7 days
-- Historical chunks are immutable and safely compressed to save disk space
ALTER TABLE sensor_readings SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'time DESC',
    timescaledb.compress_segmentby = 'device_id'
);

SELECT add_compression_policy(
    'sensor_readings',
    INTERVAL '7 days',
    if_not_exists => TRUE
);


-- ============================================================
-- TABLE: analytics_results
-- ============================================================
-- Output from Spark batch jobs.
-- One row = one metric, one device, one time window.

CREATE TABLE IF NOT EXISTS analytics_results (
    id                  SERIAL              PRIMARY KEY,
    computed_at         TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    window_start        TIMESTAMPTZ         NOT NULL,
    window_end          TIMESTAMPTZ         NOT NULL,
    device_id           VARCHAR(64)         NOT NULL,
    location            VARCHAR(128),
    metric_name         VARCHAR(64)         NOT NULL,
    metric_value        DOUBLE PRECISION,

    -- Reference to spark_job_log identifying which batch job produced this record
    -- (join on spark_job_log to obtain worker_count, execution_time_sec, etc.)
    job_id              VARCHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_analytics_device_window
    ON analytics_results (device_id, window_start DESC);

-- Retention: retain analytics results for 1 year
-- (Standard relational table with partial index + manual pruning if needed)


-- ============================================================
-- TABLE: anomaly_events
-- ============================================================

CREATE TABLE IF NOT EXISTS anomaly_events (
    id                  SERIAL              PRIMARY KEY,
    detected_at         TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    event_time          TIMESTAMPTZ         NOT NULL,
    device_id           VARCHAR(64)         NOT NULL,
    location            VARCHAR(128),
    sensor_type         VARCHAR(32)         NOT NULL,
    observed_value      DOUBLE PRECISION,
    threshold_value     DOUBLE PRECISION,
    z_score             DOUBLE PRECISION,
    severity            VARCHAR(16)         CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL'))
);

CREATE INDEX IF NOT EXISTS idx_anomaly_device_time
    ON anomaly_events (device_id, event_time DESC);


-- ============================================================
-- TABLE: spark_job_log
-- ============================================================
-- Tracks each batch job execution.
-- Used for benchmarking experiments: standalone master vs multi-worker cluster.

CREATE TABLE IF NOT EXISTS spark_job_log (
    id                  SERIAL              PRIMARY KEY,
    job_id              VARCHAR(64)         NOT NULL UNIQUE,
    started_at          TIMESTAMPTZ,
    finished_at         TIMESTAMPTZ,
    worker_count        INTEGER             NOT NULL DEFAULT 0,
    records_processed   BIGINT,
    execution_time_sec  DOUBLE PRECISION,
    status              VARCHAR(16)         CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    notes               TEXT
);