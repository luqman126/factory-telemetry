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
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HEALTH_URL = "http://localhost:8000/health"
NUM_REQUESTS = 10
_project_root = Path(os.environ.get("PROJECT_ROOT", "")).resolve()
if not (_project_root / ".git").exists():
    _project_root = Path(__file__).resolve().parents[1]


def get_git_commit():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(_project_root), text=True, stderr=subprocess.DEVNULL
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
        with urllib.request.urlopen(HEALTH_URL) as resp:
            body = json.loads(resp.read().decode())
        elapsed = (time.perf_counter() - start) * 1000  # ms
        times.append(elapsed)
        last_body = body

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
