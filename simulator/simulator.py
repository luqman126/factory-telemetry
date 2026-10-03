# ============================================================
# simulator/simulator.py
# IoT Device Simulator that publishes sensor telemetry to MQTT.
# Simulates 3 factory rooms matching the hardware plan:
#   - ruang_produksi   : DHT22 + MPU6050 (Production Area)
#   - ruang_penyolderan: DHT22 + MQ-135 (Soldering Area)
#   - ruang_penyimpanan: DHT22 (Storage Area)
# ============================================================

import json
import time
import math
import random
import logging
import os
import argparse
import threading
from datetime import datetime, timezone
from pathlib import Path

import paho.mqtt.client as mqtt
from dotenv import load_dotenv

_SIMULATOR_ENV = Path(__file__).parents[1] / "infra" / ".env.simulator"
_DEFAULT_ENV = Path(__file__).parents[1] / "infra" / ".env"

load_dotenv(dotenv_path=_SIMULATOR_ENV if _SIMULATOR_ENV.exists() else _DEFAULT_ENV)

# Load logging level dynamically from environment variable (defaults to INFO)
log_level_str = os.getenv("LOG_LEVEL", "INFO").upper()
log_level = getattr(logging, log_level_str, logging.INFO)


logging.basicConfig(
    level=log_level,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger(__name__)

def get_sensors_for_location(location: str):
    if location == "ruang_produksi":
        return ["dht22", "mpu6050"]
    elif location == "ruang_penyolderan":
        return ["dht22", "mq135"]
    elif location == "ruang_penyimpanan":
        return ["dht22"]

# ============================================================
# Device configuration
# Each entry represent a single room
# ============================================================
def generate_devices(num_devices: int):
    if num_devices <= 3:
        return [
            {"device_id": "device_001", "location": "ruang_produksi", "sensors": ["dht22", "mpu6050"]},
            {"device_id": "device_002", "location": "ruang_penyolderan", "sensors": ["dht22", "mq135"]},
            {"device_id": "device_003", "location": "ruang_penyimpanan", "sensors": ["dht22"]},
        ]
    
    locations = ["ruang_produksi", "ruang_penyolderan", "ruang_penyimpanan"]

    devices_list = []
    for i in range(1, num_devices + 1):
        dev_id = f"device_{i:03d}"
        loc = locations[(i - 1) % len(locations)]
        sensor = get_sensors_for_location(loc)
        devices_list.append(
            {"device_id": dev_id, "location": loc, "sensors": sensor}
        )
    return devices_list

# ============================================================
# Sensor value baseline for each room
# These values will serve as the center point and random noise will be added around these values
# ============================================================
BASELINE = {
    "ruang_produksi": {
        "temperature": 30.0,
        "humidity":    60.0,
        "accel_z":     9.81,   # normal gravity
    },
    "ruang_penyolderan": {
        "temperature": 32.0,   # warmer due to soldering process
        "humidity":    55.0,
        "flux_ppm":    20.0,   # normal flux vapor level
    },
    "ruang_penyimpanan": {
        "temperature": 25.0,
        "humidity":    50.0,
    },
}

states = {}
def init_device_states(devices):
    for dev in devices:
        dev_id = dev["device_id"]
        location = dev["location"]
        base = BASELINE[location]
        states[dev_id] = {
            "state": "NORMAL", # NORMAL, HEATING, COOLING
            "temperature": base["temperature"],
            "humidity": base["humidity"],
            "accel_x": 0.0,
            "accel_y": 0.0,
            "accel_z": base.get("accel_z", 0.0),
            "vibration_rms": 0.0,
            "flux_ppm": base.get("flux_ppm", 0.0),
            "flux_aqi": 0,
            "voc_level": "GOOD",
            "fan_status": "OFF",
            "state_ticks": 0,
        }

def update_device_sensors(device: dict):
    dev_id = device["device_id"]
    location = device["location"]
    base = BASELINE[location]
    dev_state = states[dev_id]

    dev_state["state_ticks"] += 1

    # Calculate S-curve acceleration factor based on ticks (thermal inertia)
    acceleration = math.tanh(dev_state["state_ticks"] / 5.0)

    # 1. Base day/night oscillation (24 hours cycle for visibility on charts)
    now = datetime.now()
    seconds_today = (
        now.hour * 3600 +
        now.minute * 60 +
        now.second
    )
    DAY_SECONDS = 24 * 60 * 60
    phase_shift = -2 * math.pi / 3 # Peaks at 02:00 PM

    time_osc = 2.0 * math.sin(2 * math.pi * seconds_today / DAY_SECONDS + phase_shift)

    if dev_state["state"] == "NORMAL":
        # Fluctuates naturally around baseline + oscillation
        dev_state["temperature"] = base["temperature"] + time_osc + random.gauss(0, 0.15)
        dev_state["humidity"] = base["humidity"] - (time_osc * 0.5) + random.gauss(0, 0.3)

        if "mq135" in device["sensors"]:
            dev_state["flux_ppm"] = base["flux_ppm"] + random.gauss(0, 0.5)
            dev_state["voc_level"] = "GOOD"

        if "mpu6050" in device["sensors"]:
            dev_state["vibration_rms"] = 0.02 + abs(random.gauss(0, 0.01))

    elif dev_state["state"] == "HEATING":
        # Logarithmic heating curve smoothed by the acceleration factor
        temp_diff = 70.0 - dev_state["temperature"]
        dev_state["temperature"] += temp_diff * 0.08 * acceleration + random.gauss(0, 0.05)

        # Humidity falls as heat rises
        dev_state["humidity"] = max(15.0, dev_state["humidity"] - random.uniform(0.2, 0.5))

        # Hard safety ceiling
        if dev_state["temperature"] > 70.0:
            dev_state["temperature"] = 70.0
    

        if "mq135" in device["sensors"]:
            # gradual gas leak / flux rise
            dev_state["flux_ppm"] += random.uniform(2.5, 4.5)
            if dev_state["flux_ppm"] >= 75.0:
                dev_state["voc_level"] = "HAZARDOUS"
            elif dev_state["flux_ppm"] > 35.0:
                dev_state["voc_level"] = "UNHEALTHY"
            else:
                dev_state["voc_level"] = "MODERATE"
        
        if "mpu6050" in device["sensors"]:
            dev_state["vibration_rms"] = 1.2 + random.uniform(0, 0.2)

    elif dev_state["state"] == "COOLING":
        # Fan is ON, cooling down
        # I the fan gets turned OFF, transition back to NORMAL state
        if dev_state["fan_status"] == "OFF":
            logger.info(f"[SIMULATOR] Fan turned OFF for {dev_id}. Returning to NORMAL.")
            dev_state["state"] = "NORMAL"
            dev_state["state_ticks"] = 0
        else:
            # Active cooling 
            # Cool toward ac active target below the baseline
            cooling_target = base["temperature"] - 5
            temp_diff = dev_state["temperature"] - cooling_target
            dev_state["temperature"] -= temp_diff * 0.12 * acceleration + random.gauss(0, 0.05)
            dev_state["humidity"] = min(base["humidity"], dev_state["humidity"] + random.uniform(0.4, 0.8))

            if "mq135" in device["sensors"]:
                dev_state["flux_ppm"] = max(base["flux_ppm"], dev_state["flux_ppm"] - random.uniform(3.5, 5.5))
                if dev_state["flux_ppm"] <= base["flux_ppm"] + 5:
                    dev_state["voc_level"] = "GOOD"
                elif dev_state["flux_ppm"] > 35.0:
                    dev_state["voc_level"] = "UNHEALTHY"
                else:
                    dev_state["voc_level"] = "MODERATE"

            if "mpu6050" in device["sensors"]:
                dev_state["vibration_rms"] = 0.15 + random.uniform(0, 0.05)
    
    # 3. Round and polish data formats
    dev_state["temperature"] = round(dev_state["temperature"], 2)
    dev_state["humidity"] = round(dev_state["humidity"], 2)

    if "mq135" in device["sensors"]:
        dev_state["flux_ppm"] = round(dev_state["flux_ppm"], 2)
        dev_state["flux_aqi"] = int(dev_state["flux_ppm"] * 1.8)

    if "mpu6050" in device["sensors"]:
        dev_state["accel_x"] = round(random.gauss(0, 0.1), 3)
        dev_state["accel_y"] = round(random.gauss(0, 0.1), 3)
        dev_state["accel_z"] = round(9.81 + random.gauss(0, 0.1) + (random.choice([-1, 1]) * dev_state["vibration_rms"]), 3)
        dev_state["vibration_rms"] = round(dev_state["vibration_rms"], 3)

def build_payload(device: dict) -> dict:
    dev_id = device["device_id"]
    dev_state = states[dev_id]

    payload = {
        "time":         datetime.now(timezone.utc).isoformat(),
        "device_id":    dev_id,
        "location":     device["location"],
        "temperature":  dev_state["temperature"],
        "humidity":     dev_state["humidity"],
        "fan_status":   dev_state["fan_status"], # <--- REPORT THE STATE!
        "accel_x":      dev_state["accel_x"] if "mpu6050" in device["sensors"] else None,
        "accel_y":      dev_state["accel_y"] if "mpu6050" in device["sensors"] else None,
        "accel_z":      dev_state["accel_z"] if "mpu6050" in device["sensors"] else None,
        "vibration_rms":      dev_state["vibration_rms"] if "mpu6050" in device["sensors"] else None,
        "flux_ppm":     dev_state["flux_ppm"] if "mq135" in device["sensors"] else None,
        "flux_aqi":     dev_state["flux_aqi"] if "mq135" in device["sensors"] else None,
        "voc_level":     dev_state["voc_level"] if "mq135" in device["sensors"] else None,
    }
    return payload

def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        logger.info("[MQTT] Connected to broker successfully.")
        # Subscribe to command topics for all devices and locations
        client.subscribe("iot/commands/+/+")
        logger.info("[MQTT] Sent subscription request for iot/commands/+/+")
    else:
        logger.error(f"[MQTT] Connection failed, reason code: {reason_code}")

def on_subscribe(client, userdata, mid, reason_code_list, properties):
    logger.info(f"[MQTT] Subscription acknowledged by broker. mid={mid}, reason_codes={reason_code_list}")

def on_message(client, userdata, msg):
    """
    Handles incoming actuator commands from the cloud.
    Topic format: iot/commands/{device_id}/{location}
    Payload format: {"actuator": "fan", "status": "ON" | "OFF"}
    """
    try:
        logger.debug(f"[MQTT DEBUG] Received message on topic {msg.topic}: {msg.payload.decode('utf-8')}")
        parts = msg.topic.split('/')
        if len(parts) < 4:
            logger.debug(f"[MQTT DEBUG] Topic has less than 4 parts: {msg.topic}")
            return
        
        device_id = parts[2]
        payload = json.loads(msg.payload.decode("utf-8"))

        actuator = payload.get("actuator")
        status = payload.get("status")

        if device_id in states:
            dev_state = states[device_id]
            if actuator == "fan":
                dev_state["fan_status"] = status
                # Trigger state changes based the actuator status
                if status == "ON" and dev_state["state"] != "COOLING":
                    logger.warning(f"[ACTUATOR] Fan ON command received for {device_id}. Transitioning to COOLING.")
                    dev_state["state"] = "COOLING"
                    dev_state["state_ticks"] = 0
                elif status == "OFF" and dev_state["state"] == "COOLING":
                    logger.info(f"[ACTUATOR] Fan OFF command received for {device_id}. Returning to NORMAL.")
                    dev_state["state"] = "NORMAL"
                    dev_state["state_ticks"] = 0
        else:
            logger.debug(f"[ACTUATOR] Command received for unknown device: {device_id}")
    except Exception as e:
        logger.error(f"[ACTUATOR] Error parsing command payload: {e}")
            
def start_input_thread():
    """
    Starts a background daemon thread to monitor terminal inputs for anomaly triggers
    """
    def _loop():
        # Wait a couple of seconds for startup logs to settle before printing instructions
        time.sleep(2.0)
        print("\n====================================================")
        print("INTERACTIVE SIMULATOR READY:")
        print("  Type 'h [device_id]' to manually trigger OVERHEAT anomaly")
        print("  Example: h device_002")
        print("====================================================\n")

        while True:
            try:
                line = input().strip()
                if line.startswith("h "):
                    parts = line.split(" ")
                    if len(parts) >= 2:
                        dev_id = parts[1].strip()
                        if dev_id in states:
                            logger.warning(f"[SIMULATOR] Manual trigger: Forcing {dev_id} to OVERHEAT!")
                            states[dev_id]["state"] = "HEATING"
                            states[dev_id]["state_ticks"] = 0
                            states[dev_id]["fan_status"] = "OFF" # Make sure the fan status is OFF while the device state is HEATING.
                        else:
                            print(f"Unknown device: {dev_id}")
            except (KeyboardInterrupt, EOFError):
                break

    t = threading.Thread(target=_loop, daemon=True)
    t.start()

# ============================================================
# Main loop
# ============================================================
_tick = 0

def run(devices_list, interval_sec: float = 2.0) -> None:
    """
    Main execution loop of the simulator.
    Spawns the background input thread and periodically publishes telemetry.
    """
    global _tick
    import ssl

    broker_host = os.getenv("MQTT_BROKER_HOST", "localhost")
    broker_port = int(os.getenv("MQTT_BROKER_PORT", 1883))

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)

    # Assign callbacks
    client.on_connect = on_connect
    client.on_message = on_message
    client.on_subscribe = on_subscribe

    # Enable TLS if port is 8883
    if broker_port == 8883:
        logger.info("[MQTT] Enabling TLS/SSL connection for port 8883...")
        client.tls_set_context(ssl.create_default_context())

    # Authentication if configured
    mqtt_user = os.getenv("MQTT_USER")
    mqtt_pass = os.getenv("MQTT_PASSWORD")
    if mqtt_user and mqtt_pass:
        client.username_pw_set(mqtt_user, mqtt_pass)

    client.connect(broker_host, broker_port, keepalive=60)
    client.loop_start()

    # Start the keyboard listener thread
    start_input_thread()
    logger.info(f"[SIMULATOR] Active - {len(devices_list)} devices, interval {interval_sec}s")

    try:
        while True:
            _tick += 1
            for device in devices_list:
                dev_id = device["device_id"]

                # 1. Update the state machine physics for this device
                update_device_sensors(device)

                # 2. Build and publish payload
                payload = build_payload(device)
                topic    = f"iot/sensor/{dev_id}/{device['location']}"
                message  = json.dumps(payload)

                client.publish(topic, message, qos=1)

                # 3. Dynamic logging: print state changes immediately, but normal states periodically
                dev_state = states[dev_id]
                if dev_state["state"] != "NORMAL" or _tick % 15 == 0:
                    logger.info(
                        f"[STATE] {dev_id} ({device['location']}) | State: {dev_state['state']} | "
                        f"Temp: {dev_state['temperature']}°C | Fan: {dev_state['fan_status']}"
                        )

                time.sleep(interval_sec / len(devices_list))

    except KeyboardInterrupt:
        logger.info("[SIMULATOR] Simulator stopped by user.")
    finally:
        client.loop_stop()
        client.disconnect()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IoT Device Simulator")
    parser.add_argument(
        "--devices",
        type=int,
        default=3,
        help="Number of simulated devices (default: 3)"
    )

    args = parser.parse_args()

    # generate lists and initialize states
    devices_list = generate_devices(args.devices)
    init_device_states(devices_list)

    run(devices_list, interval_sec=2.0)