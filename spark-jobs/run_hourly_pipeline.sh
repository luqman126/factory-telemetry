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
EXPORT_OUTPUT=$(python3.12 export_to_parquet.py)
echo "$EXPORT_OUTPUT"

# Ekstrak S3 URI menggunakan grep dan cut
S3_URI=$(echo "$EXPORT_OUTPUT" | grep "S3 URI: " | cut -d' ' -f3 || true)

if [ -z "$S3_URI" ] || [ "$S3_URI" = "None" ]; then
    echo "=== [$(date)] Tidak ada data baru untuk dianalisis. Pipeline selesai dengan sukses (graceful exit). ==="
    exit 0
fi

echo "S3 URI yang terdeteksi: $S3_URI"

# Cari spark-submit binary
SPARK_SUBMIT="spark-submit"
if [ -x "/opt/spark/bin/spark-submit" ]; then
    SPARK_SUBMIT="/opt/spark/bin/spark-submit"
elif [ -n "$SPARK_HOME" ] && [ -x "$SPARK_HOME/bin/spark-submit" ]; then
    SPARK_SUBMIT="$SPARK_HOME/bin/spark-submit"
fi

echo "Menggunakan binary spark-submit: $SPARK_SUBMIT"

# Jalankan spark-submit menggunakan local[*] mode dengan batasan memori
echo "Memicu spark-submit untuk batch_analytics.py..."
$SPARK_SUBMIT \
  --master "local[*]" \
  --executor-memory 512m \
  --driver-memory 512m \
  --packages org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.261,org.postgresql:postgresql:42.7.4 \
  batch_analytics.py "$S3_URI" 0

echo "=== [$(date)] Pipeline Batch Spark Jam-an Selesai dengan Sukses ==="
