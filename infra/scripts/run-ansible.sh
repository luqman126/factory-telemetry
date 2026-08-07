#!/usr/bin/env bash
# ============================================================
# run-ansible.sh
# Standalone helper script to configure database and application nodes.
# Run this manually AFTER `terraform apply` completes successfully.
#
# It automatically reads instance IDs and IPs from Terraform outputs,
# queries the bastion's Tailscale IP via AWS SSM, generates a temporary
# Ansible inventory, and executes `ansible-playbook site.yml`.
# ============================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TERRAFORM_DIR="${PROJECT_DIR}/infra/terraform"
ANSIBLE_DIR="${PROJECT_DIR}/ansible"
INVENTORY_FILE="/tmp/ansible-inventory-$$.ini"
export AWS_PAGER=""

echo "============================================================"
echo "    IoT Big Data — Ansible Configuration Provisioner"
echo "============================================================"

# --- 1. Auto-discover inputs from Terraform or Environment ---
echo "-> Fetching environment configuration from Terraform outputs..."

AWS_REGION="${AWS_REGION:-ap-southeast-1}"
SSH_KEY_NAME="${SSH_KEY_NAME:-iot-bigdata-key}"
SSH_KEY_PATH="${HOME}/.ssh/${SSH_KEY_NAME}.pem"

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "ERROR: SSH private key not found at $SSH_KEY_PATH" >&2
    exit 1
fi

BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID:-$(cd "$TERRAFORM_DIR" && terraform output -raw applayer_instance_id 2>/dev/null || true)}"
PRIMARY_IP="${PRIMARY_IP:-$(cd "$TERRAFORM_DIR" && terraform output -raw datalayer_1_private_ip 2>/dev/null || echo "10.1.2.10")}"
REPLICA_IP="${REPLICA_IP:-$(cd "$TERRAFORM_DIR" && terraform output -raw datalayer_2_private_ip 2>/dev/null || echo "10.1.2.20")}"
ALLOWED_CIDR="${ALLOWED_CIDR:-$(cd "$TERRAFORM_DIR" && terraform output -raw vpc_cidr 2>/dev/null || echo "10.1.0.0/16")}"
PROMETHEUS_IP="${PROMETHEUS_IP:-$(cd "$TERRAFORM_DIR" && terraform output -raw applayer_private_ip 2>/dev/null || echo "")}"

if [ -z "$BASTION_INSTANCE_ID" ]; then
    echo "ERROR: Could not retrieve Bastion Instance ID from Terraform outputs." >&2
    echo "       Please ensure 'terraform apply' has run successfully." >&2
    exit 1
fi

echo "   Bastion Instance ID : $BASTION_INSTANCE_ID"
echo "   DB Primary IP       : $PRIMARY_IP"
echo "   DB Replica IP       : $REPLICA_IP"
echo "   Allowed VPC CIDR    : $ALLOWED_CIDR"
echo "   Prometheus IP       : $PROMETHEUS_IP"

PROJECT_NAME="${PROJECT_NAME:-iot-bigdata}"
ENV="${ENV:-staging}"

echo "-> Fetching environment credentials from AWS SSM Parameter Store..."
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(aws ssm get-parameter --name "/${PROJECT_NAME}/${ENV}/CLOUDFLARE_API_TOKEN" --with-decryption --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "")}"
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-$(aws ssm get-parameter --name "/${PROJECT_NAME}/${ENV}/CLOUDFLARE_TUNNEL_TOKEN" --with-decryption --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "")}"
DOMAIN_NAME="${DOMAIN_NAME:-$(aws ssm get-parameter --name "/${PROJECT_NAME}/${ENV}/DOMAIN_NAME" --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "chescloud.my.id")}"
if [ "$ENV" = "production" ]; then
    MQTT_SUBDOMAIN="mqtt.${DOMAIN_NAME}"
else
    MQTT_SUBDOMAIN="${ENV}-mqtt.${DOMAIN_NAME}"
fi

DB_NAME="${DB_NAME:-$(aws ssm get-parameter --name "/${PROJECT_NAME}/${ENV}/POSTGRES_DB" --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "factory_telemetry")}"
DB_USER="${DB_USER:-$(aws ssm get-parameter --name "/${PROJECT_NAME}/${ENV}/POSTGRES_USER" --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "kagebyo")}"
DB_PASSWORD="${DB_PASSWORD:-$(aws ssm get-parameter --name "/${PROJECT_NAME}/${ENV}/POSTGRES_PASSWORD" --with-decryption --region "$AWS_REGION" --query "Parameter.Value" --output text 2>/dev/null || echo "")}"

