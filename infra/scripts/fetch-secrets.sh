#!/usr/bin/env bash
# ============================================================
# fetch-secrets.sh
# Fetch environment secrets from AWS SSM Parameter Store
# OS: Amazon Linux 2023 / Ubuntu
# Dependencies: aws-cli, python3
#
# Usage: ./fetch-secrets.sh <environment>
# ============================================================
set -euo pipefail

ENV="${1:-staging}"
PROJECT_NAME="${2:-iot-bigdata}"
PREFIX="/${PROJECT_NAME}/${ENV}/"
OUTPUT_FILE="$(dirname "$0")/../.env"

echo "=== Fetching Secrets from AWS SSM Parameter Store ==="
echo "Path prefix: ${PREFIX}"

# 1. Pastikan aws cli terinstal
if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws-cli is not installed." >&2
    exit 1
fi

# 2. Ambil parameter store secara rekursif dan parse ke format KEY="VALUE" menggunakan Python
aws ssm get-parameters-by-path \
  --path "${PREFIX}" \
  --recursive \
  --with-decryption \
  --region ${AWS_REGION:-ap-southeast-1} \
  --query "Parameters[*]" \
  --output json | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    if not data:
        print("WARNING: No parameters found in SSM path.", file=sys.stderr)
        sys.exit(0)
    for param in data:
        name = param["Name"]
        val = param["Value"]
        # Ambil bagian terakhir setelah slash (contoh: /iot-bigdata/staging/POSTGRES_DB -> POSTGRES_DB)
        key = name.split("/")[-1]
        # Escape quotes jika ada di dalam value
        val_escaped = val.replace("\"", "\\\"")
        print(f"{key}={val_escaped}")
except Exception as e:
    print(f"Error parsing SSM json: {e}", file=sys.stderr)
    sys.exit(1)
' > "${OUTPUT_FILE}"

# 3. Validasi apakah file .env berhasil terbuat dan tidak kosong
if [ -s "${OUTPUT_FILE}" ]; then
    echo "SUCCESS: Secrets written to ${OUTPUT_FILE}"
else
    echo "WARNING: Created .env file is empty or SSM parameters were not found." >&2
fi
