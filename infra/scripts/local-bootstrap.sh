#!/usr/bin/env bash
# ============================================================
# local-bootstrap.sh
# Jalankan script ini di terminal lokal Anda (laptop) sebelum
# melakukan rebuild environment (terraform destroy & apply).
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TERRAFORM_DIR="${PROJECT_DIR}/infra/terraform"

echo "============================================================"
echo "         IoT Big Data - Local Setup Bootstrap Helper        "
echo "============================================================"

# 1. Pastikan aws-cli dan terraform terinstal secara lokal
if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws-cli tidak terinstal di laptop Anda. Silakan pasang terlebih dahulu." >&2
    exit 1
fi

if ! command -v terraform >/dev/null 2>&1; then
    echo "ERROR: terraform tidak terinstal di laptop Anda. Silakan pasang terlebih dahulu." >&2
    exit 1
fi

# 2. Setup Bastion IP (Gunakan IP Tailscale agar bisa SSH lewat VPN)
echo "-> Menentukan IP Bastion..."
DEFAULT_BASTION_IP="100.127.104.77"
read -p "Masukkan IP Bastion Host [Default: ${DEFAULT_BASTION_IP}]: " BASTION_IP
BASTION_IP="${BASTION_IP:-$DEFAULT_BASTION_IP}"

echo "Bastion IP yang digunakan: ${BASTION_IP}"

# 3. Minta input Kredensial & Secrets
echo ""
echo "--- Pengisian Kredensial Pihak Ketiga ---"
read -p "Masukkan Cloudflare API Token (izin Zone.DNS Edit): " CF_TOKEN
read -p "Masukkan Tailscale Ephemeral/Reusable Auth Key (tskey-auth-...): " TS_KEY

if [ -z "$CF_TOKEN" ] || [ -z "$TS_KEY" ]; then
    echo "ERROR: Kedua token/key tidak boleh kosong." >&2
    exit 1
fi

# 4. Daftarkan Parameter Baru ke AWS SSM Parameter Store
AWS_REGION="ap-southeast-1"
ENV="staging"
PREFIX="/iot-bigdata/${ENV}"

echo ""
echo "-> Mendaftarkan Cloudflare API Token ke AWS SSM..."
aws ssm put-parameter \
  --name "${PREFIX}/CLOUDFLARE_API_TOKEN" \
  --value "$CF_TOKEN" \
  --type "SecureString" \
  --overwrite \
  --region "$AWS_REGION"

echo "-> Mendaftarkan Tailscale Auth Key ke AWS SSM..."
aws ssm put-parameter \
  --name "${PREFIX}/TAILSCALE_AUTH_KEY" \
  --value "$TS_KEY" \
  --type "SecureString" \
  --overwrite \
  --region "$AWS_REGION"

echo "SUCCESS: Kredensial berhasil didaftarkan di SSM Parameter Store."

# 5. Salin script dan database schema dari local ke bastion via SCP
echo ""
echo "-> Menyalin script dan file skema database ke Bastion..."
ssh -o StrictHostKeyChecking=no ec2-user@${BASTION_IP} "mkdir -p /home/ec2-user/iot-bigdata-project/infra/scripts /home/ec2-user/iot-bigdata-project/db"
scp -o StrictHostKeyChecking=no -r "${PROJECT_DIR}/infra/scripts/"* ec2-user@${BASTION_IP}:/home/ec2-user/iot-bigdata-project/infra/scripts/
scp -o StrictHostKeyChecking=no "${PROJECT_DIR}/db/init.sql" ec2-user@${BASTION_IP}:/home/ec2-user/iot-bigdata-project/db/init.sql

# 6. Jalankan Sinkronisasi RPM, script, dan init.sql ke S3 di Bastion secara remote
echo ""
echo "-> Memicu sinkronisasi paket RPM, script, dan init.sql ke S3 Bucket di Bastion..."
# Gunakan SSH Agent forwarding agar bastion bisa scp/ssh jika dibutuhkan
ssh -o StrictHostKeyChecking=no -A ec2-user@${BASTION_IP} "
  chmod +x /home/ec2-user/iot-bigdata-project/infra/scripts/sync-packages-to-s3.sh
  /home/ec2-user/iot-bigdata-project/infra/scripts/sync-packages-to-s3.sh
"

echo ""
echo "============================================================"
echo "    Setup Awal Selesai! Anda siap melakukan rebuild.        "
echo "    Langkah berikutnya:                                     "
echo "      1. terraform destroy                                  "
echo "      2. terraform apply                                    "
echo "============================================================"