if [ -z "$DB_PASSWORD" ]; then
    echo "ERROR: Could not retrieve POSTGRES_PASSWORD from SSM Parameter Store (/${PROJECT_NAME}/${ENV}/POSTGRES_PASSWORD)." >&2
    echo "       Please ensure credentials are standard in SSM or pass DB_PASSWORD env variable." >&2
    exit 1
fi

# --- 2. Discover Bastion Tailscale IP via AWS SSM ---
echo ""
echo "-> Discovering Tailscale IP on Bastion (${BASTION_INSTANCE_ID})..."

BASTION_TS_IP=""
for attempt in $(seq 1 30); do
    CMD_ID=$(aws ssm send-command \
      --instance-ids "$BASTION_INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters '{"commands":["tailscale ip -4 2>/dev/null || echo NOTREADY"]}' \
      --region "$AWS_REGION" \
      --query "Command.CommandId" \
      --output text 2>/dev/null) || true

    if [ -n "$CMD_ID" ]; then
        aws ssm wait command-executed \
          --command-id "$CMD_ID" \
          --instance-id "$BASTION_INSTANCE_ID" \
          --region "$AWS_REGION" 2>/dev/null || true

        RESULT=$(aws ssm get-command-invocation \
          --command-id "$CMD_ID" \
          --instance-id "$BASTION_INSTANCE_ID" \
          --region "$AWS_REGION" \
          --query "StandardOutputContent" \
          --output text 2>/dev/null | tr -d '[:space:]') || true

        if [ -n "$RESULT" ] && [ "$RESULT" != "NOTREADY" ]; then
            BASTION_TS_IP="$RESULT"
            echo "   Bastion Tailscale IP: $BASTION_TS_IP"
            break
        fi
    fi

    echo "   Attempt $attempt/30: Waiting for Tailscale on bastion..."
    sleep 10
done

if [ -z "$BASTION_TS_IP" ]; then
    echo "ERROR: Could not discover bastion Tailscale IP via SSM." >&2
    exit 1
fi

# --- 3. Check SSH connectivity to Bastion ---
echo ""
echo "-> Testing SSH connection to Bastion ($BASTION_TS_IP)..."
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$SSH_KEY_PATH" ec2-user@"$BASTION_TS_IP" "echo 'Bastion SSH OK'" 2>/dev/null; then
    echo "ERROR: Could not connect to Bastion via Tailscale IP ($BASTION_TS_IP)." >&2
    echo "       Please ensure your local machine is connected to Tailscale." >&2
    exit 1
fi

# --- 4. Generate Dynamic Ansible Inventory ---
echo ""
echo "-> Generating dynamic Ansible inventory at $INVENTORY_FILE..."

cat > "$INVENTORY_FILE" <<INVENTORY
[db_primary]
datalayer-1 ansible_host=${PRIMARY_IP}

[db_replica]
datalayer-2 ansible_host=${REPLICA_IP}

[app_nodes]
applayer-1 ansible_host=${BASTION_TS_IP}

[all:vars]
ansible_user=ec2-user
ansible_ssh_private_key_file=${SSH_KEY_PATH}

[db_primary:vars]
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${SSH_KEY_PATH} -W %h:%p -q ec2-user@${BASTION_TS_IP}"

[db_replica:vars]
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o ProxyCommand="ssh -i ${SSH_KEY_PATH} -W %h:%p -q ec2-user@${BASTION_TS_IP}"
INVENTORY

echo "   Inventory contents:"
cat "$INVENTORY_FILE"

# --- 5. Run Ansible Playbook ---
echo ""
echo "-> Executing ansible-playbook site.yml..."
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i "$INVENTORY_FILE" \
  --extra-vars "db_name=$DB_NAME db_user=$DB_USER db_password=$DB_PASSWORD replica_ip=$REPLICA_IP primary_ip=$PRIMARY_IP allowed_cidr=${ALLOWED_CIDR:-10.1.0.0/16} prometheus_ip=$PROMETHEUS_IP cloudflare_api_token=$CLOUDFLARE_API_TOKEN cloudflare_tunnel_token=$CLOUDFLARE_TUNNEL_TOKEN mqtt_subdomain=$MQTT_SUBDOMAIN domain_name=$DOMAIN_NAME" \
  "$ANSIBLE_DIR/site.yml"

# --- 6. Clean up temporary inventory ---
rm -f "$INVENTORY_FILE"

echo ""
echo "============================================================"
echo "    Ansible Configuration Completed Successfully!           "
echo "============================================================"
