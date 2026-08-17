#!/usr/bin/env bash
# 99-cleanup.sh
# Safely destroy OpenShift SNO cluster and optionally the DNS zone.
#
# Usage:
#   ./scripts/99-cleanup.sh                  # interactive; keeps sno-dns-rg
#   ./scripts/99-cleanup.sh --destroy-dns    # also run terraform destroy on DNS zone
#   ./scripts/99-cleanup.sh --yes            # skip confirmation prompts (use with care)
#
# This script REQUIRES explicit confirmation before running any destructive command
# unless --yes is passed. It will NOT blindly destroy resources without showing
# what it will touch first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${REPO_ROOT}/openshift"

DESTROY_DNS=false
AUTO_YES=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--destroy-dns] [--yes]

  --destroy-dns   Also destroy Terraform-managed DNS zone (sno-dns-rg).
                  Default: keep DNS zone for faster Phase 2 redeploy.
  --yes           Skip interactive confirmation prompts.
  -h, --help      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destroy-dns) DESTROY_DNS=true; shift ;;
    --yes)         AUTO_YES=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

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
if [[ "${DESTROY_DNS}" == "true" ]]; then
  echo ""
  echo "  --destroy-dns set: DNS zone and sno-dns-rg will also be destroyed after cluster teardown."
fi
echo ""

if [[ "${AUTO_YES}" == "true" ]]; then
  CONFIRM="yes"
  info "Auto-confirmed cluster destruction (--yes)"
else
  read -rp "  Type 'yes' to confirm cluster destruction: " CONFIRM
fi
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

# --- Archive installer artifacts BEFORE wipe (never commit) ---
section "Archiving installer artifacts before cleanup"

if [[ -x "${SCRIPT_DIR}/06-archive-run.sh" ]]; then
  "${SCRIPT_DIR}/06-archive-run.sh" --status destroyed --upload || \
    "${SCRIPT_DIR}/06-archive-run.sh" --status destroyed || \
    warn "Archive step failed — continuing with cleanup"
else
  warn "06-archive-run.sh not found — skipping archive"
fi

# --- Force-delete any leftover cluster RGs (no cache / dependency leftovers) ---
section "Force-deleting leftover cluster resource groups"

# Keep Terraform DNS RG; delete every other sno-* / cluster RG
LEFTOVER_RGS=$(az group list \
  --query "[?contains(name, 'sno') && name!='sno-dns-rg'].name" \
  -o tsv 2>/dev/null || echo "")

if [[ -n "${LEFTOVER_RGS}" ]]; then
  echo "${LEFTOVER_RGS}" | while read -r rg; do
    [[ -z "${rg}" ]] && continue
    warn "Deleting leftover resource group: ${rg}"
    az group delete --name "${rg}" --yes --no-wait
    ok "Delete started: ${rg}"
  done
  info "Waiting for resource group deletions to finish..."
  for rg in ${LEFTOVER_RGS}; do
    while az group show --name "${rg}" &>/dev/null; do
      sleep 10
    done
    ok "Deleted: ${rg}"
  done
else
  ok "No leftover cluster resource groups"
fi

# --- Clean up local files ---
section "Cleaning up local installation artifacts"

# Wipe ALL installer-generated state so the next create starts from a clean slate.
# Keep only: README.md, install-config.yaml.example, install-config.yaml.bak
KEEP_FILES=(
  "README.md"
  "install-config.yaml.example"
  "install-config.yaml.bak"
)

