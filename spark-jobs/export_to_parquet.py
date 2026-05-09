# ============================================================
# spark-jobs/export_to_parquet.py
# Export data sensor dari TimescaleDB ke S3 (via Parquet lokal)
# Dijalankan sebelum batch_analytics.py
# ============================================================

import os
import logging
from pathlib import Path
from datetime import datetime, timezone, timedelta

import boto3
import pandas as pd
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
# Konfigurasi
# ============================================================
OUTPUT_DIR  = Path(__file__).parent / "data" / "parquet"
WINDOW_HOURS = 1
S3_BUCKET   = os.getenv("S3_BUCKET", "iot-bigdata-datalake-kagebyo")
S3_PREFIX   = "raw"


def get_engine():
    user     = os.getenv("POSTGRES_USER")
    password = os.getenv("POSTGRES_PASSWORD")
    host     = os.getenv("POSTGRES_HOST", "localhost")
    port     = os.getenv("POSTGRES_PORT", "5432")
    dbname   = os.getenv("POSTGRES_DB")
    return create_engine(f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{dbname}")


def upload_to_s3(local_path: Path, s3_key: str) -> str:
    """
    Upload file lokal ke S3.
    Pakai IAM Role — tidak perlu credentials eksplisit.
    Kembalikan S3 URI lengkap.
    """
    s3 = boto3.client("s3", region_name="ap-southeast-1")
    s3.upload_file(str(local_path), S3_BUCKET, s3_key)
    s3_uri = f"s3://{S3_BUCKET}/{s3_key}"
    logger.info(f"Upload ke S3: {s3_uri}")
    return s3_uri


def export(window_hours: int = WINDOW_HOURS) -> str:
    """
    Query sensor_readings, simpan ke Parquet lokal,
    upload ke S3, hapus file lokal.
    Kembalikan S3 URI file yang diupload.
    """
    now       = datetime.now(timezone.utc)
    from_time = now - timedelta(hours=window_hours)

    logger.info(f"Export window: {from_time.isoformat()} → {now.isoformat()}")

    sql = """
        SELECT
            time, device_id, location,
            temperature, humidity,
            accel_x, accel_y, accel_z, vibration_rms,
            flux_ppm, flux_aqi, voc_level
        FROM sensor_readings
        WHERE time >= :from_time AND time < :now
        ORDER BY time ASC
    """

    engine = get_engine()
    try:
        with engine.connect() as conn:
            df = pd.read_sql(
                text(sql),
                conn,
                params={"from_time": from_time, "now": now}
            )
    finally:
        engine.dispose()

    if df.empty:
        logger.warning("Tidak ada data dalam window waktu ini, export dibatalkan")
        return None

    logger.info(f"Berhasil query {len(df)} baris dari DB")

    # Fix timestamp supaya kompatibel dengan Spark
    df["time"] = pd.to_datetime(df["time"])
    df["time"] = df["time"].dt.tz_localize(None)
    df["time"] = df["time"].astype("datetime64[us]")

    # Simpan ke lokal dulu
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    filename    = f"sensor_{from_time.strftime('%Y%m%d_%H%M%S')}_{now.strftime('%Y%m%d_%H%M%S')}.parquet"
    local_path  = OUTPUT_DIR / filename

    df.to_parquet(local_path, index=False, engine="pyarrow")
    logger.info(f"Parquet lokal: {local_path} ({local_path.stat().st_size / 1024:.1f} KB)")

    # Upload ke S3
    s3_key = f"{S3_PREFIX}/{filename}"
    s3_uri = upload_to_s3(local_path, s3_key)

    # Hapus file lokal setelah upload berhasil
    local_path.unlink()
    logger.info("File lokal dihapus setelah upload")

    return s3_uri


if __name__ == "__main__":
    uri = export()
    if uri:
        print(f"\nS3 URI: {uri}")
    