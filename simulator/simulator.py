# ============================================================
# simulator/simulator.py
# Simulasi IoT device yang publish data sensor ke MQTT broker
# Mensimulasikan 3 ruangan sesuai hardware plan:
#   - ruang_produksi  : DHT22 + MPU6050
#   - ruang_penyolderan: DHT22 + MQ-135
#   - ruang_penyimpanan: DHT22
# ============================================================

import json
import time
import math
import random
import logging
import os
from datetime import datetime, timezone
from pathlib import Path

import paho.mqtt.client as mqtt
from dotenv import load_dotenv

_ENV_PATH = Path(__file__).parents[1] / "infra" / ".env"
load_dotenv(dotenv_path=_ENV_PATH)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger(__name__)

# ============================================================
# Konfigurasi device
# Setiap entry merepresentasikan satu ruangan
# ============================================================
DEVICES = [
    {
        "device_id": "device_001",
        "location":  "ruang_produksi",
        "sensors":   ["dht22", "mpu6050"],
    },
    {
        "device_id": "device_002",
        "location":  "ruang_penyolderan",
        "sensors":   ["dht22", "mq135"],
    },
    {
        "device_id": "device_003",
        "location":  "ruang_penyimpanan",
        "sensors":   ["dht22"],
    },
]

# ============================================================
# Baseline nilai sensor per ruangan
# Nilai ini jadi titik tengah, noise ditambahkan di atasnya
# ============================================================
BASELINE = {
    "ruang_produksi": {
        "temperature": 30.0,
        "humidity":    60.0,
        "accel_z":     9.81,   # gravitasi normal
    },
    "ruang_penyolderan": {
        "temperature": 32.0,   # lebih panas karena proses soldering
        "humidity":    55.0,
        "flux_ppm":    20.0,   # kadar uap flux normal
    },
    "ruang_penyimpanan": {
        "temperature": 25.0,
        "humidity":    50.0,
    },
}

# ============================================================
# Counter global untuk inject anomali periodik
# ============================================================
_tick = 0


def noise(scale: float = 1.0) -> float:
    """Gaussian noise kecil untuk bikin data terasa realistis."""
    return random.gauss(0, scale)


def maybe_anomaly(value: float, threshold: float, chance: float = 0.02) -> float:
    """
    Dengan probabilitas `chance`, kembalikan nilai anomali
    yang jauh melewati threshold. Sisanya kembalikan nilai normal.
    """
    if random.random() < chance:
        return threshold * random.uniform(1.2, 1.8)
    return value


def build_payload(device: dict) -> dict:
    """
    Bangun satu payload JSON sesuai sensor yang dimiliki device.
    Field yang tidak ada di device ini akan bernilai None.
    """
    location = device["location"]
    base     = BASELINE[location]
    sensors  = device["sensors"]

    payload: dict = {
        "time":          datetime.now(timezone.utc).isoformat(),
        "device_id":     device["device_id"],
        "location":      location,
        "temperature":   None,
        "humidity":      None,
        "accel_x":       None,
        "accel_y":       None,
        "accel_z":       None,
        "vibration_rms": None,
        "flux_ppm":      None,
        "flux_aqi":      None,
        "voc_level":     None,
    }

    # DHT22 — suhu & kelembaban (semua ruangan)
    if "dht22" in sensors:
        temp = base["temperature"] + noise(0.5)
        temp = maybe_anomaly(temp, threshold=45.0)
        payload["temperature"] = round(temp, 2)
        payload["humidity"]    = round(base["humidity"] + noise(1.0), 2)

    # MPU6050 — accelerometer & getaran (ruang produksi)
    if "mpu6050" in sensors:
        # 98% bernilai 0 (normal), 2% peluang anomali/bergetar bernilai 1
        vibration_status = 1 if random.random() < 0.02 else 0
        payload["accel_x"]        = None
        payload["accel_y"]        = None
        payload["accel_z"]        = None
        payload["vibration_rms"]  = float(vibration_status)

    # MQ-135 — uap flux / gas (ruang penyolderan)
    if "mq135" in sensors:
        is_hazardous = random.random() < 0.02
        payload["flux_ppm"] = None
        payload["flux_aqi"] = None
        payload["voc_level"] = "HAZARDOUS" if is_hazardous else "GOOD"

    return payload


def run(interval_sec: float = 2.0) -> None:
    """
    Loop utama simulator.
    Setiap `interval_sec` detik, publish satu payload per device.
    """
    global _tick

    broker_host = os.getenv("MQTT_BROKER_HOST", "localhost")
    broker_port = int(os.getenv("MQTT_BROKER_PORT", 1883))

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)

    # Auth jika dikonfigurasi
    mqtt_user = os.getenv("MQTT_USER")
    mqtt_pass = os.getenv("MQTT_PASSWORD")
    if mqtt_user and mqtt_pass:
        client.username_pw_set(mqtt_user, mqtt_pass)

    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    logger.info(f"Simulator aktif — {len(DEVICES)} device, interval {interval_sec}s")

    try:
        while True:
            _tick += 1
            for device in DEVICES:
                payload  = build_payload(device)
                topic    = f"iot/sensor/{device['device_id']}/{device['location']}"
                message  = json.dumps(payload)

                client.publish(topic, message, qos=1)
                logger.info(f"[tick {_tick}] {topic} → {message}")

            time.sleep(interval_sec)

    except KeyboardInterrupt:
        logger.info("Simulator dihentikan")
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    run(interval_sec=2.0)