#!/usr/bin/env bash
# 05-validate-cluster.sh
# Comprehensive SNO cluster health validation.
# Produces a readable validation report.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${REPO_ROOT}/openshift"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass()    { echo -e "${GREEN}  PASS${NC}  $1"; PASS=$((PASS + 1)); }
fail()    { echo -e "${RED}  FAIL${NC}  $1"; FAIL=$((FAIL + 1)); }
warn()    { echo -e "${YELLOW}  WARN${NC}  $1"; WARN=$((WARN + 1)); }
info()    { echo "        $1"; }
section() { echo ""; echo -e "${BLUE}[ $1 ]${NC}"; }

echo "========================================"
echo " SNO Cluster Validation"
echo " $(date)"
echo "========================================"

# --- KUBECONFIG ---
section "kubeconfig"

if [[ -n "${KUBECONFIG:-}" ]] && [[ -f "${KUBECONFIG}" ]]; then
  pass "KUBECONFIG set: ${KUBECONFIG}"
elif [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
  export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
  pass "kubeconfig loaded from ${INSTALL_DIR}/auth/kubeconfig"
else
  fail "kubeconfig not found. Set KUBECONFIG or run from the installer directory."
  exit 1
fi

# --- API connectivity ---
section "API connectivity"

if oc whoami &>/dev/null; then
  WHO=$(oc whoami)
  pass "oc whoami: ${WHO}"
  if [[ "${WHO}" == "system:admin" ]]; then
    info "Identity is system:admin (expected)"
  else
    warn "Identity is '${WHO}' — expected 'system:admin' with kubeconfig"
  fi
else
  fail "Cannot connect to OpenShift API"
  info "Check: oc cluster-info"
  info "Check: curl -k https://api.<cluster>.<domain>:6443/healthz"
  exit 1
fi

# --- Nodes ---
section "Node status"

NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
info "Total nodes: ${NODE_COUNT}"

if [[ "${NODE_COUNT}" -eq 1 ]]; then
  pass "Node count: 1 (expected for SNO)"
elif [[ "${NODE_COUNT}" -eq 0 ]]; then
  fail "No nodes found"
else
  warn "Node count: ${NODE_COUNT} (expected 1 for SNO)"
fi

# Check node is Ready
NOT_READY=$(oc get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l | tr -d ' ')
if [[ "${NOT_READY}" -eq 0 ]]; then
  pass "All nodes are Ready"
else
  fail "${NOT_READY} node(s) are not Ready"
  oc get nodes
fi

# Check node roles
NODE_ROLES=$(oc get nodes --no-headers -o custom-columns="NAME:.metadata.name,ROLES:.metadata.labels" 2>/dev/null | head -5 || echo "")
CONTROL_PLANE_COUNT=$(oc get nodes -l "node-role.kubernetes.io/master" --no-headers 2>/dev/null | wc -l | tr -d ' ')
WORKER_ONLY_COUNT=$(oc get nodes -l "node-role.kubernetes.io/worker,!node-role.kubernetes.io/master" --no-headers 2>/dev/null | wc -l | tr -d ' ')

info "Control plane nodes: ${CONTROL_PLANE_COUNT}"
info "Worker-only nodes  : ${WORKER_ONLY_COUNT}"

if [[ "${CONTROL_PLANE_COUNT}" -eq 1 ]]; then
  pass "Control plane node count: 1 (expected for SNO)"
else
  fail "Control plane node count: ${CONTROL_PLANE_COUNT} (expected 1)"
fi

if [[ "${WORKER_ONLY_COUNT}" -eq 0 ]]; then
  pass "No worker-only nodes (expected for SNO — control plane is schedulable)"
else
  warn "Worker-only node count: ${WORKER_ONLY_COUNT} (expected 0 for SNO)"
fi

echo ""
info "Node details:"
oc get nodes -o wide --no-headers | while read -r line; do
  info "  ${line}"
done

# --- ClusterVersion ---
section "ClusterVersion"

CV_AVAILABLE=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
CV_PROGRESSING=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || echo "Unknown")
CV_DEGRADED=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
CV_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "Unknown")

info "Version     : ${CV_VERSION}"
info "Available   : ${CV_AVAILABLE}"
info "Progressing : ${CV_PROGRESSING}"
info "Degraded    : ${CV_DEGRADED}"

if [[ "${CV_AVAILABLE}" == "True" ]]; then
  pass "ClusterVersion Available: True"
else
  fail "ClusterVersion Available: ${CV_AVAILABLE}"
fi

if [[ "${CV_PROGRESSING}" == "False" ]]; then
  pass "ClusterVersion Progressing: False"
