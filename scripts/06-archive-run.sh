#!/usr/bin/env bash
# 06-archive-run.sh
# Archive installer artifacts from openshift/ into archives/runs/ (gitignored).
# Optionally upload a tarball to the existing Cloud Shell storage account.
#
# Does NOT commit or push anything.
# Safe to run before cleanup / before retrying create cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${REPO_ROOT}/openshift"
ARCHIVE_ROOT="${REPO_ROOT}/archives"
RUNS_DIR="${ARCHIVE_ROOT}/runs"
INDEX_FILE="${ARCHIVE_ROOT}/INDEX.json"

# Existing cheap storage (Cloud Shell SA — no new resources)
AZURE_STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-cs110032003f4f3399f}"
AZURE_STORAGE_CONTAINER="${AZURE_STORAGE_CONTAINER:-ocp-sno-lab}"
AZURE_STORAGE_PREFIX="${AZURE_STORAGE_PREFIX:-archives}"

STATUS="snapshot"
UPLOAD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS="${2:-snapshot}"; shift 2 ;;
    --upload) UPLOAD=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--status success|failed|destroyed|snapshot] [--upload]"
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
ok()   { echo -e "${GREEN}  OK${NC}  $1"; }
warn() { echo -e "${YELLOW}  WARN${NC}  $1"; }
info() { echo "        $1"; }

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_ID="${TIMESTAMP}-${STATUS}"
DEST="${RUNS_DIR}/${RUN_ID}"

mkdir -p "${DEST}"

echo "========================================"
echo " Archive lab run artifacts"
echo " $(date)"
echo "========================================"
echo ""
info "Run ID : ${RUN_ID}"
info "Source : ${INSTALL_DIR}"
info "Dest   : ${DEST}"
echo ""

# --- Collect metadata ---
CLUSTER_NAME="unknown"
BASE_DOMAIN="unknown"
AZURE_REGION="unknown"
INFRA_ID="unknown"

if [[ -f "${INSTALL_DIR}/install-config.yaml.bak" ]]; then
  CLUSTER_NAME=$(grep '^  name:' "${INSTALL_DIR}/install-config.yaml.bak" | head -1 | awk '{print $2}' || echo unknown)
  BASE_DOMAIN=$(grep '^baseDomain:' "${INSTALL_DIR}/install-config.yaml.bak" | awk '{print $2}' || echo unknown)
  AZURE_REGION=$(grep 'region:' "${INSTALL_DIR}/install-config.yaml.bak" | head -1 | awk '{print $2}' || echo unknown)
elif [[ -f "${INSTALL_DIR}/install-config.yaml" ]]; then
  CLUSTER_NAME=$(grep '^  name:' "${INSTALL_DIR}/install-config.yaml" | head -1 | awk '{print $2}' || echo unknown)
  BASE_DOMAIN=$(grep '^baseDomain:' "${INSTALL_DIR}/install-config.yaml" | awk '{print $2}' || echo unknown)
  AZURE_REGION=$(grep 'region:' "${INSTALL_DIR}/install-config.yaml" | head -1 | awk '{print $2}' || echo unknown)
fi

if [[ -f "${INSTALL_DIR}/metadata.json" ]]; then
  INFRA_ID=$(jq -r '.infraID // "unknown"' "${INSTALL_DIR}/metadata.json" 2>/dev/null || echo unknown)
fi

# --- Copy artifacts (skip tracked templates) ---
COPIED=0
SKIP_NAMES=("README.md" "install-config.yaml.example")

shopt -s nullglob dotglob
for path in "${INSTALL_DIR}"/*; do
  base=$(basename "${path}")
  skip=false
  for s in "${SKIP_NAMES[@]}"; do
    [[ "${base}" == "${s}" ]] && skip=true && break
  done
  if [[ "${skip}" == "true" ]]; then
    continue
  fi
  # Redact pull secret from install-config copies when archiving
  if [[ "${base}" == "install-config.yaml" || "${base}" == "install-config.yaml.bak" ]]; then
    # Copy structure but scrub pullSecret value
    sed -E "s/^(pullSecret: ).*/\1'REDACTED'/" "${path}" > "${DEST}/${base}"
    chmod 600 "${DEST}/${base}" 2>/dev/null || true
    COPIED=$((COPIED + 1))
    continue
  fi
  cp -a "${path}" "${DEST}/"
  COPIED=$((COPIED + 1))
