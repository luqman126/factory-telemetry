# ============================================================
# spark-jobs/batch_analytics.py
# Spark batch job: baca Parquet, hitung analytics, simpan ke DB
# Jalankan: spark-submit batch_analytics.py <path_parquet> <worker_count>
# Contoh:   spark-submit batch_analytics.py data/parquet/sensor_xxx.parquet 0
# ============================================================

import os
import sys
import uuid
import logging
from pathlib import Path
from datetime import datetime, timezone

from pyspark.sql import SparkSession
from pyspark.sql import functions as F
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

_ENV_PATH = Path(__file__).parents[1] / "infra" / ".env"
load_dotenv(dotenv_path=_ENV_PATH)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger(__name__)

# ============================================================
# Threshold anomali — sesuai DATA_CONTRACT
# ============================================================
THRESHOLDS = {
    "temperature":   {"warning": 35.0,  "critical": 45.0},
    "humidity":      {"warning": 80.0,  "critical": 90.0},
    "vibration_rms": {"warning": 2.0,   "critical": 5.0},
    "flux_ppm":      {"warning": 35.0,  "critical": 75.0},
}


def get_engine():
    user     = os.getenv("POSTGRES_USER")
    password = os.getenv("POSTGRES_PASSWORD")
    host     = os.getenv("POSTGRES_HOST", "localhost")
    port     = os.getenv("POSTGRES_PORT", "5432")
    dbname   = os.getenv("POSTGRES_DB")
    return create_engine(f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{dbname}")


def save_job_log(engine, job_id, started_at, finished_at, worker_count,
                 records_processed, execution_time_sec, status):
    sql = text("""
        INSERT INTO spark_job_log
            (job_id, started_at, finished_at, worker_count,
             records_processed, execution_time_sec, status)
        VALUES
            (:job_id, :started_at, :finished_at, :worker_count,
             :records_processed, :execution_time_sec, :status)
    """)
    with engine.connect() as conn:
        conn.execute(sql, {
            "job_id": job_id, "started_at": started_at,
            "finished_at": finished_at, "worker_count": worker_count,
            "records_processed": records_processed,
            "execution_time_sec": execution_time_sec, "status": status,
        })
        conn.commit()


def save_analytics(engine, rows, job_id):
    sql = text("""
        INSERT INTO analytics_results
            (computed_at, window_start, window_end,
             device_id, location, metric_name, metric_value, job_id)
        VALUES
            (:computed_at, :window_start, :window_end,
             :device_id, :location, :metric_name, :metric_value, :job_id)
    """)
    with engine.connect() as conn:
        conn.execute(sql, rows)
        conn.commit()


def save_anomalies(engine, rows):
    sql = text("""
        INSERT INTO anomaly_events
            (event_time, device_id, location,
             sensor_type, observed_value, threshold_value, severity)
        VALUES
            (:event_time, :device_id, :location,
             :sensor_type, :observed_value, :threshold_value, :severity)
    """)
    with engine.connect() as conn:
        conn.execute(sql, rows)
        conn.commit()


def run(parquet_path: str, worker_count: int = 0):
    job_id     = str(uuid.uuid4())[:8]
    started_at = datetime.now(timezone.utc)

    logger.info(f"Job ID   : {job_id}")
    logger.info(f"Input    : {parquet_path}")
    logger.info(f"Workers  : {worker_count}")

    # --------------------------------------------------------
    # Init Spark — local mode + S3A config
    # --------------------------------------------------------
    spark = SparkSession.builder \
        .appName(f"iot_analytics_{job_id}") \
        .master("local[*]") \
        .config("spark.hadoop.fs.s3a.impl",
                "org.apache.hadoop.fs.s3a.S3AFileSystem") \
        .config("spark.hadoop.fs.s3a.aws.credentials.provider",
                "com.amazonaws.auth.InstanceProfileCredentialsProvider") \
        .config("spark.hadoop.fs.s3a.endpoint",
                "s3.ap-southeast-1.amazonaws.com") \
        .getOrCreate()

    spark.sparkContext.setLogLevel("WARN")

    # --------------------------------------------------------
    # Normalise path — Spark butuh s3a://, bukan s3://
    # --------------------------------------------------------
    parquet_path = parquet_path.replace("s3://", "s3a://", 1)

    # --------------------------------------------------------
    # Baca Parquet
    # --------------------------------------------------------
    df = spark.read.parquet(parquet_path)
    total_records = df.count()
    logger.info(f"Records  : {total_records}")

    # Window waktu dari data
    window_start = df.agg(F.min("time")).collect()[0][0]
    window_end   = df.agg(F.max("time")).collect()[0][0]

    # --------------------------------------------------------
    # Agregasi per device
    # --------------------------------------------------------
    agg_df = df.groupBy("device_id", "location").agg(
        F.avg("temperature").alias("avg_temperature"),
        F.max("temperature").alias("max_temperature"),
        F.min("temperature").alias("min_temperature"),
        F.avg("humidity").alias("avg_humidity"),
        F.avg("vibration_rms").alias("avg_vibration_rms"),
        F.max("vibration_rms").alias("max_vibration_rms"),
        F.avg("flux_ppm").alias("avg_flux_ppm"),
        F.max("flux_ppm").alias("max_flux_ppm"),
    )

    # Konversi ke list of dict untuk disimpan ke DB
    now = datetime.now(timezone.utc)
    analytics_rows = []
    for row in agg_df.collect():
        for metric, value in row.asDict().items():
            if metric in ("device_id", "location") or value is None:
                continue
            analytics_rows.append({
                "computed_at":  now,
                "window_start": window_start,
                "window_end":   window_end,
                "device_id":    row["device_id"],
                "location":     row["location"],
                "metric_name":  metric,
                "metric_value": float(value),
                "job_id":       job_id,
            })

    # --------------------------------------------------------
    # Anomali detection — threshold sederhana
    # --------------------------------------------------------
    anomaly_rows = []
    for sensor, thres in THRESHOLDS.items():
        anomalies = df.filter(
            F.col(sensor).isNotNull() & (F.col(sensor) > thres["warning"])
        ).select("time", "device_id", "location", sensor).collect()

        for row in anomalies:
            val = row[sensor]
            severity = "CRITICAL" if val > thres["critical"] else "MEDIUM"
            anomaly_rows.append({
                "event_time":      row["time"],
                "device_id":       row["device_id"],
                "location":        row["location"],
                "sensor_type":     sensor,
                "observed_value":  float(val),
                "threshold_value": thres["warning"],
                "severity":        severity,
            })

    # --------------------------------------------------------
    # Simpan ke DB
    # --------------------------------------------------------
    engine = get_engine()
    try:
        save_analytics(engine, analytics_rows, job_id)
        logger.info(f"Analytics tersimpan: {len(analytics_rows)} metric")

        if anomaly_rows:
            save_anomalies(engine, anomaly_rows)
            logger.info(f"Anomali tersimpan: {len(anomaly_rows)} event")
        else:
            logger.info("Tidak ada anomali terdeteksi")

        finished_at        = datetime.now(timezone.utc)
        execution_time_sec = (finished_at - started_at).total_seconds()

        save_job_log(
            engine, job_id, started_at, finished_at,
            worker_count, total_records, execution_time_sec, "SUCCESS"
        )
        logger.info(f"Selesai dalam {execution_time_sec:.2f} detik")

    except Exception as e:
        finished_at        = datetime.now(timezone.utc)
        execution_time_sec = (finished_at - started_at).total_seconds()
        save_job_log(
            engine, job_id, started_at, finished_at,
            worker_count, total_records, execution_time_sec, "FAILED"
        )
        logger.error(f"Job gagal: {e}")
        raise
    finally:
        engine.dispose()
        spark.stop()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: spark-submit batch_analytics.py <parquet_path> [worker_count]")
        print("Contoh: spark-submit batch_analytics.py data/parquet/sensor_xxx.parquet 0")
        sys.exit(1)

    parquet_path = sys.argv[1]
    worker_count = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    run(parquet_path, worker_count)