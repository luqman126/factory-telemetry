"""
benchmarks/bench_ingestion.py
Throughput benchmark: publish MQTT messages and measure DB ingestion rate.

Usage:
    python bench_ingestion.py --scale realistic --output results/main_realistic.json
    python bench_ingestion.py --scale stress --output results/improved_stress.json
"""

import argparse
import json
import os
import time
import random
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import paho.mqtt.client as mqtt
import psycopg2
from dotenv import dotenv_values

# Load env from infra/.env
_project_root = Path(os.environ.get("PROJECT_ROOT", Path(__file__).parents[1]))
ENV_PATH = _project_root / "infra" / ".env"
env = dotenv_values(ENV_PATH)

SCALES = {
    "realistic": {"devices": 3, "messages": 100},
    "stress": {"devices": 50, "messages": 2000},
}

TIMEOUT_SEC = 60


def get_git_commit():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=_project_root, text=True
        ).strip()
    except Exception:
        return "unknown"


def build_payload(device_id, location):
    return json.dumps({
        "time": datetime.now(timezone.utc).isoformat(),
        "device_id": device_id,
        "location": location,
        "temperature": round(25 + random.gauss(0, 2), 2),
        "humidity": round(55 + random.gauss(0, 3), 2),
        "accel_x": None, "accel_y": None, "accel_z": None,
        "vibration_rms": None,
        "flux_ppm": None, "flux_aqi": None, "voc_level": None,
    })


def run_benchmark(scale_name: str, output_path: str):
    cfg = SCALES[scale_name]
    num_devices = cfg["devices"]
    num_messages = cfg["messages"]

    print(f"\n{'='*50}")
    print(f"INGESTION BENCHMARK — {scale_name.upper()}")
    print(f"Devices: {num_devices}, Messages: {num_messages}")
    print(f"{'='*50}")

    # Connect to DB
    conn = psycopg2.connect(
        host=env.get("POSTGRES_HOST", "localhost"),
        port=int(env.get("POSTGRES_PORT", 5432)),
        dbname=env.get("POSTGRES_DB"),
        user=env.get("POSTGRES_USER"),
        password=env.get("POSTGRES_PASSWORD"),
    )
    conn.autocommit = True

    # Clean any leftover bench data
    with conn.cursor() as cur:
        cur.execute("DELETE FROM sensor_readings WHERE device_id LIKE 'bench_%'")

    # Connect to MQTT
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    mqtt_user = env.get("MQTT_USER")
    mqtt_pass = env.get("MQTT_PASSWORD")
    if mqtt_user and mqtt_pass:
        client.username_pw_set(mqtt_user, mqtt_pass)
    client.connect(env.get("MQTT_BROKER_HOST", "localhost"),
                   int(env.get("MQTT_BROKER_PORT", 1883)))
    client.loop_start()

    # Publish messages as fast as possible
    benchmark_start = datetime.now(timezone.utc)
    publish_start = time.perf_counter()

    for i in range(num_messages):
        device_id = f"bench_{(i % num_devices) + 1:03d}"
        location = f"bench_room_{(i % num_devices) + 1}"
        topic = f"iot/sensor/{device_id}/{location}"
        payload = build_payload(device_id, location)
        client.publish(topic, payload, qos=1)

    publish_end = time.perf_counter()
    publish_time = publish_end - publish_start
    print(f"Published {num_messages} messages in {publish_time:.3f}s")

    # Poll DB until all messages confirmed or timeout
    print("Waiting for DB confirmation...")
    poll_start = time.perf_counter()
    confirmed = 0

    while (time.perf_counter() - poll_start) < TIMEOUT_SEC:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM sensor_readings "
                "WHERE device_id LIKE 'bench_%%' AND time >= %s",
                (benchmark_start,)
            )
            confirmed = cur.fetchone()[0]
        if confirmed >= num_messages:
            break
        time.sleep(0.5)

    total_time = time.perf_counter() - publish_start
    throughput = confirmed / total_time if total_time > 0 else 0

    # Cleanup
    with conn.cursor() as cur:
        cur.execute("DELETE FROM sensor_readings WHERE device_id LIKE 'bench_%'")
    conn.close()
    client.loop_stop()
    client.disconnect()

    # Results
    result = {
        "scale": scale_name,
        "devices": num_devices,
        "messages_sent": num_messages,
        "messages_confirmed": confirmed,
        "publish_time_sec": round(publish_time, 4),
        "total_time_sec": round(total_time, 4),
        "throughput_msg_per_sec": round(throughput, 2),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": get_git_commit(),
    }

    print(f"\nResults:")
    print(f"  Confirmed: {confirmed}/{num_messages}")
    print(f"  Total time: {total_time:.3f}s")
    print(f"  Throughput: {throughput:.2f} msg/sec")

    # Save
    if output_path:
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        Path(output_path).write_text(json.dumps(result, indent=2))
        print(f"  Saved to: {output_path}")

    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--scale", choices=["realistic", "stress"], required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    run_benchmark(args.scale, args.output)
