#!/usr/bin/env bash
# 00-check-prerequisites.sh
# Verify that all required CLI tools are installed and at minimum versions.
# This script is read-only — it makes no changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}  PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}  WARN${NC}  $1"; }
info() { echo "        $1"; }

echo "========================================"
echo " Prerequisites check"
echo " $(date)"
echo "========================================"
echo ""

# --- az (Azure CLI) ---
echo "[ Azure CLI ]"
if command -v az &>/dev/null; then
  AZ_VERSION=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "unknown")
  pass "az found — version ${AZ_VERSION}"
else
  fail "az not found — install from https://learn.microsoft.com/cli/azure/install-azure-cli"
fi

# --- terraform ---
echo ""
echo "[ Terraform ]"
if command -v terraform &>/dev/null; then
  TF_VERSION=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | head -1 | awk '{print $2}' | tr -d 'v')
  # Check >= 1.6
  TF_MAJOR=$(echo "${TF_VERSION}" | cut -d. -f1)
  TF_MINOR=$(echo "${TF_VERSION}" | cut -d. -f2)
  if [[ "${TF_MAJOR}" -gt 1 ]] || [[ "${TF_MAJOR}" -eq 1 && "${TF_MINOR}" -ge 6 ]]; then
    pass "terraform found — version ${TF_VERSION} (>= 1.6 required)"
  else
    fail "terraform version ${TF_VERSION} is below minimum 1.6 — upgrade from https://developer.hashicorp.com/terraform/install"
  fi
else
  fail "terraform not found — install from https://developer.hashicorp.com/terraform/install"
fi

# --- openshift-install ---
echo ""
echo "[ openshift-install ]"
if command -v openshift-install &>/dev/null; then
  OI_VERSION=$(openshift-install version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
  pass "openshift-install found — ${OI_VERSION}"
  # Check it's 4.22.x
  if echo "${OI_VERSION}" | grep -q "^4\.22\."; then
    info "Version matches target OCP 4.22"
  elif echo "${OI_VERSION}" | grep -qE "^4\.[2-9][0-9]|^[5-9]\."; then
    warn "openshift-install version ${OI_VERSION} — expected 4.22.x. Mismatched versions can cause issues."
  else
    warn "openshift-install version ${OI_VERSION} — could not confirm 4.22.x"
  fi
else
  fail "openshift-install not found"
  info "Install with:"
  info "  curl -L https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest-4.22/openshift-install-linux.tar.gz | tar -xz -C /usr/local/bin/ openshift-install"
fi

# --- oc ---
echo ""
echo "[ oc (OpenShift CLI) ]"
if command -v oc &>/dev/null; then
  OC_VERSION=$(oc version --client 2>/dev/null | grep "Client Version" | awk '{print $3}' || echo "unknown")
  pass "oc found — ${OC_VERSION}"
else
  fail "oc not found"
  info "Install with:"
  info "  curl -L https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest-4.22/openshift-client-linux.tar.gz | tar -xz -C /usr/local/bin/ oc"
fi

# --- jq ---
echo ""
echo "[ jq ]"
if command -v jq &>/dev/null; then
  JQ_VERSION=$(jq --version 2>/dev/null || echo "unknown")
  pass "jq found — ${JQ_VERSION}"
else
  fail "jq not found — install with: apt install jq  OR  brew install jq"
fi

# --- curl ---
echo ""
echo "[ curl ]"
if command -v curl &>/dev/null; then
  CURL_VERSION=$(curl --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
  pass "curl found — version ${CURL_VERSION}"
else
  fail "curl not found — install with: apt install curl"
fi

# --- ssh / ssh-keygen ---
echo ""
echo "[ SSH ]"
if command -v ssh &>/dev/null && command -v ssh-keygen &>/dev/null; then
  SSH_VERSION=$(ssh -V 2>&1 | awk '{print $1}' || echo "unknown")
  pass "ssh and ssh-keygen found — ${SSH_VERSION}"
else
  fail "ssh or ssh-keygen not found — install openssh-client"
fi

# --- dig (optional but useful) ---
echo ""
echo "[ dig (DNS check tool — optional) ]"
if command -v dig &>/dev/null; then
  pass "dig found"
else
  warn "dig not found — DNS verification in 01-check-azure.sh will be limited"
  info "Install with: apt install dnsutils  OR  brew install bind"
fi

# --- Environment variables ---
echo ""
echo "[ Environment variables ]"

if [[ -n "${PULL_SECRET:-}" ]]; then
  pass "PULL_SECRET is set"
  # Validate it looks like JSON without printing it
  if echo "${PULL_SECRET}" | jq -e '.auths' &>/dev/null 2>&1; then
    info "PULL_SECRET appears to be valid JSON with .auths key"
  else
    warn "PULL_SECRET is set but does not look like a valid pull secret JSON"
  fi
else
  warn "PULL_SECRET is not set — required before running 02-create-install-config.sh"
  info "Get it from: https://console.redhat.com/openshift/install/pull-secret"
  info "Then run: export PULL_SECRET='\$(cat ~/pull-secret.txt)'"
fi

if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" ]]; then
  if [[ -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
    pass "SSH_PUBLIC_KEY_PATH is set and file exists: ${SSH_PUBLIC_KEY_PATH}"
  else
    fail "SSH_PUBLIC_KEY_PATH is set but file not found: ${SSH_PUBLIC_KEY_PATH}"
  fi
else
  warn "SSH_PUBLIC_KEY_PATH is not set — will default to ~/.ssh/id_ed25519.pub"
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    info "Found ${HOME}/.ssh/id_ed25519.pub (default)"
  elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    info "Found ${HOME}/.ssh/id_rsa.pub — set SSH_PUBLIC_KEY_PATH to use it"
  else
    warn "No SSH public key found — generate one with: ssh-keygen -t ed25519 -C 'ocp-sno'"
  fi
fi

# --- Summary ---
echo ""
echo "========================================"
echo " Summary"
echo "========================================"
echo -e "  ${GREEN}PASS: ${PASS}${NC}   ${RED}FAIL: ${FAIL}${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo -e "${RED}Prerequisites check FAILED. Fix the above issues before continuing.${NC}"
  exit 1
else
  echo -e "${GREEN}All required tools are present.${NC}"
  echo ""
  echo "Next step: ./scripts/01-check-azure.sh"
fi
