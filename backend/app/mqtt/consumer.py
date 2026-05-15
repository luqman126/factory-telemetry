# ============================================================
# app/mqtt/consumer.py
# Subscribe ke MQTT broker, terima payload sensor, simpan ke DB
# Menggunakan buffered batch insert untuk throughput tinggi
# ============================================================

import json
import logging
import os
import threading
import time

import paho.mqtt.client as mqtt
from dotenv import load_dotenv
from pydantic import ValidationError

from app.models.sensor import SensorPayload
from app.db import insert_batch

load_dotenv()

logger = logging.getLogger(__name__)

# Topic yang di-subscribe: semua device, semua ruangan
MQTT_TOPIC = "iot/sensor/+/+"

# Buffer config
BATCH_SIZE = 50
FLUSH_INTERVAL = 5.0  # detik

# Buffer dan lock
_buffer: list = []
_buffer_lock = threading.Lock()
_flush_timer: threading.Timer | None = None


def _flush_buffer() -> None:
    """Flush buffer ke DB. Dipanggil dari timer atau saat buffer penuh."""
    global _flush_timer
    with _buffer_lock:
        if not _buffer:
            _schedule_flush()
            return
        batch = _buffer.copy()
        _buffer.clear()

    try:
        insert_batch(batch)
        logger.info(f"Batch insert: {len(batch)} records")
    except Exception as e:
        logger.error(f"Batch insert gagal ({len(batch)} records): {e}")

    _schedule_flush()


def _schedule_flush() -> None:
    """Schedule next periodic flush."""
    global _flush_timer
    _flush_timer = threading.Timer(FLUSH_INTERVAL, _flush_buffer)
    _flush_timer.daemon = True
    _flush_timer.start()


def stop_flush_timer() -> None:
    """Stop timer dan flush sisa buffer. Dipanggil saat shutdown."""
    global _flush_timer
    if _flush_timer:
        _flush_timer.cancel()
    # Final flush
    with _buffer_lock:
        if _buffer:
            try:
                insert_batch(_buffer.copy())
                logger.info(f"Final flush: {len(_buffer)} records")
            except Exception as e:
                logger.error(f"Final flush gagal: {e}")
            _buffer.clear()


def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        logger.info("MQTT terhubung ke broker")
        client.subscribe(MQTT_TOPIC)
        logger.info(f"Subscribe ke topic: {MQTT_TOPIC}")
    else:
        logger.error(f"Gagal connect ke broker, reason code: {reason_code}")


def on_message(client, userdata, msg):
    """
    Dipanggil setiap ada pesan masuk dari broker.
    Alur: decode JSON → validasi Pydantic → buffer → flush saat penuh
    """
    try:
        raw = json.loads(msg.payload.decode("utf-8"))
        payload = SensorPayload(**raw)
        data = payload.model_dump()
        data["time"] = payload.time.isoformat()

        batch = None
        with _buffer_lock:
            _buffer.append(data)
            if len(_buffer) >= BATCH_SIZE:
                batch = _buffer.copy()
                _buffer.clear()

        if batch:
            try:
                insert_batch(batch)
                logger.info(f"Batch insert (full): {len(batch)} records")
            except Exception as e:
                logger.error(f"Batch insert gagal: {e}")

    except json.JSONDecodeError as e:
        logger.error(f"Payload bukan JSON valid: {e}")
    except ValidationError as e:
        logger.error(f"Payload tidak sesuai schema: {e}")
    except Exception as e:
        logger.error(f"Gagal proses pesan: {e}")


def on_disconnect(client, userdata, flags, reason_code, properties):
    if reason_code != 0:
        logger.warning(f"MQTT terputus, reason code: {reason_code}")


def start_mqtt_consumer() -> mqtt.Client:
    """
    Inisialisasi dan jalankan MQTT client.
    Dipanggil dari main.py saat backend start.
    """
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.on_message = on_message
    client.on_disconnect = on_disconnect

    broker_host = os.getenv("MQTT_BROKER_HOST", "localhost")
    broker_port = int(os.getenv("MQTT_BROKER_PORT", 1883))

    # Auth jika dikonfigurasi
    mqtt_user = os.getenv("MQTT_USER")
    mqtt_pass = os.getenv("MQTT_PASSWORD")
    if mqtt_user and mqtt_pass:
        client.username_pw_set(mqtt_user, mqtt_pass)

    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    # Start periodic flush timer
    _schedule_flush()

    return client
