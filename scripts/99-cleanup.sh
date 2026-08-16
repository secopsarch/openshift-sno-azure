#!/usr/bin/env bash
# 99-cleanup.sh
# Safely destroy OpenShift SNO cluster and optionally the DNS zone.
#
# This script REQUIRES explicit confirmation before running any destructive command.
# It will NOT blindly destroy resources without showing you what it will touch first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${REPO_ROOT}/openshift"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo "  $1"; }
ok()      { echo -e "${GREEN}  OK${NC}  $1"; }
fail()    { echo -e "${RED}  ERROR${NC}  $1"; }
warn()    { echo -e "${YELLOW}  WARN${NC}  $1"; }
section() { echo ""; echo -e "${BLUE}─────────────────────────────────────${NC}"; echo "  $1"; echo -e "${BLUE}─────────────────────────────────────${NC}"; }

echo "========================================"
echo " OpenShift SNO Cleanup"
echo " $(date)"
echo "========================================"
echo ""
echo -e "${RED}  WARNING: This will DESTROY Azure resources and incur data loss.${NC}"
echo -e "${RED}  All workloads, data, and configurations on the cluster will be lost.${NC}"
echo ""

# --- Show target resources ---
section "Cleanup target"

# Azure subscription
if ! az account show &>/dev/null; then
  fail "Not authenticated to Azure — run: az login"
  exit 1
fi

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
info "Azure subscription : ${SUB_NAME}"
info "Subscription ID    : ${SUB_ID}"

# Cluster info from install-config backup or state
CLUSTER_NAME="unknown"
BASE_DOMAIN="unknown"
AZURE_REGION="unknown"

CONFIG_BACKUP="${INSTALL_DIR}/install-config.yaml.bak"
if [[ -f "${CONFIG_BACKUP}" ]]; then
  CLUSTER_NAME=$(grep '^  name:' "${CONFIG_BACKUP}" | head -1 | awk '{print $2}' || echo "unknown")
  BASE_DOMAIN=$(grep '^baseDomain:' "${CONFIG_BACKUP}" | awk '{print $2}' || echo "unknown")
  AZURE_REGION=$(grep 'region:' "${CONFIG_BACKUP}" | awk '{print $2}' || echo "unknown")
fi

info "Cluster name       : ${CLUSTER_NAME}"
info "Base domain        : ${BASE_DOMAIN}"
info "Azure region       : ${AZURE_REGION}"
info "Installation dir   : ${INSTALL_DIR}"
echo ""

# Show existing Azure resource groups
info "Azure resource groups containing 'sno' or '${CLUSTER_NAME}':"
EXISTING_RGS=$(az group list \
  --query "[?contains(name, 'sno') || contains(name, '${CLUSTER_NAME}')].{Name:name, Location:location, State:properties.provisioningState}" \
  -o table 2>/dev/null || echo "  (unable to list)")
echo "${EXISTING_RGS}"
echo ""

# Check if state file exists
if [[ -f "${INSTALL_DIR}/.openshift_install_state.json" ]]; then
  info "Install state file found — openshift-install destroy cluster can clean up automatically"
else
  warn "No install state file found at ${INSTALL_DIR}/.openshift_install_state.json"
  warn "openshift-install may not be able to identify all resources to destroy."
  warn "You may need to manually delete the cluster resource group in Azure."
fi

# --- Confirmation ---
section "Confirmation required"
echo ""
echo "  This will run:"
echo "    openshift-install destroy cluster --dir ${INSTALL_DIR}"
echo ""
echo "  This destroys:"
echo "    - Control plane VM and all disks"
echo "    - Bootstrap VM (if still present)"
echo "    - Load balancers (3)"
echo "    - Public IPs (3)"
echo "    - VNet and subnets"
echo "    - NSGs"
echo "    - DNS A records (api.* and *.apps.*)"
echo "    - Storage accounts"
echo "    - Managed identities"
echo "    - The cluster resource group and all contents"
echo ""
echo "  This does NOT destroy (managed by Terraform):"
echo "    - DNS zone: $(cat "${REPO_ROOT}/terraform/terraform.tfvars" 2>/dev/null | grep dns_zone_name | awk -F= '{print $2}' | tr -d ' "' || echo "see terraform/terraform.tfvars")"
echo "    - DNS resource group: sno-dns-rg"
echo ""

