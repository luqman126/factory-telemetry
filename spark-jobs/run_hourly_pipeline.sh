#!/bin/bash
# ==============================================================================
# spark-jobs/run_hourly_pipeline.sh
# Orkestrator Pipeline Batch Spark Jam-an
# Alur:
# 1. Masuk ke direktori script ini berada.
# 2. Aktifkan virtual environment python.
# 3. Jalankan export_to_parquet.py untuk export data dari Postgres replica ke S3.
# 4. Tangkap S3 URI hasil upload.
# 5. Jika tidak ada data baru (S3 URI kosong/None), keluar dengan sukses (graceful exit).
# 6. Jika ada data, jalankan spark-submit dengan Spark Local Mode.
# ==============================================================================

set -e

# Masuk ke direktori tempat script ini berada
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [$(date)] Memulai Pipeline Batch Spark per-Jam ==="

# Load environment variables dari file .env di direktori infra (jika ada)
ENV_PATH="$SCRIPT_DIR/../infra/.env"
if [ -f "$ENV_PATH" ]; then
    echo "Loading environment variables dari $ENV_PATH..."
    # load tapi exclude comment
    export $(grep -v '^#' "$ENV_PATH" | xargs)
fi

# Resolve JAVA_HOME jika belum di-set (sangat penting untuk systemd service)
if [ -z "$JAVA_HOME" ]; then
    if command -v java >/dev/null 2>&1; then
        JAVA_PATH=$(readlink -f $(command -v java))
        export JAVA_HOME="${JAVA_PATH%/bin/java}"
        echo "Resolved JAVA_HOME to: $JAVA_HOME"
    else
        echo "WARNING: java command not found" >&2
    fi
fi

# Resolve SPARK_HOME jika belum di-set
if [ -z "$SPARK_HOME" ]; then
    if [ -d "/opt/spark" ]; then
        export SPARK_HOME="/opt/spark"
        echo "Resolved SPARK_HOME to: $SPARK_HOME"
    fi
fi

# Aktifkan virtual environment
if [ -d ".venv" ]; then
    echo "Mengaktifkan virtual environment..."
    source .venv/bin/activate
else
    echo "ERROR: Virtual environment .venv tidak ditemukan di $SCRIPT_DIR!" >&2
    exit 1
fi

# Jalankan export_to_parquet.py dan tangkap output S3 URI
echo "Menjalankan export_to_parquet.py..."
python3.12 export_to_parquet.py

# Read S3 URI from file (deterministic handoff)
URI_FILE="$SCRIPT_DIR/data/last_export_uri.txt"
if [ ! -f "$URI_FILE" ] || [ ! -s "$URI_FILE" ]; then
    echo "=== [$(date)] No new data to analyze. Pipeline exiting cleanly. ==="
    exit 0
fi

S3_URI=$(cat "$URI_FILE")
echo "S3 URI detected: $S3_URI"

# S3 URI is passed to the containerized Spark job
echo "Running batch_analytics.py inside iot-spark container..."

# User infra_iot_net for local dev (compose network), or host network for EC2 VPC access
DOCKER_NET="${DOCKER_NET:-infra_iot_net}"

docker run --rm \
    --name iot_spark \
    --network "$DOCKER_NET" \
    --env-file "$SCRIPT_DIR/../infra/.env" \
    iot-spark:latest \
    spark-submit \
    --master "local[*]" \
    --driver-memory 512m \
    --executor-memory 512m \
    --packages org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.261,org.postgresql:postgresql:42.7.4 \
    batch_analytics.py "$S3_URI" 0

echo "=== [$(date)] Hourly Spark Batch pipeline is complete successfully ==="
