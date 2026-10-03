#!/usr/bin/env bash
# ============================================================
# deploy-environment.sh
# Master end-to-end deployment orchestrator script
#
# Usage:
#   bash infra/scripts/deploy-environment.sh [staging|production]
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TERRAFORM_DIR="${PROJECT_DIR}/infra/terraform"
ENV="${1:-staging}"

if [[ "$ENV" != "staging" && "$ENV" != "production" ]]; then
    echo "ERROR: Invalid environment '${ENV}'." >&2
    echo "       Allowed environments: staging, production" >&2
    exit 1
fi

echo "============================================================"
echo "    IoT Big Data — End-to-End Environment Deployer (${ENV})"
echo "============================================================"

# --- Phase 1: Terraform Init & Plan ---
echo ""
echo "=== [Phase 1/3] Initializing Backend & Planning Infrastructure (${ENV}) ==="
cd "${TERRAFORM_DIR}"
terraform init -backend-config="key=${ENV}/terraform.tfstate" -reconfigure

SECRET_OPT=""
if [ -f "environments/${ENV}.secrets.tfvars" ]; then
    SECRET_OPT="-var-file=environments/${ENV}.secrets.tfvars"
fi

terraform plan -var-file="environments/${ENV}.tfvars" ${SECRET_OPT} -out="${ENV}.tfplan"

# --- Gate: Review Plan Before Apply ---
if [[ -t 0 ]]; then
    echo ""
    read -rp "Review the plan above. Proceed with apply? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted by operator."
        rm -f "${ENV}.tfplan"
        exit 0
    fi
fi

# --- Phase 2: Terraform Apply ---
echo ""
echo "=== [Phase 2/3] Provisioning Infrastructure & Auto-Uploading Scripts ==="
terraform apply "${ENV}.tfplan"
rm -f "${ENV}.tfplan"

# --- Phase 3: Configure Database Cluster & Monitoring via Ansible ---
echo ""
echo "=== [Phase 3/3] Configuring Services with Ansible (${ENV}) ==="
cd "${SCRIPT_DIR}"
ENV="${ENV}" bash "${SCRIPT_DIR}/run-ansible.sh"

echo ""
echo "============================================================"
echo "    Deployment Completed Successfully!"
echo "============================================================"
