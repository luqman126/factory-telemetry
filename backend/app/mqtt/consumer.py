# ============================================================
# app/mqtt/consumer.py
# Subscribe ke MQTT broker, terima payload sensor, simpan ke DB
# ============================================================

import json
import logging
import os

import paho.mqtt.client as mqtt
from dotenv import load_dotenv
from pydantic import ValidationError

from app.models.sensor import SensorPayload
from app.db import insert_one

load_dotenv()

logger = logging.getLogger(__name__)

# Topic yang di-subscribe: semua device, semua ruangan
# + artinya wildcard satu level, contoh: iot/sensor/device_001/ruang_produksi
MQTT_TOPIC = "iot/sensor/+/+"


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
    Alur: decode JSON → validasi Pydantic → insert ke DB
    """
    try:
        # Decode payload dari bytes ke string lalu parse JSON
        raw = json.loads(msg.payload.decode("utf-8"))

        # Validasi dengan Pydantic — kalau tidak sesuai schema, lempar ValidationError
        payload = SensorPayload(**raw)

        # Konversi ke dict untuk di-insert ke DB
        # model_dump() menghasilkan dict dengan semua field termasuk None
        data = payload.model_dump()

        # Konversi datetime ke string ISO supaya psycopg2 bisa handle
        data["time"] = payload.time.isoformat()

        insert_one(data)
        logger.info(f"Data tersimpan: {payload.device_id} | {payload.location}")

    except json.JSONDecodeError as e:
        logger.error(f"Payload bukan JSON valid: {e}")
    except ValidationError as e:
        logger.error(f"Payload tidak sesuai schema: {e}")
    except Exception as e:
        logger.error(f"Gagal simpan data: {e}")


def on_disconnect(client, userdata, flags, reason_code, properties):
    if reason_code != 0:
        logger.warning(f"MQTT terputus, reason code: {reason_code}")


def start_mqtt_consumer() -> mqtt.Client:
    """
    Inisialisasi dan jalankan MQTT client.
    Dipanggil dari main.py saat backend start.
    """
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect    = on_connect
    client.on_message    = on_message
    client.on_disconnect = on_disconnect

    broker_host = os.getenv("MQTT_BROKER_HOST", "localhost")
    broker_port = int(os.getenv("MQTT_BROKER_PORT", 1883))

    client.connect(broker_host, broker_port, keepalive=60)

    # loop_start() menjalankan network loop di background thread
    # sehingga tidak memblokir FastAPI
    client.loop_start()

    return client