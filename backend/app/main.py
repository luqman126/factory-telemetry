# ============================================================
# app/main.py
# Entry point FastAPI — menyatukan semua komponen
# ============================================================

import logging
import os

from contextlib import asynccontextmanager
from fastapi import FastAPI
from dotenv import load_dotenv

from app.mqtt.consumer import start_mqtt_consumer, stop_flush_timer
from app.routes.sensor import router as sensor_router
from app.db import init_pool, close_pool

load_dotenv()

# ============================================================
# Logging
# ============================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
logger = logging.getLogger(__name__)


# ============================================================
# Lifespan — startup & shutdown
# Ini cara FastAPI modern untuk menggantikan @app.on_event
# ============================================================
@asynccontextmanager
async def lifespan(app: FastAPI):
    # --- Startup ---
    logger.info("Backend starting...")
    init_pool()
    logger.info("Connection pool siap")
    mqtt_client = start_mqtt_consumer()
    app.state.mqtt_client = mqtt_client
    logger.info("MQTT consumer aktif")

    yield  # aplikasi berjalan di sini

    # --- Shutdown ---
    logger.info("Backend shutting down...")
    stop_flush_timer()
    app.state.mqtt_client.loop_stop()
    app.state.mqtt_client.disconnect()
    close_pool()
    logger.info("Koneksi ditutup")


# ============================================================
# Aplikasi
# ============================================================
app = FastAPI(
    title="IoT Manufacturing Monitor — Backend",
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(sensor_router)


# ============================================================
# Health check
# ============================================================
@app.get("/health")
async def health():
    """Deep health check — verifies DB and MQTT are actually connected."""
    from app.db import POOL

    # Check DB
    db_ok = False
    try:
        conn = POOL.getconn()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
            db_ok = True
        finally:
            POOL.putconn(conn)
    except Exception:
        pass

    # Check MQTT
    mqtt_ok = app.state.mqtt_client.is_connected()

    status = "ok" if (db_ok and mqtt_ok) else "degraded"
    return {"status": status, "db": db_ok, "mqtt": mqtt_ok}