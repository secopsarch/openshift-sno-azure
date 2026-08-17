#!/usr/bin/env bash
# 03-install-sno.sh
# Run openshift-install create cluster.
#
# IMPORTANT: openshift-install create cluster is a ONE-SHOT operation.
# It cannot be re-run on the same directory if it fails or is interrupted.
# On failure, run 99-cleanup.sh, then regenerate install-config.yaml, then retry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${REPO_ROOT}/openshift"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo "  $1"; }
ok()    { echo -e "${GREEN}  OK${NC}  $1"; }
fail()  { echo -e "${RED}  ERROR${NC}  $1"; exit 1; }
warn()  { echo -e "${YELLOW}  WARN${NC}  $1"; }
section() { echo ""; echo -e "${BLUE}─────────────────────────────────────${NC}"; echo "  $1"; echo -e "${BLUE}─────────────────────────────────────${NC}"; }

echo "========================================"
echo " OpenShift SNO Installation"
echo " $(date)"
echo "========================================"

# --- Pre-flight checks ---
section "Pre-flight validation"

# Verify install-config exists
if [[ ! -f "${INSTALL_DIR}/install-config.yaml" ]]; then
  fail "install-config.yaml not found at ${INSTALL_DIR}/install-config.yaml
  Run ./scripts/02-create-install-config.sh first."
fi
ok "install-config.yaml found"

# Extract key values for display (without pull secret)
CLUSTER_NAME=$(grep '^  name:' "${INSTALL_DIR}/install-config.yaml" | head -1 | awk '{print $2}')
BASE_DOMAIN=$(grep '^baseDomain:' "${INSTALL_DIR}/install-config.yaml" | awk '{print $2}')
AZURE_REGION=$(grep 'region:' "${INSTALL_DIR}/install-config.yaml" | awk '{print $2}')
CP_REPLICAS=$(grep -A 10 '^controlPlane:' "${INSTALL_DIR}/install-config.yaml" | grep 'replicas:' | head -1 | awk '{print $2}')
WORKER_REPLICAS=$(grep -A 5 '^compute:' "${INSTALL_DIR}/install-config.yaml" | grep 'replicas:' | head -1 | awk '{print $2}')
VM_TYPE=$(grep -A 10 '^controlPlane:' "${INSTALL_DIR}/install-config.yaml" | grep 'type:' | head -1 | awk '{print $2}')

echo ""
info "Installation target:"
info "  Cluster name     : ${CLUSTER_NAME}"
info "  Base domain      : ${BASE_DOMAIN}"
info "  Azure region     : ${AZURE_REGION}"
info "  Control plane VM : ${VM_TYPE}"
info "  CP replicas      : ${CP_REPLICAS} (expected: 1 for SNO)"
info "  Worker replicas  : ${WORKER_REPLICAS} (expected: 0 for SNO)"
info "  API endpoint     : https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
info "  Console          : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo ""

# Verify SNO configuration
if [[ "${CP_REPLICAS}" != "1" ]]; then
  fail "controlPlane.replicas is '${CP_REPLICAS}' — must be 1 for SNO"
fi
if [[ "${WORKER_REPLICAS}" != "0" ]]; then
  fail "compute.replicas is '${WORKER_REPLICAS}' — must be 0 for SNO"
fi
ok "SNO configuration validated (controlPlane: 1, workers: 0)"

# Verify Azure authentication
if ! az account show &>/dev/null; then
  fail "Not authenticated to Azure — run: az login"
fi
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
ok "Azure authenticated"
info "  Subscription: ${SUB_NAME} (${SUB_ID})"

