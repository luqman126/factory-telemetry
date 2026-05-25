#!/usr/bin/env python3
# ============================================================
# spark-jobs/generate_bulk_data.py
# Generate large synthetic dataset for Spark benchmarking
#
# Usage:
#   python generate_bulk_data.py [--records 1000000] [--devices 20] [--days 30] [--upload]
#
# Output: Parquet file di data/parquet/ dan opsional upload ke S3
# ============================================================

import argparse
import logging
import os
from pathlib import Path
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from dotenv import load_dotenv

_ENV_PATH = Path(__file__).parents[1] / "infra" / ".env"
load_dotenv(dotenv_path=_ENV_PATH)

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
logger = logging.getLogger(__name__)

# Device pool
DEVICES = [
    {"device_id": f"device_{i:03d}", "location": loc}
    for i, loc in enumerate([
        "soldering_area_1", "soldering_area_2", "qc_area",
        "storage_room_1", "storage_room_2", "production_line_1",
        "production_line_2", "assembly_area", "testing_lab", "warehouse",
        "soldering_area_3", "production_line_3", "qc_area_2",
        "storage_room_3", "assembly_area_2", "testing_lab_2",
        "warehouse_2", "production_line_4", "soldering_area_4", "qc_area_3",
    ], start=1)
]


def generate_chunk(num_records: int, num_devices: int, num_days: int,
                   device_offset: int = 0, time_seed_offset: int = 0) -> pd.DataFrame:
    """Generate a chunk of synthetic sensor data."""
    devices = DEVICES[:num_devices]
    records_per_device = num_records // num_devices
    remainder = num_records % num_devices

    all_data = []
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(days=num_days)

    for i, device in enumerate(devices):
        n = records_per_device + (1 if i < remainder else 0)
        if n == 0:
            continue

        timestamps = pd.to_datetime(
            np.sort(np.random.uniform(start_time.timestamp(), end_time.timestamp(), n)),
            unit='s'
        )

        base_temp = np.random.uniform(25, 35)
        base_humidity = np.random.uniform(50, 70)

        data = {
            "time": timestamps,
            "device_id": device["device_id"],
            "location": device["location"],
            "temperature": np.random.normal(base_temp, 3, n).clip(15, 55),
            "humidity": np.random.normal(base_humidity, 8, n).clip(20, 95),
            "accel_x": np.random.normal(0, 0.5, n),
            "accel_y": np.random.normal(0, 0.5, n),
            "accel_z": np.random.normal(9.8, 0.5, n),
            "vibration_rms": np.abs(np.random.exponential(1.0, n)),
            "flux_ppm": np.abs(np.random.exponential(15, n)),
            "flux_aqi": np.random.randint(0, 200, n),
            "voc_level": np.random.choice(
                ["GOOD", "MODERATE", "UNHEALTHY", "HAZARDOUS"],
                n, p=[0.6, 0.25, 0.12, 0.03]
            ),
        }

        anomaly_mask = np.random.random(n) < 0.02
        data["temperature"][anomaly_mask] = np.random.uniform(40, 55, anomaly_mask.sum())
        data["vibration_rms"][anomaly_mask] = np.random.uniform(3, 8, anomaly_mask.sum())

        all_data.append(pd.DataFrame(data))

    df = pd.concat(all_data, ignore_index=True)
    df = df.sort_values("time").reset_index(drop=True)
    df["time"] = df["time"].dt.tz_localize(None).astype("datetime64[us]")
    df["flux_aqi"] = df["flux_aqi"].astype("int32")
    return df


def generate(num_records: int, num_devices: int, num_days: int,
             output_path: Path, chunk_size: int = 500_000) -> Path:
    """Generate large dataset incrementally to avoid OOM."""
    logger.info(f"Generating {num_records} records in chunks of {chunk_size}, "
                f"{num_devices} devices, {num_days} days")

    output_path.parent.mkdir(parents=True, exist_ok=True)

    writer = None
    total_written = 0
    chunk_num = 0

    while total_written < num_records:
        chunk_num += 1
        records_this_chunk = min(chunk_size, num_records - total_written)

        logger.info(f"Chunk {chunk_num}: generating {records_this_chunk} records")
        chunk_df = generate_chunk(records_this_chunk, num_devices, num_days)

        table = pa.Table.from_pandas(chunk_df, preserve_index=False)
        if writer is None:
            writer = pq.ParquetWriter(output_path, table.schema)
        writer.write_table(table)

        total_written += len(chunk_df)
        logger.info(f"Progress: {total_written}/{num_records} ({total_written*100/num_records:.1f}%)")

        # Free memory
        del chunk_df
        del table

    if writer:
        writer.close()

    size_mb = output_path.stat().st_size / 1024 / 1024
    logger.info(f"Total: {total_written} records, file size: {size_mb:.1f} MB")
    return output_path


def upload_to_s3(local_path: Path) -> str:
    """Upload to S3 and return URI."""
    import boto3
    bucket = os.getenv("S3_BUCKET", "iot-bigdata-datalake-kagebyo")
    s3_key = f"benchmark/{local_path.name}"
    s3 = boto3.client("s3", region_name="ap-southeast-1")
    s3.upload_file(str(local_path), bucket, s3_key)
    uri = f"s3://{bucket}/{s3_key}"
    logger.info(f"Uploaded: {uri}")
    return uri


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate bulk sensor data for benchmarking")
    parser.add_argument("--records", type=int, default=1_000_000, help="Total records (default: 1M)")
    parser.add_argument("--devices", type=int, default=20, help="Number of devices (default: 20)")
    parser.add_argument("--days", type=int, default=30, help="Time span in days (default: 30)")
    parser.add_argument("--chunk-size", type=int, default=500_000, help="Chunk size for incremental generation (default: 500K)")
    parser.add_argument("--upload", action="store_true", help="Upload to S3 after generation")
    args = parser.parse_args()

    output_dir = Path(__file__).parent / "data" / "parquet"
    output_dir.mkdir(parents=True, exist_ok=True)
    filename = f"benchmark_{args.records}records_{datetime.now().strftime('%Y%m%d_%H%M%S')}.parquet"
    path = output_dir / filename

    generate(args.records, args.devices, args.days, path, chunk_size=args.chunk_size)

    if args.upload:
        uri = upload_to_s3(path)
        print(f"\nS3 URI: {uri}")
        path.unlink()
        logger.info("Local file removed after upload")
    else:
        print(f"\nLocal file: {path}")
        print("To upload: python generate_bulk_data.py --upload")
