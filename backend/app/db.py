# ============================================================
# app/db.py
# Koneksi ke PostgreSQL / TimescaleDB
# ============================================================

import os
from pathlib import Path
from typing import List, Dict, Any

import psycopg2
from psycopg2.pool import SimpleConnectionPool
from psycopg2.extras import execute_batch
from dotenv import load_dotenv

# Tunjuk eksplisit ke infra/.env
# __file__ = backend/app/db.py
# .parents[2] = backend/
# lalu naik satu lagi ke root project, masuk ke infra/
_ENV_PATH = Path(__file__).parents[2] / "infra" / ".env"
load_dotenv(dotenv_path=_ENV_PATH)

# ============================================================
# Connection Pool
# POOL dimulai sebagai None, baru diinisialisasi saat
# init_pool() dipanggil dari main.py pada saat startup.
# Ini supaya koneksi tidak dibuat saat module di-import.
# ============================================================
POOL: SimpleConnectionPool | None = None


def init_pool() -> None:
    """
    Inisialisasi connection pool.
    Dipanggil sekali dari main.py saat aplikasi startup.
    """
    global POOL
    POOL = SimpleConnectionPool(
        minconn=1,
        maxconn=10,
        host=os.getenv("POSTGRES_HOST", "localhost"),
        port=int(os.getenv("POSTGRES_PORT", 5432)),
        dbname=os.getenv("POSTGRES_DB"),
        user=os.getenv("POSTGRES_USER"),
        password=os.getenv("POSTGRES_PASSWORD"),
    )


def close_pool() -> None:
    """
    Tutup semua koneksi di pool.
    Dipanggil dari main.py saat aplikasi shutdown.
    """
    if POOL:
        POOL.closeall()


# ============================================================
# SQL
# ============================================================
_INSERT_SQL = """
    INSERT INTO sensor_readings (
        time, device_id, location,
        temperature, humidity,
        accel_x, accel_y, accel_z, vibration_rms,
        flux_ppm, flux_aqi, voc_level
    ) VALUES (
        %(time)s, %(device_id)s, %(location)s,
        %(temperature)s, %(humidity)s,
        %(accel_x)s, %(accel_y)s, %(accel_z)s, %(vibration_rms)s,
        %(flux_ppm)s, %(flux_aqi)s, %(voc_level)s
    )
"""


# ============================================================
# Single insert — dipakai MQTT consumer (satu pesan = satu row)
# ============================================================
def insert_one(payload: Dict[str, Any]) -> None:
    conn = POOL.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(_INSERT_SQL, payload)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        POOL.putconn(conn)


# ============================================================
# Batch insert
# ============================================================
def insert_batch(payloads: List[Dict[str, Any]]) -> None:
    if not payloads:
        return
    conn = POOL.getconn()
    try:
        with conn.cursor() as cur:
            execute_batch(cur, _INSERT_SQL, payloads, page_size=100)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        POOL.putconn(conn)