else
  warn "ClusterVersion still progressing — cluster may still be settling"
fi

if [[ "${CV_DEGRADED}" == "False" ]]; then
  pass "ClusterVersion Degraded: False"
else
  fail "ClusterVersion Degraded: True"
  oc get clusterversion version -o jsonpath='{.status.conditions}' | jq -r '.[] | select(.type=="Degraded") | .message' 2>/dev/null | head -5 | while read -r msg; do
    info "  ${msg}"
  done
fi

# --- ClusterOperators ---
section "ClusterOperators"

TOTAL_CO=$(oc get co --no-headers 2>/dev/null | wc -l | tr -d ' ')
DEGRADED_CO=$(oc get co --no-headers 2>/dev/null | awk '$5 == "True"' | wc -l | tr -d ' ')
UNAVAILABLE_CO=$(oc get co --no-headers 2>/dev/null | awk '$3 == "False"' | wc -l | tr -d ' ')
PROGRESSING_CO=$(oc get co --no-headers 2>/dev/null | awk '$4 == "True"' | wc -l | tr -d ' ')

info "Total operators    : ${TOTAL_CO}"
info "Degraded           : ${DEGRADED_CO}"
info "Unavailable        : ${UNAVAILABLE_CO}"
info "Still progressing  : ${PROGRESSING_CO}"

if [[ "${DEGRADED_CO}" -eq 0 ]]; then
  pass "No degraded ClusterOperators"
else
  fail "${DEGRADED_CO} degraded ClusterOperator(s):"
  oc get co --no-headers | awk '$5 == "True" {print "    DEGRADED: " $1}' | while read -r line; do
    info "${line}"
  done
fi

if [[ "${UNAVAILABLE_CO}" -eq 0 ]]; then
  pass "All ClusterOperators available"
else
  fail "${UNAVAILABLE_CO} ClusterOperator(s) unavailable:"
  oc get co --no-headers | awk '$3 == "False" {print "    UNAVAILABLE: " $1}' | while read -r line; do
    info "${line}"
  done
fi

if [[ "${PROGRESSING_CO}" -gt 0 ]]; then
  warn "${PROGRESSING_CO} ClusterOperator(s) still progressing (may settle after a few minutes)"
fi

# --- DNS verification ---
section "DNS resolution"

# Extract cluster info from kubeconfig
API_URL=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
if [[ -n "${API_URL}" ]]; then
  API_HOST=$(echo "${API_URL}" | sed 's|https://||' | cut -d: -f1)
  info "API endpoint: ${API_URL}"

  if command -v dig &>/dev/null; then
    API_IP=$(dig A "${API_HOST}" +short 2>/dev/null | head -1 || echo "")
    if [[ -n "${API_IP}" ]]; then
      pass "API hostname resolves: ${API_HOST} → ${API_IP}"
    else
      fail "API hostname does not resolve: ${API_HOST}"
      info "Check DNS propagation: dig A ${API_HOST}"
    fi
  else
    if host "${API_HOST}" &>/dev/null 2>&1; then
      pass "API hostname resolves: ${API_HOST}"
    else
      warn "Cannot verify DNS resolution (dig not available, host command failed)"
    fi
  fi
fi

# --- Ingress ---
section "Ingress and console"

INGRESS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [[ -n "${INGRESS_DOMAIN}" ]]; then
  pass "Ingress domain configured: ${INGRESS_DOMAIN}"
  CONSOLE_URL="https://console-openshift-console.${INGRESS_DOMAIN}"
  info "Console URL: ${CONSOLE_URL}"

  # Test console reachability
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "${CONSOLE_URL}" --max-time 15 2>/dev/null || echo "000")
  if [[ "${HTTP_CODE}" == "200" ]] || [[ "${HTTP_CODE}" == "307" ]] || [[ "${HTTP_CODE}" == "302" ]]; then
    pass "Console reachable (HTTP ${HTTP_CODE}): ${CONSOLE_URL}"
  elif [[ "${HTTP_CODE}" == "000" ]]; then
    warn "Console did not respond (timeout or DNS not propagated yet): ${CONSOLE_URL}"
    info "If DNS just propagated, wait a few minutes and retry"
  else
    warn "Console returned HTTP ${HTTP_CODE}: ${CONSOLE_URL}"
  fi

  # Test API external endpoint
  API_HEALTHZ=$(curl -sk -o /dev/null -w "%{http_code}" "${API_URL}/healthz" --max-time 10 2>/dev/null || echo "000")
  if [[ "${API_HEALTHZ}" == "200" ]]; then
    pass "API /healthz reachable (HTTP 200)"
  else
    warn "API /healthz returned HTTP ${API_HEALTHZ}"
  fi