shopt -s nullglob dotglob
for path in "${INSTALL_DIR}"/*; do
  base=$(basename "${path}")
  keep=false
  for k in "${KEEP_FILES[@]}"; do
    if [[ "${base}" == "${k}" ]]; then
      keep=true
      break
    fi
  done
  if [[ "${keep}" == "false" ]]; then
    rm -rf "${path}"
    ok "Removed: ${path}"
  fi
done
shopt -u nullglob dotglob

# Keep install-config.yaml.bak (useful for replay in Phase 2)
if [[ -f "${INSTALL_DIR}/install-config.yaml.bak" ]]; then
  info "Kept: ${INSTALL_DIR}/install-config.yaml.bak (useful for Phase 2 replay)"
fi

# Explicit note: no installer cache remains
ok "Installer directory reset — next create will have no cached state"

# --- Destroy DNS zone (optional) ---
section "DNS zone (Terraform)"

if [[ "${DESTROY_DNS}" == "true" ]]; then
  if [[ -d "${REPO_ROOT}/terraform" ]] && [[ -f "${REPO_ROOT}/terraform/terraform.tfstate" ]]; then
    echo ""
    echo "  Running: terraform destroy (--destroy-dns)"
    cd "${REPO_ROOT}/terraform"
    if [[ "${AUTO_YES}" == "true" ]]; then
      terraform destroy -auto-approve
    else
      terraform destroy
    fi
    ok "DNS zone destroyed"
  else
    warn "No Terraform state found — DNS zone may not exist or was not managed by this Terraform"
    info "Check manually: az network dns zone list -o table"
    # Fallback: delete RG if it still exists
    if az group show --name sno-dns-rg &>/dev/null; then
      warn "Deleting sno-dns-rg manually"
      az group delete --name sno-dns-rg --yes --no-wait
    fi
  fi
else
  echo ""
  echo "  The Terraform-managed DNS zone (sno-dns-rg) was NOT destroyed."
  echo "  This is intentional — keeping the zone allows Phase 2 (reproducibility)"
  echo "  to redeploy without re-delegating NS records."
  echo ""
  echo "  To destroy the DNS zone on the next run:"
  echo "    ./scripts/99-cleanup.sh --destroy-dns"
  echo "  Or manually:"
  echo "    cd ${REPO_ROOT}/terraform && terraform destroy"
  echo ""

  if [[ "${AUTO_YES}" == "true" ]]; then
    info "DNS zone preserved (--yes without --destroy-dns)"
  else
    read -rp "  Destroy DNS zone now? (yes/no): " DESTROY_DNS_PROMPT
    if [[ "${DESTROY_DNS_PROMPT}" == "yes" ]]; then
      if [[ -d "${REPO_ROOT}/terraform" ]] && [[ -f "${REPO_ROOT}/terraform/terraform.tfstate" ]]; then
        echo ""
        echo "  Running: terraform destroy"
        cd "${REPO_ROOT}/terraform"
        terraform destroy
        ok "DNS zone destroyed"
      else
        warn "No Terraform state found — check Azure portal manually"
      fi
    else
      info "DNS zone preserved. Useful for Phase 2 reproducibility testing."
    fi
  fi
fi

# --- Post-cleanup verification ---
section "Post-cleanup verification"

SNO_RGS=$(az group list --query "[?contains(name, 'sno')].name" -o tsv 2>/dev/null || true)
SNO_PIPS=$(az network public-ip list --query "[?contains(name, 'sno')].name" -o tsv 2>/dev/null || true)
SNO_LBS=$(az network lb list --query "[?contains(name, 'sno')].name" -o tsv 2>/dev/null || true)

if [[ -z "${SNO_RGS}" ]]; then
  ok "No resource groups containing 'sno' remain"
else
  warn "Resource groups still present:"
  echo "${SNO_RGS}" | while read -r rg; do info "  ${rg}"; done
fi

if [[ -z "${SNO_PIPS}" ]]; then
  ok "No orphaned public IPs containing 'sno'"
else
  warn "Orphaned public IPs:"
  echo "${SNO_PIPS}" | while read -r pip; do info "  ${pip}"; done
fi

if [[ -z "${SNO_LBS}" ]]; then
  ok "No orphaned load balancers containing 'sno'"
else
  warn "Orphaned load balancers:"
  echo "${SNO_LBS}" | while read -r lb; do info "  ${lb}"; done
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
echo "  To redeploy (Phase 2) — always start from a clean slate:"
echo "    1. Confirm no leftover RGs: az group list -o table | grep sno"
echo "    2. Regenerate install-config (do not reuse stale installer state):"
echo "         export PULL_SECRET=/home/devops/pull-secret.txt"
echo "         ./scripts/02-create-install-config.sh"
echo "    3. ./scripts/03-install-sno.sh"
echo ""
echo "  Future ACR work: keep default managed identity (do not set identity.type: None)."
echo "  Installer SP must retain Contributor + User Access Administrator."
echo ""
