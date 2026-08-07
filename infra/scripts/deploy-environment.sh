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

echo "============================================================"
echo "    IoT Big Data — End-to-End Environment Deployer (${ENV})"
echo "============================================================"

# --- Phase 1: Terraform Plan ---
echo ""
echo "=== [Phase 1/3] Planning Infrastructure Changes ==="
cd "${TERRAFORM_DIR}"
terraform plan -var-file="environments/${ENV}.tfvars" -out="${ENV}.tfplan"

# --- Phase 2: Terraform Apply ---
echo ""
echo "=== [Phase 2/3] Provisioning Infrastructure & Auto-Uploading Scripts ==="
terraform apply "${ENV}.tfplan"
rm -f "${ENV}.tfplan"

# --- Phase 3: Configure Database Cluster & Monitoring via Ansible ---
echo ""
echo "=== [Phase 3/3] Configuring Services with Ansible ==="
cd "${SCRIPT_DIR}"
bash "${SCRIPT_DIR}/run-ansible.sh"

echo ""
echo "============================================================"
echo "    Deployment Completed Successfully!"
echo "============================================================"
