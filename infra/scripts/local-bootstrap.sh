#!/usr/bin/env bash
# ============================================================
# local-bootstrap.sh
# Jalankan script ini di terminal lokal Anda (laptop) sebelum
# melakukan rebuild environment (terraform destroy & apply).
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TERRAFORM_DIR="${PROJECT_DIR}/infra/terraform"
ENV_FILE="${PROJECT_DIR}/infra/.env"

if [ -f "$ENV_FILE" ]; then
    # Load variables jika file .env lokal ada
    set -a
    source "$ENV_FILE"
    set +a
fi

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

# 1.5 Cek ssh-agent (Wajib untuk Agent Forwarding)
if ! ssh-add -l >/dev/null 2>&1; then
    echo "WARNING: ssh-agent belum aktif atau belum mendeteksi adanya SSH key."
    echo "Script membutuhkan SSH Agent Forwarding (-A) agar Bastion bisa mengakses node privat."
    echo "Silakan jalankan perintah ini terlebih dahulu jika koneksi gagal:"
    echo "  eval \$(ssh-agent) && ssh-add ~/.ssh/iot-bigdata-key.pem"
    echo ""
    read -p "Apakah Anda ingin tetap mencoba melanjutkan? (y/n) [y]: " CONTINUE_SSH
    CONTINUE_SSH="${CONTINUE_SSH:-y}"
    if [ "$CONTINUE_SSH" != "y" ]; then
        exit 1
    fi
fi

# 2. Setup Bastion IP (Gunakan IP Tailscale agar bisa SSH lewat VPN)
echo "-> Menentukan IP Bastion..."
# Gunakan BASTION_TAILSCALE_IP dari .env jika ada
if [ ! -z "${BASTION_TAILSCALE_IP:-}" ]; then
    read -p "Masukkan IP Bastion Host [Default: ${BASTION_TAILSCALE_IP}]: " INPUT_IP
    BASTION_IP="${INPUT_IP:-$BASTION_TAILSCALE_IP}"
else
    # Jika tidak ada di .env lokal, minta input manual
    read -p "Masukkan IP Bastion Host (IP Tailscale Anda): " BASTION_IP
    if [ -z "$BASTION_IP" ]; then
        echo "ERROR: IP Bastion wajib diisi." >&2
        exit 1
    fi
fi

echo "Bastion IP yang digunakan: ${BASTION_IP}"

# Simpan Bastion IP ke .env (ditolak dari Git/gitignore) agar awet dan ISO 27001 compliant
if [ -f "$ENV_FILE" ]; then
    if ! grep -q "^BASTION_TAILSCALE_IP=" "$ENV_FILE"; then
        echo "BASTION_TAILSCALE_IP=\"${BASTION_IP}\"" >> "$ENV_FILE"
    else
        sed -i "s/^BASTION_TAILSCALE_IP=.*/BASTION_TAILSCALE_IP=\"${BASTION_IP}\"/g" "$ENV_FILE"
    fi
else
    mkdir -p "$(dirname "$ENV_FILE")"
    echo "BASTION_TAILSCALE_IP=\"${BASTION_IP}\"" > "$ENV_FILE"
fi

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
