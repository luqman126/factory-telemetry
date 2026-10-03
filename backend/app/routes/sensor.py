# ============================================================
# app/routes/sensor.py
# HTTP endpoints for sensor data ingestion and retrieval
# ============================================================

import logging
from fastapi import APIRouter, HTTPException, status

from app.models.sensor import SensorPayload
from app.db import insert_one

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/sensors", tags=["sensors"])


# ------------------------------------------------------------
# POST /sensors/ingest
# Ingest a single sensor payload via HTTP and persist to DB
# Alternative ingestion path to MQTT — useful for manual testing
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
        logger.error(f"Failed HTTP ingest: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to persist sensor data"
        )


# ------------------------------------------------------------
# GET /sensors/latest/{device_id}
# Retrieve recent readings for a specific device
# Useful for ingestion verification during testing
# ------------------------------------------------------------
@router.get("/latest/{device_id}")
async def get_latest(device_id: str):
    from app.db import POOL
    from psycopg2.extras import RealDictCursor
    conn = POOL.getconn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
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
        logger.error(f"Failed to fetch data: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to retrieve sensor data"
        )
    finally:
        POOL.putconn(conn)