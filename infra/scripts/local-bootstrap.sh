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

# Disable AWS CLI v2 pager globally to prevent terminal blocking on long JSON outputs
export AWS_PAGER=""

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

# 2. Minta input Kredensial & Secrets (Opsional jika sudah ada di SSM)
AWS_REGION="ap-southeast-1"
ENV="staging"
PREFIX="/iot-bigdata/${ENV}"

# Cek apakah parameter sudah ada di SSM Parameter Store
CF_EXISTS=0
TS_EXISTS=0
CF_TUNNEL_EXISTS=0

aws ssm get-parameter --name "${PREFIX}/CLOUDFLARE_API_TOKEN" --region "$AWS_REGION" &>/dev/null && CF_EXISTS=1 || true
aws ssm get-parameter --name "${PREFIX}/TAILSCALE_AUTH_KEY" --region "$AWS_REGION" &>/dev/null && TS_EXISTS=1 || true
aws ssm get-parameter --name "${PREFIX}/CLOUDFLARE_TUNNEL_TOKEN" --region "$AWS_REGION" &>/dev/null && CF_TUNNEL_EXISTS=1 || true

echo ""
echo "--- Pengisian Kredensial Pihak Ketiga (Tekan Enter untuk skip jika sudah ada di SSM) ---"

prompt_cf="Masukkan Cloudflare API Token"
[ $CF_EXISTS -eq 1 ] && prompt_cf="$prompt_cf [Sudah ada di SSM, Enter untuk skip]"
read -p "$prompt_cf: " CF_TOKEN

prompt_ts="Masukkan Tailscale Auth Key (tskey-auth-...)"
[ $TS_EXISTS -eq 1 ] && prompt_ts="$prompt_ts [Sudah ada di SSM, Enter untuk skip]"
read -p "$prompt_ts: " TS_KEY

prompt_tunnel="Masukkan Cloudflare Tunnel Token (opsional)"
[ $CF_TUNNEL_EXISTS -eq 1 ] && prompt_tunnel="$prompt_tunnel [Sudah ada di SSM, Enter untuk skip]"
read -p "$prompt_tunnel: " CF_TUNNEL_TOKEN

# 3. Daftarkan Parameter Baru ke AWS SSM jika diisi
if [ -n "$CF_TOKEN" ]; then
    echo "-> Mendaftarkan Cloudflare API Token ke AWS SSM..."
    aws ssm put-parameter \
      --name "${PREFIX}/CLOUDFLARE_API_TOKEN" \
      --value "$CF_TOKEN" \
      --type "SecureString" \
      --overwrite \
      --region "$AWS_REGION"
elif [ $CF_EXISTS -eq 0 ]; then
    echo "ERROR: Cloudflare API Token tidak boleh kosong karena belum ada di SSM." >&2
    exit 1
else
    echo "-> Menggunakan Cloudflare API Token yang sudah ada di SSM."
fi

if [ -n "$TS_KEY" ]; then
    echo "-> Mendaftarkan Tailscale Auth Key ke AWS SSM..."
    aws ssm put-parameter \
      --name "${PREFIX}/TAILSCALE_AUTH_KEY" \
      --value "$TS_KEY" \
      --type "SecureString" \
      --overwrite \
      --region "$AWS_REGION"
elif [ $TS_EXISTS -eq 0 ]; then
    echo "ERROR: Tailscale Auth Key tidak boleh kosong karena belum ada di SSM." >&2
    exit 1
else
    echo "-> Menggunakan Tailscale Auth Key yang sudah ada di SSM."
fi

if [ -n "$CF_TUNNEL_TOKEN" ]; then
    echo "-> Mendaftarkan Cloudflare Tunnel Token ke AWS SSM..."
    aws ssm put-parameter \
      --name "${PREFIX}/CLOUDFLARE_TUNNEL_TOKEN" \
      --value "$CF_TUNNEL_TOKEN" \
      --type "SecureString" \
      --overwrite \
      --region "$AWS_REGION"

    # Simpan Cloudflare Tunnel Token ke .env lokal
    if [ -f "$ENV_FILE" ]; then
        if ! grep -q "^CLOUDFLARE_TUNNEL_TOKEN=" "$ENV_FILE"; then
            echo "CLOUDFLARE_TUNNEL_TOKEN=\"${CF_TUNNEL_TOKEN}\"" >> "$ENV_FILE"
        else
            sed -i "s/^CLOUDFLARE_TUNNEL_TOKEN=.*/CLOUDFLARE_TUNNEL_TOKEN=\"${CF_TUNNEL_TOKEN}\"/g" "$ENV_FILE"
        fi
    else
        mkdir -p "$(dirname "$ENV_FILE")"
        echo "CLOUDFLARE_TUNNEL_TOKEN=\"${CF_TUNNEL_TOKEN}\"" > "$ENV_FILE"
    fi