read -rp "  Type 'yes' to confirm cluster destruction: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Aborted. No changes made."
  exit 0
fi

# --- Destroy cluster ---
section "Destroying cluster"

if [[ ! -f "${INSTALL_DIR}/.openshift_install_state.json" ]]; then
  warn "No state file — attempting destroy anyway (may be a no-op or partial cleanup)"
fi

echo ""
echo "  Running: openshift-install destroy cluster"
echo "  This may take 5-15 minutes..."
echo ""

openshift-install destroy cluster \
  --dir "${INSTALL_DIR}" \
  --log-level=info

DESTROY_EXIT=$?

if [[ "${DESTROY_EXIT}" -eq 0 ]]; then
  ok "openshift-install destroy cluster completed"
else
  warn "openshift-install destroy cluster exited with code ${DESTROY_EXIT}"
  warn "Some resources may still exist — check Azure portal"
fi

# --- Verify cluster resources are gone ---
section "Verifying cluster resource cleanup"

sleep 5
REMAINING_RGS=$(az group list \
  --query "[?contains(name, '${CLUSTER_NAME}') && !contains(name, 'dns')].name" \
  -o tsv 2>/dev/null || echo "")

if [[ -z "${REMAINING_RGS}" ]]; then
  ok "No cluster resource groups remain"
else
  warn "The following resource groups may still exist:"
  echo "${REMAINING_RGS}" | while read -r rg; do
    info "  ${rg}"
    info "  Delete manually: az group delete --name ${rg} --yes"
  done
fi

# --- Clean up local files ---
section "Cleaning up local installation artifacts"

FILES_TO_REMOVE=(
  "${INSTALL_DIR}/auth"
  "${INSTALL_DIR}/*.ign"
  "${INSTALL_DIR}/.openshift_install.log"
  "${INSTALL_DIR}/.openshift_install_state.json"
  "${INSTALL_DIR}/metadata.json"
)

for f in "${FILES_TO_REMOVE[@]}"; do
  # Expand globs safely
  for match in $f; do
    if [[ -e "${match}" ]]; then
      rm -rf "${match}"
      ok "Removed: ${match}"
    fi
  done
done

# Keep install-config.yaml.bak (useful for replay in Phase 2)
if [[ -f "${INSTALL_DIR}/install-config.yaml.bak" ]]; then
  info "Kept: ${INSTALL_DIR}/install-config.yaml.bak (useful for Phase 2 replay)"
fi

# --- Offer to destroy DNS zone ---
section "Optional: destroy DNS zone (Terraform)"
echo ""
echo "  The Terraform-managed DNS zone (sno-dns-rg) was NOT destroyed."
echo "  This is intentional — keeping the zone allows Phase 2 (reproducibility)"
echo "  to redeploy without re-delegating NS records."
echo ""
echo "  To destroy the DNS zone and resource group, run:"
echo "    cd ${REPO_ROOT}/terraform && terraform destroy"
echo ""

read -rp "  Destroy DNS zone now? (yes/no): " DESTROY_DNS
if [[ "${DESTROY_DNS}" == "yes" ]]; then
  if [[ -d "${REPO_ROOT}/terraform" ]] && [[ -f "${REPO_ROOT}/terraform/terraform.tfstate" ]]; then
    echo ""
    echo "  Running: terraform destroy"
    cd "${REPO_ROOT}/terraform"
    terraform destroy
    ok "DNS zone destroyed"
  else
    warn "No Terraform state found — DNS zone may not exist or was not managed by this Terraform"
    info "Check manually: az network dns zone list -o table"
  fi
else
  info "DNS zone preserved. Useful for Phase 2 reproducibility testing."
fi

# --- Final summary ---
echo ""
echo "========================================"
echo " Cleanup complete — $(date)"
echo "========================================"
echo ""
echo "  Verify no billable resources remain:"
echo "    az group list --query \"[?contains(name, 'sno')]\" -o table"
echo "    az network public-ip list --query \"[?contains(name, 'sno')]\" -o table"
echo "    az network lb list --query \"[?contains(name, 'sno')]\" -o table"
echo ""
echo "  To redeploy (Phase 2):"
echo "    cp ${INSTALL_DIR}/install-config.yaml.bak ${INSTALL_DIR}/install-config.yaml"
echo "    ./scripts/03-install-sno.sh"
echo ""
