# ============================================================
# app/routes/sensor.py
# HTTP endpoint untuk ingestion data sensor
# ============================================================

import logging
from fastapi import APIRouter, HTTPException, status

from app.models.sensor import SensorPayload
from app.db import insert_one

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/sensors", tags=["sensors"])


# ------------------------------------------------------------
# POST /sensors/ingest
# Terima satu payload sensor via HTTP, simpan ke DB
# Ini alternatif selain MQTT — berguna untuk testing manual
# ------------------------------------------------------------
@router.post("/ingest", status_code=status.HTTP_201_CREATED)
async def ingest_sensor(payload: SensorPayload):
    try:
        data = payload.model_dump()
        data["time"] = payload.time.isoformat()
        insert_one(data)
        logger.info(f"HTTP ingest: {payload.device_id} | {payload.location}")
        return {"status": "ok", "device_id": payload.device_id}
    except Exception as e:
        logger.error(f"Gagal insert via HTTP: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Gagal menyimpan data sensor"
        )


# ------------------------------------------------------------
# GET /sensors/latest/{device_id}
# Ambil data terbaru dari device tertentu
# Berguna untuk verifikasi data masuk saat testing
# ------------------------------------------------------------
@router.get("/latest/{device_id}")
async def get_latest(device_id: str):
    from app.db import POOL
    conn = POOL.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT * FROM sensor_readings
                WHERE device_id = %s
                ORDER BY time DESC
                LIMIT 5
                """,
                (device_id,)
            )
            rows = cur.fetchall()
        return {"device_id": device_id, "data": rows}
    except Exception as e:
        logger.error(f"Gagal ambil data: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Gagal mengambil data"
        )
    finally:
        POOL.putconn(conn)