elif [ $CF_TUNNEL_EXISTS -eq 1 ]; then
    echo "-> Menggunakan Cloudflare Tunnel Token yang sudah ada di SSM."
fi

echo "SUCCESS: Kredensial siap digunakan."

# 4. Ambil output infrastruktur dari Terraform
echo ""
echo "-> Membaca output Terraform..."
if [ ! -f "${TERRAFORM_DIR}/terraform.tfstate" ]; then
    echo "WARNING: terraform.tfstate tidak ditemukan. Pastikan Anda sudah menjalankan terraform apply." >&2
    exit 1
fi

S3_BUCKET=$(terraform -chdir="${TERRAFORM_DIR}" output -raw s3_bucket)
BASTION_INSTANCE_ID=$(terraform -chdir="${TERRAFORM_DIR}" output -raw applayer_instance_id)

if [ -z "$S3_BUCKET" ] || [ -z "$BASTION_INSTANCE_ID" ] || [ "$S3_BUCKET" = "No outputs found" ]; then
    echo "ERROR: Gagal membaca output dari Terraform. Pastikan resources sudah di-apply." >&2
    exit 1
fi

echo "S3 Bucket: ${S3_BUCKET}"
echo "Bastion Instance ID: ${BASTION_INSTANCE_ID}"

# 5. Salin script dan database schema dari local langsung ke S3
echo ""
echo "-> Menyalin script dan file skema database ke S3..."
aws s3 cp "${PROJECT_DIR}/infra/scripts/" "s3://${S3_BUCKET}/scripts/" --recursive --region "$AWS_REGION"
aws s3 cp "${PROJECT_DIR}/db/init.sql" "s3://${S3_BUCKET}/scripts/init.sql" --region "$AWS_REGION"

# 6. Jalankan Sinkronisasi RPM, script, dan init.sql di Bastion secara remote via AWS SSM Run Command
echo ""
echo "-> Memicu sinkronisasi paket RPM dan secrets di Bastion via AWS SSM..."
COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$BASTION_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "{\"commands\":[
    \"mkdir -p /home/ec2-user/iot-bigdata-project/infra/scripts /home/ec2-user/iot-bigdata-project/db\",
    \"aws s3 cp s3://${S3_BUCKET}/scripts/ /home/ec2-user/iot-bigdata-project/infra/scripts/ --recursive --region ${AWS_REGION}\",
    \"aws s3 cp s3://${S3_BUCKET}/scripts/init.sql /home/ec2-user/iot-bigdata-project/db/init.sql --region ${AWS_REGION}\",
    \"chmod +x /home/ec2-user/iot-bigdata-project/infra/scripts/*.sh\",
    \"chown -R ec2-user:ec2-user /home/ec2-user/iot-bigdata-project\",
    \"sudo -i -u ec2-user /home/ec2-user/iot-bigdata-project/infra/scripts/sync-packages-to-s3.sh\"
  ]}" \
  --region "$AWS_REGION" \
  --query "Command.CommandId" \
  --output text)

echo "SSM Command sent dengan ID: $COMMAND_ID"
echo "Menunggu command selesai..."
aws ssm wait command-executed --command-id "$COMMAND_ID" --instance-id "$BASTION_INSTANCE_ID" --region "$AWS_REGION" || true

# Ambil hasil output log secara bersih (raw text)
STATUS=$(aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$BASTION_INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query "Status" \
  --output text)

echo "Status Eksekusi: $STATUS"

echo ""
echo "--- Log Output Bastion ---"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$BASTION_INSTANCE_ID" \
  --region "$AWS_REGION" \
  --query "StandardOutputContent" \
  --output text

if [ "$STATUS" != "Success" ]; then
    echo ""
    echo "--- Log Error Bastion ---"
    aws ssm get-command-invocation \
      --command-id "$COMMAND_ID" \
      --instance-id "$BASTION_INSTANCE_ID" \
      --region "$AWS_REGION" \
      --query "StandardErrorContent" \
      --output text
fi

echo ""
echo "============================================================"
echo "    Setup Awal Selesai! Seluruh environment telah pulih.    "
echo "============================================================"
