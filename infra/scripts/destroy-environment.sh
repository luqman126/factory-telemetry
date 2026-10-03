#!/usr/bin/env bash
# ============================================================
# destroy-environment.sh
# Safely tears down the deployed AWS infrastructure for a given
# environment to avoid lingering cloud costs.
#
# Usage:
#   bash infra/scripts/destroy-environment.sh [staging|production]
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
echo "    IoT Big Data — TEARDOWN INITIATED (${ENV})"
echo "    WARNING: This will DESTROY all AWS infrastructure!"
echo "============================================================"
echo ""

cd "${TERRAFORM_DIR}"

# --- Phase 1: Initialize Backend ---
echo "=== [Phase 1/2] Initializing Backend for (${ENV}) ==="
terraform init -backend-config="key=${ENV}/terraform.tfstate" -reconfigure

SECRET_OPT=""
if [ -f "environments/${ENV}.secrets.tfvars" ]; then
    SECRET_OPT="-var-file=environments/${ENV}.secrets.tfvars"
fi

# --- Phase 2: Plan Destruction ---
echo ""
echo "=== [Phase 2/2] Planning Destruction ==="
terraform plan -destroy -var-file="environments/${ENV}.tfvars" ${SECRET_OPT} -out="${ENV}.destroy.tfplan"

# --- Gate: Review Plan Before Destroy ---
if [[ -t 0 ]]; then
    echo ""
    echo "⚠️  DANGER: Review the destruction plan above."
    read -rp "Are you absolutely sure you want to destroy all resources for '${ENV}'? [y/N]: " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "Aborted by operator. Infrastructure preserved."
        rm -f "${ENV}.destroy.tfplan"
        exit 0
    fi
fi

echo ""
echo "=== Executing Destruction ==="
terraform apply "${ENV}.destroy.tfplan"
rm -f "${ENV}.destroy.tfplan"

echo ""
echo "============================================================"
echo "    Destruction Completed Successfully!"
echo "    All resources for '${ENV}' have been destroyed."
echo "============================================================"
