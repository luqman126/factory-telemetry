-- ============================================================
-- init.sql
-- Schema untuk IoT Soldering Workstation Monitoring
-- PostgreSQL + TimescaleDB
-- ============================================================

-- Aktifkan extension TimescaleDB
CREATE EXTENSION IF NOT EXISTS timescaledb;


-- ============================================================
-- TABLE: devices
-- ============================================================
-- Dibuat duluan karena tabel lain referensi device_id dari sini.
-- Tidak pakai foreign key constraint ke sensor_readings supaya
-- ingestion tidak terhambat kalau device belum terdaftar.

CREATE TABLE IF NOT EXISTS devices (
    device_id           VARCHAR(64)         PRIMARY KEY,
    device_name         VARCHAR(128)        NOT NULL,
    location            VARCHAR(128)        NOT NULL,
    registered_at       TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    active              BOOLEAN             NOT NULL DEFAULT TRUE
);

-- Seed: 3 device awal untuk simulasi
INSERT INTO devices (device_id, device_name, location) VALUES
    ('device_001', 'Workstation A', 'soldering_area_1'),
    ('device_002', 'Workstation B', 'soldering_area_1'),
    ('device_003', 'Workstation C', 'qc_area')
ON CONFLICT (device_id) DO NOTHING;


-- ============================================================
-- TABLE: sensor_readings
-- ============================================================
-- Hypertable utama. TimescaleDB akan partisi otomatis per 1 hari.
-- Pakai DOUBLE PRECISION (eksplisit) bukan FLOAT (ambigu).
-- Pakai CHECK constraint untuk nilai yang punya range logis.

CREATE TABLE IF NOT EXISTS sensor_readings (

    time                TIMESTAMPTZ         NOT NULL,
    device_id           VARCHAR(64)         NOT NULL,
    location            VARCHAR(128)        NOT NULL,

    -- Suhu dan kelembaban
    temperature         DOUBLE PRECISION    CHECK (temperature BETWEEN -10 AND 100),   -- Celsius
    humidity            DOUBLE PRECISION    CHECK (humidity BETWEEN 0 AND 100),        -- %RH

    -- Accelerometer
    accel_x             DOUBLE PRECISION,   -- m/s²
    accel_y             DOUBLE PRECISION,   -- m/s²
    accel_z             DOUBLE PRECISION,   -- m/s²
    vibration_rms       DOUBLE PRECISION    CHECK (vibration_rms >= 0),               -- m/s²

    -- Uap flux solder
    flux_ppm            DOUBLE PRECISION    CHECK (flux_ppm >= 0),                    -- ppm
    flux_aqi            INTEGER             CHECK (flux_aqi BETWEEN 0 AND 500),       -- AQI
    voc_level           VARCHAR(16)         CHECK (voc_level IN ('GOOD', 'MODERATE', 'UNHEALTHY', 'HAZARDOUS'))

);

-- Konversi ke hypertable, partisi per 1 hari
SELECT create_hypertable(
    'sensor_readings',
    'time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Index untuk query per device dalam rentang waktu tertentu
CREATE INDEX IF NOT EXISTS idx_sensor_device_time
    ON sensor_readings (device_id, time DESC);

-- Retention policy: hapus data raw yang lebih dari 90 hari
-- (chunk lama di-drop otomatis oleh background job TimescaleDB)
SELECT add_retention_policy(
    'sensor_readings',
    INTERVAL '90 days',
    if_not_exists => TRUE
);

-- Compression policy: compress chunk yang sudah lebih dari 7 hari
-- Chunk lama jarang ditulis ulang, jadi aman di-compress untuk hemat storage
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
-- Output dari Spark batch job.
-- Satu baris = satu metric, satu device, satu window waktu.

CREATE TABLE IF NOT EXISTS analytics_results (
    id                  SERIAL              PRIMARY KEY,
    computed_at         TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    window_start        TIMESTAMPTZ         NOT NULL,
    window_end          TIMESTAMPTZ         NOT NULL,
    device_id           VARCHAR(64)         NOT NULL,
    location            VARCHAR(128),
    metric_name         VARCHAR(64)         NOT NULL,
    metric_value        DOUBLE PRECISION,

    -- Referensi ke spark_job_log untuk tahu job mana yang menghasilkan baris ini
    -- (join ke spark_job_log untuk dapat worker_count, execution_time_sec, dll)
    job_id              VARCHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_analytics_device_window
    ON analytics_results (device_id, window_start DESC);

-- Retention: simpan hasil analytics 1 tahun
-- (tidak pakai hypertable, cukup partial index + manual cleanup kalau perlu)


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
-- Tracking setiap batch job yang dijalankan.
-- Dipakai untuk eksperimen perbandingan: master only vs multi-worker.

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