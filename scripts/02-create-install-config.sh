#!/usr/bin/env bash
# 02-create-install-config.sh
# Generate openshift/install-config.yaml from the example template.
# Reads secrets from environment variables — never prints or commits them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo "  $1"; }
ok()    { echo -e "${GREEN}  OK${NC}  $1"; }
fail()  { echo -e "${RED}  ERROR${NC}  $1"; exit 1; }
warn()  { echo -e "${YELLOW}  WARN${NC}  $1"; }

echo "========================================"
echo " Generate install-config.yaml"
echo " $(date)"
echo "========================================"

# --- Required environment variables ---
: "${PULL_SECRET:?ERROR: PULL_SECRET environment variable is not set. Get it from https://console.redhat.com/openshift/install/pull-secret}"
: "${SSH_PUBLIC_KEY_PATH:=${HOME}/.ssh/id_ed25519.pub}"

# --- Configurable cluster parameters ---
# Override any of these with environment variables before running this script.
CLUSTER_NAME="${CLUSTER_NAME:-sno}"
BASE_DOMAIN="${BASE_DOMAIN:-ocp.lab1.arunkube.org}"
AZURE_REGION="${AZURE_REGION:-eastus2}"
CONTROL_PLANE_VM="${CONTROL_PLANE_VM:-Standard_D8s_v3}"
CONTROL_PLANE_DISK_GB="${CONTROL_PLANE_DISK_GB:-128}"
DNS_RG="${DNS_RESOURCE_GROUP:-sno-dns-rg}"

echo ""
info "Cluster parameters:"
info "  Cluster name  : ${CLUSTER_NAME}"
info "  Base domain   : ${BASE_DOMAIN}"
info "  Azure region  : ${AZURE_REGION}"
info "  Control plane : ${CONTROL_PLANE_VM} (${CONTROL_PLANE_DISK_GB} GB disk)"
info "  DNS zone RG   : ${DNS_RG}"
info "  API endpoint  : api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
info "  Console       : https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo ""

# --- Validate pull secret (without printing it) ---
if ! echo "${PULL_SECRET}" | jq -e '.auths' &>/dev/null 2>&1; then
  fail "PULL_SECRET does not look like valid JSON with .auths key. Check https://console.redhat.com/openshift/install/pull-secret"
fi
ok "PULL_SECRET is valid JSON"

# --- Validate SSH public key ---
if [[ ! -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
  fail "SSH public key not found at: ${SSH_PUBLIC_KEY_PATH}
  Generate one with: ssh-keygen -t ed25519 -C 'ocp-sno'
  Or set: export SSH_PUBLIC_KEY_PATH=~/.ssh/your_key.pub"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_PUBLIC_KEY_PATH}")
ok "SSH public key loaded from ${SSH_PUBLIC_KEY_PATH}"

# --- Check for existing install-config ---
OUTPUT_FILE="${REPO_ROOT}/openshift/install-config.yaml"

if [[ -f "${OUTPUT_FILE}" ]]; then
  warn "install-config.yaml already exists at: ${OUTPUT_FILE}"
  read -rp "  Overwrite? (yes/no): " OVERWRITE
  if [[ "${OVERWRITE}" != "yes" ]]; then
    echo "Aborted. Existing install-config.yaml preserved."
    exit 0
  fi
fi

# --- Check output directory ---
mkdir -p "${REPO_ROOT}/openshift"

# --- Generate install-config.yaml ---
# The pull secret is injected via shell substitution — not stored in a temp file.
cat > "${OUTPUT_FILE}" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  hyperthreading: Enabled
  name: master
  platform:
    azure:
      type: ${CONTROL_PLANE_VM}
      osDisk:
        diskSizeGB: ${CONTROL_PLANE_DISK_GB}
        diskType: premium_LRS
  replicas: 1
compute:
- hyperthreading: Enabled
  name: worker
  platform:
    azure:
      type: Standard_D4s_v3
  replicas: 0
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  azure:
    baseDomainResourceGroupName: ${DNS_RG}
    region: ${AZURE_REGION}
pullSecret: '${PULL_SECRET}'
sshKey: |
  ${SSH_PUBLIC_KEY}
EOF

ok "install-config.yaml written to: ${OUTPUT_FILE}"

# --- Set restrictive permissions ---
chmod 600 "${OUTPUT_FILE}"
ok "Permissions set to 600"

# --- Remind about backup ---
echo ""
echo -e "${YELLOW}IMPORTANT: Back up install-config.yaml before running openshift-install.${NC}"
echo "  openshift-install CONSUMES AND DELETES this file during installation."
echo "  Run:"
echo "    cp ${OUTPUT_FILE} ${OUTPUT_FILE}.bak"
echo ""
echo "  Do NOT commit install-config.yaml (it contains your pull secret)."
echo ""

# --- Offer to create backup automatically ---
read -rp "Create backup now? (yes/no): " CREATE_BACKUP
if [[ "${CREATE_BACKUP}" == "yes" ]]; then
  cp "${OUTPUT_FILE}" "${OUTPUT_FILE}.bak"
  chmod 600 "${OUTPUT_FILE}.bak"
  ok "Backup created: ${OUTPUT_FILE}.bak"
fi

echo ""
echo -e "${GREEN}install-config.yaml is ready.${NC}"
echo ""
echo "Review the configuration (without secrets):"
echo "  grep -v 'pullSecret\|sshKey' ${OUTPUT_FILE}"
echo ""
echo "Next step: ./scripts/03-install-sno.sh"
