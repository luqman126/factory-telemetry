#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [$(date)] Starting Hourly Spark Batch Pipeline ==="

# User infra_iot_net for local dev, or host/bridge for EC2 VPC access
DOCKER_NET="${DOCKER_NET:-infra_iot_net}"

# 1. Run export_to_parquet.py inside the container with volume mount
echo "Running export_to_parquet.py..."
docker run --rm \
    --name iot_spark \
    --network "$DOCKER_NET" \
    -v "$SCRIPT_DIR/data:/spark-jobs/data" \
    --env-file "$SCRIPT_DIR/../infra/.env" \
    iot-spark:latest \
    python3.12 export_to_parquet.py

# 2. Read S3 URI from file (deterministic handoff)
URI_FILE="$SCRIPT_DIR/data/last_export_uri.txt"
if [ ! -f "$URI_FILE" ] || [ ! -s "$URI_FILE" ]; then
    echo "=== [$(date)] No new data to analyze. Pipeline exiting cleanly. ==="
    exit 0
fi

S3_URI=$(cat "$URI_FILE")
echo "S3 URI detected: $S3_URI"

# 3. Run Spark batch analytics inside container
echo "Running batch_analytics.py..."
docker run --rm \
    --name iot_spark \
    --network "$DOCKER_NET" \
    --env-file "$SCRIPT_DIR/../infra/.env" \
    iot-spark:latest \
    spark-submit \
    --master "local[*]" \
    --driver-memory 512m \
    --executor-memory 512m \
    batch_analytics.py "$S3_URI" 0

echo "=== [$(date)] Hourly Spark Batch pipeline is complete successfully ==="
