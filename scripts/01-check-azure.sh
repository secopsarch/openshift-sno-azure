#!/usr/bin/env bash
# 01-check-azure.sh
# Verify Azure subscription, quota, region, and VM SKU availability.
# This script is read-only — it makes no changes to Azure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "${GREEN}  PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "${YELLOW}  WARN${NC}  $1"; WARN=$((WARN + 1)); }
info() { echo "        $1"; }
section() { echo ""; echo -e "${BLUE}[ $1 ]${NC}"; }

# Configurable defaults — override via environment variables
AZURE_REGION="${AZURE_REGION:-eastus2}"
VM_SKU="${VM_SKU:-Standard_D8s_v7}"
MIN_VCPU_REQUIRED=16  # bootstrap(8) + control-plane(8) during SNO installation

# Derive the quota family name from the VM SKU.
# Standard_D8s_v7 → "Standard Dsv7 Family vCPUs"
# Standard_D8s_v3 → "Standard DSv3 Family vCPUs"
# Override with QUOTA_FAMILY if the auto-derived name is wrong for your SKU.
_SKU_SUFFIX="${VM_SKU##*_v}"  # e.g. "7" from Standard_D8s_v7
QUOTA_FAMILY="${QUOTA_FAMILY:-Standard Dsv${_SKU_SUFFIX} Family vCPUs}"

echo "========================================"
echo " Azure preflight check"
echo " $(date)"
echo "========================================"
echo ""
echo "  Target region : ${AZURE_REGION}"
echo "  Target VM SKU : ${VM_SKU}"
echo "  vCPU required : ${MIN_VCPU_REQUIRED} (install peak)"
echo ""

# --- Authentication ---
section "Azure authentication"

if ! az account show &>/dev/null; then
  fail "Not logged in to Azure — run: az login"
  echo ""
  echo -e "${RED}Cannot continue without Azure authentication.${NC}"
  exit 1
fi

SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
pass "Authenticated to Azure"
info "Subscription : ${SUB_NAME}"
info "Subscription ID: ${SUB_ID}"
info "Tenant ID    : ${TENANT_ID}"

# --- Subscription state ---
section "Subscription state"

SUB_STATE=$(az account show --query state -o tsv)
if [[ "${SUB_STATE}" == "Enabled" ]]; then
  pass "Subscription state: ${SUB_STATE}"
else
  fail "Subscription state is '${SUB_STATE}' — must be 'Enabled'"
fi

# --- Region availability ---
section "Region availability: ${AZURE_REGION}"

if az account list-locations --query "[?name=='${AZURE_REGION}'].displayName" -o tsv 2>/dev/null | grep -q .; then
  REGION_DISPLAY=$(az account list-locations --query "[?name=='${AZURE_REGION}'].displayName" -o tsv)
  pass "Region ${AZURE_REGION} exists (${REGION_DISPLAY})"
else
  fail "Region '${AZURE_REGION}' not found — check region name with: az account list-locations -o table"
  exit 1
fi

# --- VM SKU availability ---
section "VM SKU availability: ${VM_SKU} in ${AZURE_REGION}"

SKU_INFO=$(az vm list-skus \
  --location "${AZURE_REGION}" \
  --size "${VM_SKU}" \
  --all \
  --query "[?name=='${VM_SKU}']" \
  -o json 2>/dev/null || echo "[]")

if [[ "${SKU_INFO}" == "[]" ]] || [[ -z "${SKU_INFO}" ]]; then
  fail "VM SKU '${VM_SKU}' not found in region '${AZURE_REGION}'"
  info "Check available D8s SKUs with:"
  info "  az vm list-skus --location ${AZURE_REGION} --query \"[?contains(name, 'D8s')]\" --output table"
else
  RESTRICTIONS=$(echo "${SKU_INFO}" | jq -r '.[0].restrictions // [] | length')
  if [[ "${RESTRICTIONS}" -eq 0 ]]; then
    pass "${VM_SKU} is available in ${AZURE_REGION} with no restrictions"
  else
    RESTRICTION_DETAILS=$(echo "${SKU_INFO}" | jq -r '.[0].restrictions[].reasonCode' 2>/dev/null || echo "unknown")
    if echo "${RESTRICTION_DETAILS}" | grep -q "NotAvailableForSubscription"; then
      fail "${VM_SKU} is restricted in ${AZURE_REGION} for this subscription (${RESTRICTION_DETAILS})"
      info "Try an alternative region or request quota increase in Azure portal"
      info "Alternative SKUs: Standard_D8s_v7, Standard_D8as_v7, Standard_D8s_v5"
    else
      warn "${VM_SKU} has restrictions in ${AZURE_REGION}: ${RESTRICTION_DETAILS}"
    fi
  fi
fi

# --- vCPU quota ---
section "vCPU quota: ${QUOTA_FAMILY} in ${AZURE_REGION}"

QUOTA_INFO=$(az vm list-usage \
  --location "${AZURE_REGION}" \
  --query "[?name.localizedValue=='${QUOTA_FAMILY}']" \
  -o json 2>/dev/null || echo "[]")

if [[ "${QUOTA_INFO}" == "[]" ]] || [[ -z "${QUOTA_INFO}" ]]; then
  warn "Could not retrieve '${QUOTA_FAMILY}' quota — check manually in Azure portal"
  info "Override the family name with: export QUOTA_FAMILY='<exact name from portal>'"
