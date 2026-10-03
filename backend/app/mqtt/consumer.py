# ============================================================
# app/mqtt/consumer.py
# Subscribe to MQTT broker, consume sensor payloads, persist to DB
# Implements buffered batch inserts for high ingestion throughput
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

# Subscribed topic pattern: all devices, all locations
MQTT_TOPIC = "iot/sensor/+/+"

# Buffer config
BATCH_SIZE = 50
FLUSH_INTERVAL = 5.0  # seconds

# Buffer and lock
_buffer: list = []
_buffer_lock = threading.Lock()
_flush_timer: threading.Timer | None = None

def _flush_buffer() -> None:
    """Flush buffer to DB. Triggered by timer or when buffer reaches capacity."""
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
        logger.error(f"Batch insert failed ({len(batch)} records): {e}")

    _schedule_flush()


def _schedule_flush() -> None:
    """Schedule next periodic flush."""
    global _flush_timer
    _flush_timer = threading.Timer(FLUSH_INTERVAL, _flush_buffer)
    _flush_timer.daemon = True
    _flush_timer.start()


def stop_flush_timer() -> None:
    """Stop timer and flush remaining buffer items. Invoked during shutdown."""
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
                logger.error(f"Final flush failed: {e}")
            _buffer.clear()


def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        logger.info("MQTT connected to broker successfully")
        client.subscribe(MQTT_TOPIC)
        logger.info(f"Sent subscription request for {MQTT_TOPIC}")
    else:
        logger.error(f"Failed to connect to MQTT broker, reason code: {reason_code}")

def on_subscribe(client, userdata, mid, reason_code_list, properties):
    logger.info(f"MQTT subscription acknowledged: mid={mid}, reason_codes={reason_code_list}")


def on_message(client, userdata, msg):
    """
    Invoked on each incoming message from broker.
    Pipeline: decode JSON -> Pydantic validation -> buffer -> flush when full
    """
    try:
        raw = json.loads(msg.payload.decode("utf-8"))
        payload = SensorPayload(**raw)
        data = payload.model_dump()
        data["time"] = payload.time.isoformat()

        # ============================================================
        # Real-time Closed-loop Control Loop
        # ============================================================
        device_id = payload.device_id
        location = payload.location
        temp = payload.temperature
        voc = payload.voc_level
        flux = payload.flux_ppm

        # Check existing fan state for this device
        current_fan = payload.fan_status or "OFF" # Read directly from reported state

        trigger_fan_on = False
        trigger_fan_off = False
        reason = ""

        # Logic for turning the Fan ON (overheat or gas leak)
        if temp is not None and temp > 35.0 and current_fan == "OFF":
            trigger_fan_on = True
            reason = f"Temperature exceeded threshold: {temp}°C"
        elif voc is not None and voc in ("HAZARDOUS", "UNHEALTHY") and current_fan == "OFF":
            trigger_fan_on = True
            reason = f"VOC Level is unsafe: {voc} ({flux} ppm)"

        # Logic for turning the Fan OFF (cooldown safety release)
        # Turn OFF only when BOTH temperature and flux are in safe zones
        elif current_fan == "ON":
            temp_safe = (temp is None or temp < 30.0)
            flux_safe = (flux is None or flux < 30.0)
            if temp_safe and flux_safe:
                trigger_fan_off = True
                reason = f"All metrics returned to safe range."
        
        # Dispatch command publishes
        if trigger_fan_on:        
            topic = f"iot/commands/{device_id}/{location}"
            cmd = {"actuator": "fan", "status" : "ON"}
            message  = json.dumps(cmd)

            client.publish(topic, message, qos=1)
            logger.warning(f"[CONTROL] Emergency on {device_id} ({location}): {reason}. Triggering Fan ON.")

        elif trigger_fan_off:
            topic = f"iot/commands/{device_id}/{location}"
            cmd = {"actuator": "fan", "status": "OFF"}
            message = json.dumps(cmd)

            client.publish(topic, message, qos=1)
            logger.info(f"[CONTROL] Safe condition restored on {device_id} ({location}). Turning Fan OFF.")

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
                logger.error(f"Batch insert failed: {e}")

    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON payload: {e}")
    except ValidationError as e:
        logger.error(f"Payload does not match schema: {e}")
    except Exception as e:
        logger.error(f"Failed to process message: {e}")


def on_disconnect(client, userdata, flags, reason_code, properties):
    if reason_code != 0:
        logger.warning(f"MQTT disconnected unexpectedly, reason code: {reason_code}")


def start_mqtt_consumer() -> mqtt.Client:
    """
    Initialize and start MQTT consumer client.
    Called from main.py during backend startup.
    """
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.on_subscribe = on_subscribe
    client.on_message = on_message
    client.on_disconnect = on_disconnect

    broker_host = os.getenv("MQTT_BROKER_HOST", "localhost")
    broker_port = int(os.getenv("MQTT_BROKER_PORT", 1883))

    # Authentication if configured
    mqtt_user = os.getenv("MQTT_USER")
    mqtt_pass = os.getenv("MQTT_PASSWORD")
    if mqtt_user and mqtt_pass:
        client.username_pw_set(mqtt_user, mqtt_pass)

    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    # Start periodic flush timer
    _schedule_flush()

    return client
