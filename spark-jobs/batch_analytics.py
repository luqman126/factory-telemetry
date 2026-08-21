# ============================================================
# spark-jobs/batch_analytics.py
# Spark batch job: baca Parquet, hitung analytics, simpan ke DB
# Jalankan: spark-submit [options] batch_analytics.py <path_parquet> <worker_count>
# Contoh:   spark-submit --master "local[*]" batch_analytics.py data/parquet/sensor_xxx.parquet 0
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
    "temperature":   {"warning": 35.0,  "critical": 35.0},
    "humidity":      {"warning": 80.0,  "critical": 90.0},
    "vibration_rms": {"warning": 1.0,   "critical": 1.0},
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


def save_analytics(engine, rows, job_id, window_start, window_end):
    # Delete previous results for this window (idempotent re-run)
    delete_sql = text("""
        DELETE FROM analytics_results
        WHERE window_start = :window_start AND window_end = :window_end
    """)
    insert_sql = text("""
        INSERT INTO analytics_results
            (computed_at, window_start, window_end,
             device_id, location, metric_name, metric_value, job_id)
        VALUES
            (:computed_at, :window_start, :window_end,
             :device_id, :location, :metric_name, :metric_value, :job_id)
    """)
    with engine.connect() as conn:
        conn.execute(delete_sql, {"window_start": window_start, "window_end": window_end})
        conn.execute(insert_sql, rows)
        conn.commit()


def save_anomalies(engine, rows, window_start, window_end):
    # Delete previous anomalies for this window (idempotent re-run)
    delete_sql = text("""
        DELETE FROM anomaly_events
        WHERE event_time >= :window_start AND event_time <= :window_end
    """)
    insert_sql = text("""
        INSERT INTO anomaly_events
            (event_time, device_id, location,
             sensor_type, observed_value, threshold_value, severity)
        VALUES
            (:event_time, :device_id, :location,
             :sensor_type, :observed_value, :threshold_value, :severity)
    """)
    with engine.connect() as conn:
        conn.execute(delete_sql, {"window_start": window_start, "window_end": window_end})
        conn.execute(insert_sql, rows)
        conn.commit()