else
  warn "Could not determine ingress domain"
fi

# --- Node resources ---
section "Node resources"

if oc adm top node --no-headers &>/dev/null 2>&1; then
  NODE_RESOURCES=$(oc adm top node --no-headers 2>/dev/null || echo "")
  if [[ -n "${NODE_RESOURCES}" ]]; then
    pass "Node resource metrics available"
    info ""
    info "$(oc adm top node 2>/dev/null)"
  fi
else
  warn "oc adm top node unavailable — metrics-server may still be starting"
fi

# Check node disk via describe
NODE_NAME=$(oc get nodes --no-headers -o custom-columns="NAME:.metadata.name" 2>/dev/null | head -1)
if [[ -n "${NODE_NAME}" ]]; then
  DISK_PRESSURE=$(oc get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "Unknown")
  MEM_PRESSURE=$(oc get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="MemoryPressure")].status}' 2>/dev/null || echo "Unknown")

  if [[ "${DISK_PRESSURE}" == "False" ]]; then
    pass "Node DiskPressure: False"
  else
    warn "Node DiskPressure: ${DISK_PRESSURE}"
  fi

  if [[ "${MEM_PRESSURE}" == "False" ]]; then
    pass "Node MemoryPressure: False"
  else
    warn "Node MemoryPressure: ${MEM_PRESSURE}"
  fi
fi

# --- Pods ---
section "Critical system pods"

NOT_RUNNING=$(oc get pods -A --no-headers 2>/dev/null | grep -v "Running\|Completed\|Succeeded" | wc -l | tr -d ' ')
TOTAL_PODS=$(oc get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

info "Total pods: ${TOTAL_PODS}"
info "Non-running/completed: ${NOT_RUNNING}"

if [[ "${NOT_RUNNING}" -eq 0 ]]; then
  pass "All pods are Running or Completed"
elif [[ "${NOT_RUNNING}" -le 5 ]]; then
  warn "${NOT_RUNNING} pod(s) not Running/Completed (may be starting)"
  oc get pods -A --no-headers 2>/dev/null | grep -v "Running\|Completed\|Succeeded" | head -10 | while read -r line; do
    info "  ${line}"
  done
else
  fail "${NOT_RUNNING} pod(s) not Running/Completed:"
  oc get pods -A --no-headers 2>/dev/null | grep -v "Running\|Completed\|Succeeded" | head -20 | while read -r line; do
    info "  ${line}"
  done
fi

# --- kubeadmin password ---
section "Cluster credentials"

if [[ -f "${INSTALL_DIR}/auth/kubeadmin-password" ]]; then
  pass "kubeadmin-password file found"
  info "Location: ${INSTALL_DIR}/auth/kubeadmin-password"
  info "Console login: kubeadmin / <password from file above>"
else
  warn "kubeadmin-password not found at ${INSTALL_DIR}/auth/kubeadmin-password"
fi

# --- Summary report ---
echo ""
echo "========================================"
echo " VALIDATION REPORT — $(date)"
echo "========================================"
echo ""
echo -e "  ${GREEN}PASS: ${PASS}${NC}   ${RED}FAIL: ${FAIL}${NC}   ${YELLOW}WARN: ${WARN}${NC}"
echo ""

if [[ "${FAIL}" -eq 0 ]] && [[ "${WARN}" -le 2 ]]; then
  echo -e "${GREEN}  STATUS: PASS${NC}"
  echo ""
  echo "  SNO cluster is healthy."
  echo ""
  if [[ -n "${INGRESS_DOMAIN:-}" ]]; then
    echo "  Console: https://console-openshift-console.${INGRESS_DOMAIN}"
  fi
  echo "  kubeadmin password: cat ${INSTALL_DIR}/auth/kubeadmin-password"
  echo ""
  echo "Next step: deploy the nginx demo application"
  echo "  cd examples/nginx/ && oc new-project sno-demo && oc apply -f ."
elif [[ "${FAIL}" -eq 0 ]]; then
  echo -e "${YELLOW}  STATUS: PASS WITH WARNINGS${NC}"
  echo ""
  echo "  Cluster is operational but review the warnings above."
elif [[ "${FAIL}" -le 2 ]]; then
  echo -e "${YELLOW}  STATUS: NEEDS ATTENTION${NC}"
  echo ""
  echo "  Some checks failed. Review failures above."
  echo "  The cluster may still be settling. Wait 10 minutes and re-run."
else
  echo -e "${RED}  STATUS: FAIL${NC}"
  echo ""
  echo "  Multiple checks failed. Review failures above."
  echo "  See docs/troubleshooting.md for remediation steps."
  exit 1
fi
