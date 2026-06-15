#!/usr/bin/env bash
# ============================================================
# sync-packages-to-s3.sh
# Download required database and monitoring RPMs on the bastion,
# and upload them to the S3 bucket packages prefix.
# OS: Amazon Linux 2023
# Run on: applayer-1 (bastion)
# ============================================================
set -euo pipefail

PROJECT_DIR="/home/ec2-user/iot-bigdata-project"
ENV_PATH="${PROJECT_DIR}/infra/.env"

# 1. Fetch S3 bucket name
if [ -f "$ENV_PATH" ]; then
    S3_BUCKET=$(grep -E "^S3_BUCKET=" "$ENV_PATH" | cut -d= -f2 | tr -d '"'\')
else
    echo "WARNING: Env file not found at ${ENV_PATH}. Falling back to SSM..."
    S3_BUCKET=$(aws ssm get-parameter --name "/iot-bigdata/staging/S3_BUCKET" --region ap-southeast-1 --query "Parameter.Value" --output text)
fi

echo "Target S3 Bucket: ${S3_BUCKET}"

# 2. Add TimescaleDB Repository
if [ ! -f /etc/yum.repos.d/timescaledb.repo ]; then
    echo "-> Adding TimescaleDB repository..."
    sudo tee /etc/yum.repos.d/timescaledb.repo <<'EOF'
[timescale_timescaledb]
name=timescale_timescaledb
baseurl=https://packagecloud.io/timescale/timescaledb/el/9/$basearch
repo_gpgcheck=1
gpgcheck=0
enabled=1
gpgkey=https://packagecloud.io/timescale/timescaledb/gpgkey
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
fi

# 3. Add Grafana Repository
if [ ! -f /etc/yum.repos.d/grafana.repo ]; then
    echo "-> Adding Grafana repository..."
    sudo tee /etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
fi

# 4. Prepare local folder
DOWNLOAD_DIR="/home/ec2-user/rpm-packages"
mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"
rm -f *.rpm

# 5. Download Packages (timescaledb-2-postgresql-16, timescaledb-2-loader-postgresql-16, timescaledb-tools, and alloy)
echo "-> Downloading TimescaleDB RPMs (x86_64)..."
sudo dnf download --arch=x86_64 timescaledb-2-postgresql-16 timescaledb-2-loader-postgresql-16 timescaledb-tools -y

echo "-> Downloading Grafana Alloy RPM (x86_64)..."
sudo dnf download --arch=x86_64 alloy -y

# 6. Upload packages to S3 bucket
echo "-> Syncing RPM packages to s3://${S3_BUCKET}/packages/ ..."
aws s3 cp "$DOWNLOAD_DIR/" "s3://${S3_BUCKET}/packages/" --recursive --exclude "*" --include "*.rpm"

# 7. Upload provisioning scripts and schema to S3 bucket
echo "-> Syncing provisioning scripts and init.sql to s3://${S3_BUCKET}/scripts/ ..."
aws s3 cp "${PROJECT_DIR}/infra/scripts/" "s3://${S3_BUCKET}/scripts/" --recursive
aws s3 cp "${PROJECT_DIR}/db/init.sql" "s3://${S3_BUCKET}/scripts/init.sql"

# 8. Fetch database secrets from SSM and upload to S3 for private database nodes
echo "-> Fetching DB credentials from SSM for private nodes..."
DB_NAME=$(aws ssm get-parameter --name "/iot-bigdata/staging/POSTGRES_DB" --region ap-southeast-1 --query "Parameter.Value" --output text || echo "")
DB_USER=$(aws ssm get-parameter --name "/iot-bigdata/staging/POSTGRES_USER" --region ap-southeast-1 --query "Parameter.Value" --output text || echo "")
DB_PASSWORD=$(aws ssm get-parameter --name "/iot-bigdata/staging/POSTGRES_PASSWORD" --with-decryption --region ap-southeast-1 --query "Parameter.Value" --output text || echo "")

if [ ! -z "$DB_PASSWORD" ]; then
    echo "-> Creating temporary db-secrets.env file..."
    TEMP_DB_ENV=$(mktemp)
    cat <<EOF > "$TEMP_DB_ENV"
POSTGRES_DB="$DB_NAME"
POSTGRES_USER="$DB_USER"
POSTGRES_PASSWORD="$DB_PASSWORD"
EOF
    chmod 600 "$TEMP_DB_ENV"

    echo "-> Syncing DB credentials to s3://${S3_BUCKET}/secrets/db-secrets.env ..."
    aws s3 cp "$TEMP_DB_ENV" "s3://${S3_BUCKET}/secrets/db-secrets.env"
    rm -f "$TEMP_DB_ENV"
else
    echo "WARNING: Failed to fetch database credentials from SSM. S3 database configuration step skipped."
fi

echo "=== Package & Script Sync to S3 Completed successfully ==="
