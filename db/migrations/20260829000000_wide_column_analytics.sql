-- db/migrations/001_wide_column_analytics.sql
-- Migration: Transform analytics_results from EAV to wide-Column format

-- migrate:up
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_temperature DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS max_temperature DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS min_temperature DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_humidity DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_vibration_rms DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS max_vibration_rms DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS avg_flux_ppm DOUBLE PRECISION;
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS max_flux_ppm DOUBLE PRECISION;

ALTER TABLE analytics_results DROP COLUMN IF EXISTS metric_name;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS metric_value;

-- migrate:down
ALTER TABLE analytics_results DROP COLUMN IF EXISTS avg_temperature;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS max_temperature;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS min_temperature;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS avg_humidity;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS avg_vibration_rms;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS max_vibration_rms;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS avg_flux_ppm;
ALTER TABLE analytics_results DROP COLUMN IF EXISTS max_flux_ppm;

ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS metric_name VARCHAR(64);
ALTER TABLE analytics_results ADD COLUMN IF NOT EXISTS metric_value DOUBLE PRECISION; 