done
shopt -u nullglob dotglob

# Write MANIFEST
cat > "${DEST}/MANIFEST.json" <<EOF
{
  "run_id": "${RUN_ID}",
  "status": "${STATUS}",
  "archived_at": "$(date -Iseconds)",
  "cluster_name": "${CLUSTER_NAME}",
  "base_domain": "${BASE_DOMAIN}",
  "azure_region": "${AZURE_REGION}",
  "infra_id": "${INFRA_ID}",
  "artifacts_copied": ${COPIED},
  "source_dir": "openshift/",
  "notes": "Local archive only. Never commit. Optional Azure blob upload uses existing Cloud Shell storage."
}
EOF

ok "Archived ${COPIED} item(s) → archives/runs/${RUN_ID}/"

# --- Update INDEX.json (run counter) ---
if [[ ! -f "${INDEX_FILE}" ]]; then
  echo '{"total_runs":0,"runs":[]}' > "${INDEX_FILE}"
fi

TMP_INDEX=$(mktemp)
jq --arg id "${RUN_ID}" \
   --arg status "${STATUS}" \
   --arg ts "$(date -Iseconds)" \
   --arg cluster "${CLUSTER_NAME}" \
   --arg domain "${BASE_DOMAIN}" \
   --arg infra "${INFRA_ID}" \
   --argjson n "${COPIED}" \
   '.total_runs += 1
    | .runs += [{
        "run_id": $id,
        "status": $status,
        "archived_at": $ts,
        "cluster_name": $cluster,
        "base_domain": $domain,
        "infra_id": $infra,
        "artifacts_copied": $n
      }]
    | .last_run_id = $id
    | .last_status = $status' \
   "${INDEX_FILE}" > "${TMP_INDEX}"
mv "${TMP_INDEX}" "${INDEX_FILE}"

TOTAL=$(jq -r '.total_runs' "${INDEX_FILE}")
ok "INDEX updated — total lab runs archived: ${TOTAL}"
info "Index: archives/INDEX.json (gitignored)"

# --- Optional upload to existing Azure storage ---
if [[ "${UPLOAD}" == "true" ]]; then
  echo ""
  info "Uploading tarball to ${AZURE_STORAGE_ACCOUNT}/${AZURE_STORAGE_CONTAINER}/${AZURE_STORAGE_PREFIX}/"
  TARBALL="${ARCHIVE_ROOT}/${RUN_ID}.tar.gz"
  tar -C "${RUNS_DIR}" -czf "${TARBALL}" "${RUN_ID}"

  if az storage blob upload \
      --account-name "${AZURE_STORAGE_ACCOUNT}" \
      --container-name "${AZURE_STORAGE_CONTAINER}" \
      --name "${AZURE_STORAGE_PREFIX}/${RUN_ID}.tar.gz" \
      --file "${TARBALL}" \
      --auth-mode login \
      --overwrite true \
      --only-show-errors &>/dev/null; then
    ok "Uploaded: ${AZURE_STORAGE_PREFIX}/${RUN_ID}.tar.gz"
    # Also upload INDEX for remote visibility of run count
    az storage blob upload \
      --account-name "${AZURE_STORAGE_ACCOUNT}" \
      --container-name "${AZURE_STORAGE_CONTAINER}" \
      --name "${AZURE_STORAGE_PREFIX}/INDEX.json" \
      --file "${INDEX_FILE}" \
      --auth-mode login \
      --overwrite true \
      --only-show-errors &>/dev/null || true
    ok "Uploaded: ${AZURE_STORAGE_PREFIX}/INDEX.json"
  else
    warn "Blob upload failed — archive remains local only"
    warn "Try: az login && re-run with --upload"
  fi
fi

echo ""
echo "  List local runs:"
echo "    ls archives/runs/"
echo "    jq . archives/INDEX.json"
echo ""
echo "  This archive is gitignored. Do not commit it."
echo ""
