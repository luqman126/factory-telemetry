# ============================================================
# spark-jobs/export_to_parquet.py
# Export data sensor dari TimescaleDB ke file Parquet lokal
# Dijalankan sebelum batch_analytics.py
# ============================================================

import os
import logging
from pathlib import Path
from datetime import datetime, timezone, timedelta

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

# Direktori output Parquet — dibuat otomatis kalau belum ada
OUTPUT_DIR = Path(__file__).parent / "data" / "parquet"

# Window waktu export: default 1 jam terakhir
# Bisa diubah sesuai kebutuhan
WINDOW_HOURS = 1


def get_engine():
    user     = os.getenv("POSTGRES_USER")
    password = os.getenv("POSTGRES_PASSWORD")
    host     = os.getenv("POSTGRES_HOST", "localhost")
    port     = os.getenv("POSTGRES_PORT", "5432")
    dbname   = os.getenv("POSTGRES_DB")
    return create_engine(f"postgresql+psycopg2://{user}:{password}@{host}:{port}/{dbname}")


def export(window_hours: int = WINDOW_HOURS) -> Path:
    """
    Query sensor_readings dalam window waktu tertentu,
    simpan sebagai file Parquet dengan nama berdasarkan timestamp.
    Kembalikan path file yang dihasilkan.
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

    # Buat direktori output kalau belum ada
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Nama file berdasarkan timestamp window
    filename = f"sensor_{from_time.strftime('%Y%m%d_%H%M%S')}_{now.strftime('%Y%m%d_%H%M%S')}.parquet"
    output_path = OUTPUT_DIR / filename

    df["time"] = pd.to_datetime(df["time"])
    df["time"] = df["time"].dt.tz_localize(None)  # kalau ada timezone
    df["time"] = df["time"].astype("datetime64[us]")    
    
    df.to_parquet(output_path, index=False, engine="pyarrow")
    logger.info(f"Parquet tersimpan: {output_path} ({output_path.stat().st_size / 1024:.1f} KB)")

    return output_path


if __name__ == "__main__":
    path = export()
    if path:
        print(f"\nOutput: {path}")