# Check for existing state file (indicates previous failed install)
if [[ -f "${INSTALL_DIR}/.openshift_install_state.json" ]]; then
  warn "An installation state file already exists: ${INSTALL_DIR}/.openshift_install_state.json"
  warn "This indicates a previous installation attempt. openshift-install cannot be re-run"
  warn "on a directory with an existing state file."
  echo ""
  echo "Options:"
  echo "  1. Run ./scripts/99-cleanup.sh to destroy existing resources and start fresh"
  echo "  2. Run ./scripts/04-wait-for-install.sh if the previous install is still running"
  echo ""
  read -rp "  Do you want to continue anyway? (this will likely fail) (yes/no): " FORCE_CONTINUE
  if [[ "${FORCE_CONTINUE}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Cost and time warning ---
section "Cost and time warning"
echo ""
echo -e "${YELLOW}  WARNING: This command will create billable Azure resources.${NC}"
echo ""
echo "  Resources that will be created:"
echo "    - Bootstrap VM:     Standard_D8s_v7 (~\$0.38/hr, temporary)"
echo "    - Control plane VM: Standard_D8s_v7 (~\$0.38/hr, ongoing)"
echo "    - OS disks:         Premium_LRS (~\$0.02/hr, ongoing)"
echo "    - Load balancers:   3x Standard (~\$0.03/hr each, ongoing)"
echo "    - Public IPs:       3x Standard (~\$0.005/hr each)"
echo "    - Storage + misc:   Variable"
echo ""
echo "  Estimated installation time: 40-90 minutes"
echo ""
echo "  Subscription : ${SUB_NAME}"
echo "  Sub ID       : ${SUB_ID}"
echo "  Region       : ${AZURE_REGION}"
echo "  Cluster      : ${CLUSTER_NAME}.${BASE_DOMAIN}"
echo ""
echo -e "${RED}  OpenShift installation CANNOT be paused or undone once started.${NC}"
echo -e "${RED}  If it fails, you must run 99-cleanup.sh and start from scratch.${NC}"
echo ""

# --- Explicit confirmation ---
read -rp "  Type the cluster name to confirm installation (${CLUSTER_NAME}): " CONFIRM_NAME
if [[ "${CONFIRM_NAME}" != "${CLUSTER_NAME}" ]]; then
  echo "Confirmation did not match. Aborted."
  exit 0
fi

# --- Back up install-config (it will be consumed by the installer) ---
section "Backing up install-config.yaml"

BACKUP_FILE="${INSTALL_DIR}/install-config.yaml.bak"
if [[ ! -f "${BACKUP_FILE}" ]]; then
  cp "${INSTALL_DIR}/install-config.yaml" "${BACKUP_FILE}"
  chmod 600 "${BACKUP_FILE}"
  ok "Backup created: ${BACKUP_FILE}"
else
  ok "Backup already exists: ${BACKUP_FILE}"
fi

# --- Run installation ---
section "Running openshift-install create cluster"
echo ""
echo "  Log file: ${INSTALL_DIR}/.openshift_install.log"
echo "  Follow progress: tail -f ${INSTALL_DIR}/.openshift_install.log"
echo ""
echo "  Starting at: $(date)"
echo ""

openshift-install create cluster \
  --dir "${INSTALL_DIR}" \
  --log-level=info

INSTALL_EXIT=$?

echo ""
echo "  Completed at: $(date)"
echo ""

if [[ "${INSTALL_EXIT}" -eq 0 ]]; then
  echo -e "${GREEN}========================================"
  echo " Installation completed successfully"
  echo -e "========================================${NC}"
  echo ""
  echo "  kubeconfig : ${INSTALL_DIR}/auth/kubeconfig"
  echo "  password   : ${INSTALL_DIR}/auth/kubeadmin-password"
  echo ""
  echo "  To connect:"
  echo "    export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig"
  echo "    oc whoami"
  echo ""
  # Archive successful run (local + optional Azure blob on existing SA)
  if [[ -x "${SCRIPT_DIR}/06-archive-run.sh" ]]; then
    "${SCRIPT_DIR}/06-archive-run.sh" --status success --upload || \
      "${SCRIPT_DIR}/06-archive-run.sh" --status success || true
  fi
  echo "Next step: ./scripts/05-validate-cluster.sh"
else
  echo -e "${RED}========================================"
  echo " Installation FAILED (exit code ${INSTALL_EXIT})"
  echo -e "========================================${NC}"
  echo ""
  echo "  Review the installation log:"
  echo "    cat ${INSTALL_DIR}/.openshift_install.log | grep -i 'error\|fatal\|failed'"
  echo ""
  # Archive failed attempt BEFORE any wipe so we keep terraform.platform.auto.tfvars.json etc.
  if [[ -x "${SCRIPT_DIR}/06-archive-run.sh" ]]; then
    "${SCRIPT_DIR}/06-archive-run.sh" --status failed --upload || \
      "${SCRIPT_DIR}/06-archive-run.sh" --status failed || true
  fi
  echo "  Recovery procedure:"
  echo "    1. ./scripts/99-cleanup.sh  — archives then destroys partial resources"
  echo "    2. Diagnose the root cause (see docs/troubleshooting.md)"
  echo "    3. ./scripts/02-create-install-config.sh  — regenerate install-config"
  echo "    4. ./scripts/03-install-sno.sh  — retry"
  echo ""
  echo "  See docs/troubleshooting.md for common failure modes."
  echo "  See archives/INDEX.json for how many times this lab has been reproduced."
  exit "${INSTALL_EXIT}"
fi
