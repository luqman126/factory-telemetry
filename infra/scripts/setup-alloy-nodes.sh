#!/usr/bin/env bash
# ============================================================
# setup-alloy-nodes.sh
# Orchestrate installation & configuration of Grafana Alloy
# across applayer-1, datalayer-1, and datalayer-2.
# OS: Amazon Linux 2023
# Dependencies: aws-cli, python3, ssh, scp
#
# Run on: applayer-1
# ============================================================
set -euo pipefail

# 1. Paths & Directories
PROJECT_DIR="/home/ec2-user/iot-bigdata-project"
ENV_PATH="${PROJECT_DIR}/infra/.env"
TEMPLATE_PATH="${PROJECT_DIR}/infra/alloy/config.alloy.template"
RENDER_SCRIPT="${PROJECT_DIR}/infra/scripts/render_alloy_config.py"
PKG_DIR="/home/ec2-user/alloy-pkg"
CONFIG_OUT_DIR="/home/ec2-user/alloy-configs"

mkdir -p "$PKG_DIR" "$CONFIG_OUT_DIR"

echo "=== [1/5] Checking environment & dependencies ==="
if [ ! -f "$ENV_PATH" ]; then
    echo "ERROR: Environment file not found at ${ENV_PATH}. Run fetch-secrets.sh first." >&2
    exit 1
fi

# Load database host IPs directly from .env file
DATALAYER_1_IP=$(grep -E "^POSTGRES_HOST=" "$ENV_PATH" | cut -d= -f2 | tr -d '"'\')
DATALAYER_2_IP=$(grep -E "^POSTGRES_HOST_REPLICA=" "$ENV_PATH" | cut -d= -f2 | tr -d '"'\')
PROMETHEUS_IP=$(hostname -I | awk '{print $1}')

echo "Applayer-1 Private IP (Prometheus): ${PROMETHEUS_IP}"
echo "Datalayer-1 Private IP: ${DATALAYER_1_IP}"
echo "Datalayer-2 Private IP: ${DATALAYER_2_IP}"

# Determine SSH Key Args (use transient key if it exists, otherwise fall back to SSH Agent Forwarding)
SSH_KEY_ARGS=()
if [ -f "/home/ec2-user/tmp-key.pem" ]; then
    SSH_KEY_ARGS=(-i /home/ec2-user/tmp-key.pem)
    echo "Using transient SSH key: /home/ec2-user/tmp-key.pem"
else
    echo "WARNING: /home/ec2-user/tmp-key.pem not found. Using SSH Agent Forwarding..."
fi

# 2. Configure Grafana Repo & Download Alloy RPM
echo "=== [2/5] Configuring Grafana repo & downloading Alloy RPM ==="
if [ ! -f /etc/yum.repos.d/grafana.repo ]; then
    echo "-> Adding Grafana RPM repository..."
    sudo sh -c 'cat <<EOF > /etc/yum.repos.d/grafana.repo
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF'
fi

cd "$PKG_DIR"
rm -f alloy-*.rpm
echo "-> Downloading Alloy package for x86_64..."
sudo dnf download --arch=x86_64 alloy -y
ALLOY_RPM=$(ls alloy-*.rpm | head -n 1)
ALLOY_RPM_PATH="${PKG_DIR}/${ALLOY_RPM}"
echo "Downloaded package: ${ALLOY_RPM_PATH}"

# 3. Setup local node: applayer-1
echo "=== [3/5] Configuring & installing Alloy locally on applayer-1 ==="
python3 "$RENDER_SCRIPT" \
    --role applayer \
    --prometheus-ip "127.0.0.1" \
    --template "$TEMPLATE_PATH" \
    --env "$ENV_PATH" \
    --output "${CONFIG_OUT_DIR}/config.alloy.applayer"

sudo dnf localinstall -y "$ALLOY_RPM_PATH"
sudo cp "${CONFIG_OUT_DIR}/config.alloy.applayer" /etc/alloy/config.alloy
sudo systemctl enable --now alloy
sudo systemctl restart alloy
echo "Alloy service restarted on applayer-1."

# Helper function to deploy to private subnet nodes
deploy_to_database_node() {
    local role="$1"
    local ip="$2"
    local rendered_config="${CONFIG_OUT_DIR}/config.alloy.${role}"

    echo "-> Rendering configuration for ${role}..."
    python3 "$RENDER_SCRIPT" \
        --role "$role" \
        --prometheus-ip "$PROMETHEUS_IP" \
        --template "$TEMPLATE_PATH" \
        --env "$ENV_PATH" \
        --output "$rendered_config"

    echo "-> Deploying to ${role} (${ip})..."
    # Pastikan file RPM/config lama milik root dihapus terlebih dahulu agar SCP tidak Permission Denied
    ssh -o StrictHostKeyChecking=no "${SSH_KEY_ARGS[@]}" "ec2-user@${ip}" "sudo rm -f /home/ec2-user/$(basename "$ALLOY_RPM_PATH") /home/ec2-user/config.alloy" || true

    # Copy RPM and Config
    scp -o StrictHostKeyChecking=no "${SSH_KEY_ARGS[@]}" "$ALLOY_RPM_PATH" "ec2-user@${ip}:/home/ec2-user/"
    scp -o StrictHostKeyChecking=no "${SSH_KEY_ARGS[@]}" "$rendered_config" "ec2-user@${ip}:/home/ec2-user/config.alloy"

    # Install & restart service via SSH
    ssh -o StrictHostKeyChecking=no "${SSH_KEY_ARGS[@]}" "ec2-user@${ip}" "
        sudo dnf localinstall -y /home/ec2-user/$(basename "$ALLOY_RPM_PATH")
        sudo cp /home/ec2-user/config.alloy /etc/alloy/config.alloy
        sudo systemctl enable --now alloy
        sudo systemctl restart alloy
        rm -f /home/ec2-user/$(basename "$ALLOY_RPM_PATH") /home/ec2-user/config.alloy
    "
    echo "Alloy service successfully set up on ${role} (${ip})"
}

# 4. Setup datalayer-1
if [ ! -z "$DATALAYER_1_IP" ]; then
    echo "=== [4/5] Configuring & installing Alloy on datalayer-1 ==="
    deploy_to_database_node datalayer-1 "$DATALAYER_1_IP"
else
    echo "WARNING: DATALAYER_1_IP not configured in .env"
fi

# 5. Setup datalayer-2
if [ ! -z "$DATALAYER_2_IP" ]; then
    echo "=== [5/5] Configuring & installing Alloy on datalayer-2 ==="
    deploy_to_database_node datalayer-2 "$DATALAYER_2_IP"
else
    echo "WARNING: DATALAYER_2_IP not configured in .env"
fi

echo "=== setup-alloy-nodes.sh completed ==="
