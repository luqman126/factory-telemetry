"""
benchmarks/bench_health.py
Health check benchmark: measure response time and response depth.

Usage:
    python bench_health.py --output results/main_health.json
"""

import argparse
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

HEALTH_URL = "http://localhost:8000/health"
NUM_REQUESTS = 10
_project_root = Path(os.environ.get("PROJECT_ROOT", Path(__file__).parents[1]))


def get_git_commit():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=_project_root, text=True
        ).strip()
    except Exception:
        return "unknown"


def run_benchmark(output_path: str):
    print(f"\n{'='*50}")
    print("HEALTH CHECK BENCHMARK")
    print(f"{'='*50}")

    times = []
    last_body = None

    for i in range(NUM_REQUESTS):
        start = time.perf_counter()
        resp = requests.get(HEALTH_URL)
        elapsed = (time.perf_counter() - start) * 1000  # ms
        times.append(elapsed)
        last_body = resp.json()

    avg_ms = sum(times) / len(times)
    response_fields = list(last_body.keys())

    result = {
        "avg_response_ms": round(avg_ms, 2),
        "response_body": last_body,
        "response_fields": response_fields,
        "has_db_check": "db" in last_body,
        "has_mqtt_check": "mqtt" in last_body,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": get_git_commit(),
    }

    print(f"  Avg response time: {avg_ms:.2f}ms")
    print(f"  Response body: {json.dumps(last_body)}")
    print(f"  Has DB check: {result['has_db_check']}")
    print(f"  Has MQTT check: {result['has_mqtt_check']}")

    if output_path:
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        Path(output_path).write_text(json.dumps(result, indent=2))
        print(f"  Saved to: {output_path}")

    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    run_benchmark(args.output)
