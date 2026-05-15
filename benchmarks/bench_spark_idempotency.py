"""
benchmarks/bench_spark_idempotency.py
Spark idempotency proof: run batch_analytics twice, verify no duplicates.

Usage:
    python bench_spark_idempotency.py --output results/improved_spark.json
"""

import argparse
import json
import os
import random
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

import pandas as pd
import psycopg2
from dotenv import dotenv_values

ENV_PATH = Path(__file__).parents[1] / "infra" / ".env"
if not ENV_PATH.exists():
    # Running from temp dir during benchmark
    ENV_PATH = Path(os.environ.get("PROJECT_ROOT", Path(__file__).parents[1])) / "infra" / ".env"
env = dotenv_values(ENV_PATH)

PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", Path(__file__).parents[1]))
PARQUET_PATH = Path(__file__).parent / "results" / "test_data.parquet"
NUM_TEST_ROWS = 100


def get_git_commit():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=PROJECT_ROOT, text=True
        ).strip()
    except Exception:
        return "unknown"


def get_branch():
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=PROJECT_ROOT, text=True
        ).strip()
    except Exception:
        return "unknown"


def get_conn():
    return psycopg2.connect(
        host=env.get("POSTGRES_HOST", "localhost"),
        port=int(env.get("POSTGRES_PORT", 5432)),
        dbname=env.get("POSTGRES_DB"),
        user=env.get("POSTGRES_USER"),
        password=env.get("POSTGRES_PASSWORD"),
    )


def insert_test_data(conn):
    """Insert test sensor rows into DB."""
    base_time = datetime.now(timezone.utc) - timedelta(hours=1)
    with conn.cursor() as cur:
        for i in range(NUM_TEST_ROWS):
            t = base_time + timedelta(seconds=i * 2)
            device_id = f"bench_spark_{(i % 3) + 1:03d}"
            temp = round(30 + random.gauss(0, 5), 2)
            cur.execute(
                """INSERT INTO sensor_readings
                   (time, device_id, location, temperature, humidity)
                   VALUES (%s, %s, %s, %s, %s)""",
                (t, device_id, "bench_room", temp, round(55 + random.gauss(0, 3), 2))
            )
    conn.commit()


def export_test_parquet(conn):
    """Export test data to local parquet."""
    df = pd.read_sql(
        "SELECT * FROM sensor_readings WHERE device_id LIKE 'bench_spark_%%'",
        conn
    )
    # Spark-compatible timestamps
    df["time"] = pd.to_datetime(df["time"]).dt.tz_localize(None).astype("datetime64[us]")
    PARQUET_PATH.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(PARQUET_PATH, index=False, engine="pyarrow")
    return len(df)


def run_spark_job():
    """Run batch_analytics.py and capture output."""
    spark_script = PROJECT_ROOT / "spark-jobs" / "batch_analytics.py"
    spark_env = os.environ.copy()
    spark_env["SPARK_MASTER_URL"] = "local[*]"
    # Source the .env vars
    for k, v in env.items():
        if v:
            spark_env[k] = v

    result = subprocess.run(
        [sys.executable, str(spark_script), str(PARQUET_PATH), "0"],
        capture_output=True, text=True, env=spark_env,
        cwd=str(PROJECT_ROOT / "spark-jobs")
    )
    return result.stdout + result.stderr


def query_results(conn):
    """Get analytics and anomaly counts + values for bench data."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT count(*) FROM analytics_results WHERE device_id LIKE 'bench_spark_%%'"
        )
        analytics_count = cur.fetchone()[0]

        cur.execute(
            "SELECT device_id, metric_name, metric_value FROM analytics_results "
            "WHERE device_id LIKE 'bench_spark_%%' ORDER BY device_id, metric_name"
        )
        analytics_values = cur.fetchall()

        cur.execute(
            "SELECT count(*) FROM anomaly_events WHERE device_id LIKE 'bench_spark_%%'"
        )
        anomaly_count = cur.fetchone()[0]

    return analytics_count, analytics_values, anomaly_count


def cleanup(conn):
    """Remove all bench test data."""
    with conn.cursor() as cur:
        cur.execute("DELETE FROM sensor_readings WHERE device_id LIKE 'bench_spark_%%'")
        cur.execute("DELETE FROM analytics_results WHERE device_id LIKE 'bench_spark_%%'")
        cur.execute("DELETE FROM anomaly_events WHERE device_id LIKE 'bench_spark_%%'")
    conn.commit()
    if PARQUET_PATH.exists():
        PARQUET_PATH.unlink()


def run_benchmark(output_path: str):
    branch = get_branch()

    print(f"\n{'='*50}")
    print(f"SPARK IDEMPOTENCY TEST — branch: {branch}")
    print(f"{'='*50}")

    conn = get_conn()
    conn.autocommit = True

    # Cleanup any leftover
    cleanup(conn)

    # Insert test data and export parquet
    conn.autocommit = False
    insert_test_data(conn)
    conn.autocommit = True
    rows_exported = export_test_parquet(conn)
    print(f"  Test data: {rows_exported} rows exported to parquet")

    # Run 1
    print("  Running Spark job (run 1)...")
    log1 = run_spark_job()
    r1_analytics, r1_values, r1_anomaly = query_results(conn)
    print(f"  Run 1: analytics={r1_analytics}, anomalies={r1_anomaly}")

    # Run 2
    print("  Running Spark job (run 2)...")
    log2 = run_spark_job()
    r2_analytics, r2_values, r2_anomaly = query_results(conn)
    print(f"  Run 2: analytics={r2_analytics}, anomalies={r2_anomaly}")

    # Compare
    duplicates_found = (r2_analytics > r1_analytics) or (r2_anomaly > r1_anomaly)
    values_match = (r1_values == r2_values)
    log_shows_delete = "DELETE" in log2 or "delete" in log2.lower()

    if not duplicates_found and values_match:
        print(f"\n  ✓ IDEMPOTENT — no duplicates, values identical")
    else:
        print(f"\n  ✗ NOT IDEMPOTENT — duplicates detected")
        print(f"    Analytics: {r1_analytics} → {r2_analytics}")
        print(f"    Anomalies: {r1_anomaly} → {r2_anomaly}")

    if log_shows_delete:
        print(f"  ✓ Log evidence: DELETE-before-INSERT confirmed")
    else:
        print(f"  ✗ No DELETE evidence in logs")

    # Cleanup
    cleanup(conn)
    conn.close()

    result = {
        "branch": branch,
        "test_rows": NUM_TEST_ROWS,
        "run1_analytics_count": r1_analytics,
        "run2_analytics_count": r2_analytics,
        "run1_anomaly_count": r1_anomaly,
        "run2_anomaly_count": r2_anomaly,
        "duplicates_found": duplicates_found,
        "values_match": values_match,
        "log_shows_delete": log_shows_delete,
        "idempotent": not duplicates_found and values_match,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": get_git_commit(),
    }

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
