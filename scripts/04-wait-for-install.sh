#!/usr/bin/env bash
# 04-wait-for-install.sh
# Monitor an in-progress OpenShift installation.
# Use this if 03-install-sno.sh was backgrounded or disconnected.

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
fail()  { echo -e "${RED}  ERROR${NC}  $1"; }
warn()  { echo -e "${YELLOW}  WARN${NC}  $1"; }

echo "========================================"
echo " OpenShift installation monitor"
echo " $(date)"
echo "========================================"

# --- Check for installation directory ---
if [[ ! -d "${INSTALL_DIR}" ]]; then
  fail "Installation directory not found: ${INSTALL_DIR}"
  echo "  Run ./scripts/03-install-sno.sh first."
  exit 1
fi

LOG_FILE="${INSTALL_DIR}/.openshift_install.log"
STATE_FILE="${INSTALL_DIR}/.openshift_install_state.json"

if [[ ! -f "${STATE_FILE}" ]]; then
  fail "No installation state found at ${STATE_FILE}"
  echo "  Either installation has not started, or the directory was cleaned."
  exit 1
fi

echo ""
info "Installation directory: ${INSTALL_DIR}"
info "Log file: ${LOG_FILE}"
echo ""

# --- Show current installation state summary ---
if [[ -f "${LOG_FILE}" ]]; then
  echo -e "${BLUE}─── Last 20 lines of installation log ───${NC}"
  tail -20 "${LOG_FILE}"
  echo -e "${BLUE}─────────────────────────────────────────${NC}"
  echo ""
fi

# --- Check if install is still running ---
if pgrep -f "openshift-install create cluster" &>/dev/null; then
  INSTALL_PID=$(pgrep -f "openshift-install create cluster" | head -1)
  warn "openshift-install is still running (PID: ${INSTALL_PID})"
  echo ""
  echo "  Options:"
  echo "    Follow log:    tail -f ${LOG_FILE}"
  echo "    Watch summary: watch -n30 'tail -5 ${LOG_FILE}'"
  echo ""
  echo "  Attaching to installer to wait for completion..."
  echo ""
  openshift-install wait-for install-complete \
    --dir "${INSTALL_DIR}" \
    --log-level=info
  WAIT_EXIT=$?
else
  # Install is not running — check if it completed or failed
  if [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
    ok "Installation appears to have completed (kubeconfig found)"
  else
    warn "openshift-install is not running and kubeconfig is absent"
    echo ""
    echo "  Check the log for errors:"
    echo "    grep -i 'error\|fatal\|failed' ${LOG_FILE} | tail -20"
    echo ""
    echo "  Attempting to wait for completion (in case install is in a late stage)..."
    openshift-install wait-for install-complete \
      --dir "${INSTALL_DIR}" \
      --log-level=info || true
  fi
fi

# --- Check result ---
echo ""
if [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
  echo -e "${GREEN}========================================"
  echo " Installation complete"
  echo -e "========================================${NC}"
  echo ""
  info "kubeconfig : ${INSTALL_DIR}/auth/kubeconfig"
  info "password   : ${INSTALL_DIR}/auth/kubeadmin-password"
  echo ""
  CLUSTER_NAME=$(grep '^  name:' "${INSTALL_DIR}/install-config.yaml.bak" 2>/dev/null | head -1 | awk '{print $2}' || echo "sno")
  BASE_DOMAIN=$(grep '^baseDomain:' "${INSTALL_DIR}/install-config.yaml.bak" 2>/dev/null | awk '{print $2}' || echo "")
  if [[ -n "${BASE_DOMAIN}" ]]; then
    info "API     : https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
    info "Console : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
  fi
  echo ""
  echo "Next step: export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig && ./scripts/05-validate-cluster.sh"
else
  echo -e "${RED}========================================"
  echo " Installation did not complete"
  echo -e "========================================${NC}"
  echo ""
  echo "  Review errors:"
  echo "    grep -iE 'error|fatal|failed|timeout' ${LOG_FILE} | tail -30"
  echo ""
  echo "  Azure resources status:"
  echo "    az group list --query \"[?contains(name, 'sno')]\" -o table"
  echo ""
  echo "  If installation cannot recover:"
  echo "    ./scripts/99-cleanup.sh"
  exit 1
fi
