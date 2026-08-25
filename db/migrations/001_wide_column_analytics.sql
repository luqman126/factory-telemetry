-- db/migrations/001_wide_column_analytics.sql
-- Migration: Transform analytics_results from EAV to wide-Column format

BEGIN;

-- 1. Add new wide columns
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_temperature DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS max_temperature DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS min_temperature DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_humidity DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_vibration_rms DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS max_vibration_rms DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_flux_ppm DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS max_flux_ppm DOUBLE PRECISION;

-- 2. Drop legacy EAV columns if they exist
ALTER TABLE analytics_results DROP COLUMN IF EXISTS metric_name;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS metric_value;

-- 3. Ensure query index exists
CREATE INDEX IF NOT EXISTS idx_analytics_device_window
    ON analytics_results (device_id, window_start DESC);

COMMIT;