else
  QUOTA_CURRENT=$(echo "${QUOTA_INFO}" | jq -r '.[0].currentValue // 0')
  QUOTA_LIMIT=$(echo "${QUOTA_INFO}" | jq -r '.[0].limit // 0')
  QUOTA_AVAILABLE=$((QUOTA_LIMIT - QUOTA_CURRENT))

  info "Quota family : ${QUOTA_FAMILY}"
  info "Quota limit  : ${QUOTA_LIMIT} vCPU"
  info "Current usage: ${QUOTA_CURRENT} vCPU"
  info "Available    : ${QUOTA_AVAILABLE} vCPU"
  info "Required     : ${MIN_VCPU_REQUIRED} vCPU (during SNO installation)"

  if [[ "${QUOTA_AVAILABLE}" -ge "${MIN_VCPU_REQUIRED}" ]]; then
    pass "Sufficient vCPU quota: ${QUOTA_AVAILABLE} available, ${MIN_VCPU_REQUIRED} required"
  else
    fail "Insufficient vCPU quota: ${QUOTA_AVAILABLE} available, ${MIN_VCPU_REQUIRED} required"
    info "Request increase at: Azure portal → Subscriptions → Usage + quotas"
    info "Filter: '${QUOTA_FAMILY}' → Request increase → set to at least 20"
  fi
fi

# --- Public IP quota ---
section "Public IP quota in ${AZURE_REGION}"

PIP_INFO=$(az vm list-usage \
  --location "${AZURE_REGION}" \
  --query "[?name.localizedValue=='Public IP Addresses']" \
  -o json 2>/dev/null || echo "[]")

if [[ "${PIP_INFO}" != "[]" ]] && [[ -n "${PIP_INFO}" ]]; then
  PIP_CURRENT=$(echo "${PIP_INFO}" | jq -r '.[0].currentValue // 0')
  PIP_LIMIT=$(echo "${PIP_INFO}" | jq -r '.[0].limit // 0')
  PIP_AVAILABLE=$((PIP_LIMIT - PIP_CURRENT))
  info "Public IPs: ${PIP_CURRENT} used / ${PIP_LIMIT} limit (${PIP_AVAILABLE} available)"
  if [[ "${PIP_AVAILABLE}" -ge 3 ]]; then
    pass "Sufficient public IP quota: ${PIP_AVAILABLE} available, 3 required"
  else
    fail "Insufficient public IP quota: ${PIP_AVAILABLE} available, 3 required"
  fi
else
  warn "Could not retrieve Public IP quota"
fi

# --- DNS zone check ---
section "Azure DNS zone"

DNS_ZONE="${DNS_ZONE_NAME:-}"
DNS_RG="${DNS_RG_NAME:-sno-dns-rg}"

if [[ -z "${DNS_ZONE}" ]]; then
  warn "DNS_ZONE_NAME not set — skipping DNS zone check"
  info "Set it with: export DNS_ZONE_NAME=ocplab1.arunkube.org"
else
  if az network dns zone show \
      --resource-group "${DNS_RG}" \
      --name "${DNS_ZONE}" &>/dev/null 2>&1; then
    pass "DNS zone '${DNS_ZONE}' exists in resource group '${DNS_RG}'"

    # Check NS delegation if dig is available
    if command -v dig &>/dev/null; then
      NS_RESULT=$(dig NS "${DNS_ZONE}" @8.8.8.8 +short 2>/dev/null || echo "")
      if [[ -n "${NS_RESULT}" ]]; then
        pass "NS delegation for '${DNS_ZONE}' is resolving externally"
        info "Name servers: ${NS_RESULT}"
      else
        warn "NS delegation for '${DNS_ZONE}' is not yet resolving from 8.8.8.8"
        info "Add NS records to your parent zone and wait for propagation"
        info "See docs/dns.md for instructions"
      fi
    else
      warn "dig not available — cannot verify NS delegation"
      info "Verify manually: dig NS ${DNS_ZONE} @8.8.8.8 +short"
    fi
  else
    warn "DNS zone '${DNS_ZONE}' not found in resource group '${DNS_RG}'"
    info "Run terraform apply in terraform/ directory first"
  fi
fi

# --- Resource group check (pre-existing cluster RG) ---
section "Pre-existing cluster resource groups"

EXISTING_RGS=$(az group list \
  --query "[?contains(name, 'sno') && state=='Succeeded'].name" \
  -o tsv 2>/dev/null || echo "")

if [[ -z "${EXISTING_RGS}" ]]; then
  pass "No existing SNO resource groups found (clean state)"
else
  warn "Existing resource groups containing 'sno' found:"
  echo "${EXISTING_RGS}" | while read -r rg; do
    info "  ${rg}"
  done
  info "These may be from a previous install. Run 99-cleanup.sh to remove them."
fi

# --- Summary ---
echo ""
echo "========================================"
echo " Summary"
echo "========================================"
echo -e "  ${GREEN}PASS: ${PASS}${NC}   ${RED}FAIL: ${FAIL}${NC}   ${YELLOW}WARN: ${WARN}${NC}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
  echo -e "${RED}Azure preflight check FAILED. Fix the above issues before installing.${NC}"
  exit 1
elif [[ "${WARN}" -gt 0 ]]; then
  echo -e "${YELLOW}Azure preflight check PASSED with warnings. Review warnings above.${NC}"
  echo ""
  echo "Next step: terraform apply (in terraform/ directory)"
else
  echo -e "${GREEN}Azure preflight check PASSED.${NC}"
  echo ""
  echo "Next step: terraform apply (in terraform/ directory)"
fi