def run(parquet_path: str, worker_count: int = 0):
    job_id     = str(uuid.uuid4())[:8]
    started_at = datetime.now(timezone.utc)

    logger.info(f"Job ID   : {job_id}")
    logger.info(f"Input    : {parquet_path}")
    logger.info(f"Workers  : {worker_count}")

    # --------------------------------------------------------
    # Init Spark — master URL ditentukan oleh spark-submit --master
    # Kalau tidak di-set, default fallback ke local[*]
    # --------------------------------------------------------
    spark_builder = SparkSession.builder \
        .appName(f"iot_analytics_{job_id}") \
        .config("spark.hadoop.fs.s3a.impl",
                "org.apache.hadoop.fs.s3a.S3AFileSystem") 
         
    # Local MinIO mode (if credentials /endpoint are set in .env)   
    if os.getenv("AWS_ACCESS_KEY_ID") and os.getenv("AWS_SECRET_ACCESS_KEY"):
        spark_builder = spark_builder \
            .config("spark.hadoop.fs.s3a.endpoint", os.getenv("AWS_ENDPOINT_URL", "http://minio:9000")) \
            .config("spark.hadoop.fs.s3a.access.key", os.getenv("AWS_ACCESS_KEY_ID")) \
            .config("spark.hadoop.fs.s3a.secret.key", os.getenv("AWS_SECRET_ACCESS_KEY")) \
            .config("spark.hadoop.fs.s3a.path.style.access", "true") \
            .config("spark.hadoop.fs.s3a.connection.ssl.enabled", "false") \
            .config("spark.hadoop.fs.s3a.aws.credentials.provider", "org.apache.hadoop.fs.s3a.SimpleAWSCredentialsProvider")
    else:
        # Production AWS EC2 Mode (IAM Instance Profile)
        spark_builder = spark_builder \
            .config("spark.hadoop.fs.s3a.aws.credentials.provider", "com.amazonaws.auth.InstanceProfileCredentialsProvider") \
            .config("spark.hadoop.fs.s3a.endpoint", "s3.ap-southeast-1.amazonaws.com")

    spark = spark_builder.getOrCreate()
    logger.info(f"Spark master: {spark.sparkContext.master}")

    spark.sparkContext.setLogLevel("WARN")

    # --------------------------------------------------------
    # Normalise path — Spark butuh s3a://, bukan s3://
    # --------------------------------------------------------
    parquet_path = parquet_path.replace("s3://", "s3a://", 1)

    # --------------------------------------------------------
    # Baca Parquet + smart repartition + cache
    # df di-cache karena dipakai untuk multiple actions:
    # count, agg time, groupBy, anomaly detection
    # Tanpa cache, setiap action akan re-read dari S3 → SLOW
    # --------------------------------------------------------
    df = spark.read.parquet(parquet_path)

    # Smart repartition sebelum cache (banyak partisi = data per partisi kecil, mencegah OOM)
    if worker_count > 0:
        num_partitions = max(worker_count * 10, 20)
        df = df.repartition(num_partitions)
        logger.info(f"Repartitioned to {num_partitions} partitions")

    df = df.cache()
    total_records = df.count()  # Trigger cache materialization
    logger.info(f"Records  : {total_records}")

    # --------------------------------------------------------
    # Window waktu — gabung min+max dalam 1 agg call (1 action)
    # --------------------------------------------------------
    window_row = df.agg(
        F.min("time").alias("ws"),
        F.max("time").alias("we")
    ).collect()[0]
    window_start = window_row["ws"]
    window_end   = window_row["we"]

    # --------------------------------------------------------
    # Agregasi per device (small output, aman collect)
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
    # Anomali detection — distributed write via JDBC
    # Tidak collect ke driver — executor langsung write ke DB
    # --------------------------------------------------------
    anomaly_dfs = []
    for sensor, thres in THRESHOLDS.items():
        anomaly_df = df.filter(
            F.col(sensor).isNotNull() & (F.col(sensor) >= thres["warning"])
        ).select(
            F.col("time").alias("event_time"),
            F.col("device_id"),
            F.col("location"),
            F.lit(sensor).alias("sensor_type"),
            F.col(sensor).cast("double").alias("observed_value"),
            F.lit(thres["warning"]).alias("threshold_value"),
            F.when(F.col(sensor) >= thres["critical"], "CRITICAL")
             .otherwise("MEDIUM").alias("severity"),
        )
        anomaly_dfs.append(anomaly_df)

    # Check voc_level string anomalies (GOOD vs HAZARDOUS)
    voc_anomaly_df = df.filter(
        F.col("voc_level").isNotNull() & (F.col("voc_level") == "HAZARDOUS")
    ).select(
        F.col("time").alias("event_time"),
        F.col("device_id"),
        F.col("location"),
        F.lit("voc_level").alias("sensor_type"),
        F.lit(1.0).alias("observed_value"),
        F.lit(0.0).alias("threshold_value"),
        F.lit("CRITICAL").alias("severity"),
    )
    anomaly_dfs.append(voc_anomaly_df)

    # Union all sensor anomalies
    anomaly_combined = anomaly_dfs[0]
    for adf in anomaly_dfs[1:]:
        anomaly_combined = anomaly_combined.unionByName(adf)

    # Coalesce ke jumlah partition kecil untuk JDBC write
    # Terlalu banyak partition = terlalu banyak DB connection paralel
    anomaly_combined = anomaly_combined.coalesce(2)

    # --------------------------------------------------------
    # Simpan ke DB
    # --------------------------------------------------------
    engine = get_engine()

    # JDBC connection params untuk distributed write
    jdbc_url = f"jdbc:postgresql://{os.getenv('POSTGRES_HOST')}:{os.getenv('POSTGRES_PORT', '5432')}/{os.getenv('POSTGRES_DB')}"
    jdbc_props = {
        "user": os.getenv("POSTGRES_USER"),
        "password": os.getenv("POSTGRES_PASSWORD"),
        "driver": "org.postgresql.Driver",
    }

    try:
        save_analytics(engine, analytics_rows, job_id, window_start, window_end)
        logger.info(f"Analytics tersimpan: {len(analytics_rows)} metric")

        # Delete existing anomalies in window (idempotent re-run)
        with engine.connect() as conn:
            conn.execute(text("""
                DELETE FROM anomaly_events
                WHERE event_time >= :ws AND event_time <= :we
            """), {"ws": window_start, "we": window_end})
            conn.commit()

        # Distributed write — executor langsung tulis ke DB paralel
        # Tidak ada count() dulu — write langsung, kalau kosong = no-op
        anomaly_combined.write \
            .mode("append") \
            .option("batchsize", 5000) \
            .jdbc(url=jdbc_url, table="anomaly_events", properties=jdbc_props)
        logger.info("Anomali tersimpan via distributed JDBC write")

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