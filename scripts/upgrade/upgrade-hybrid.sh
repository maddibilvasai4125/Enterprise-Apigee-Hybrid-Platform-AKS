#!/usr/bin/env bash
# =============================================================================
# upgrade-hybrid.sh
# Purpose : Safely upgrade Apigee Hybrid from one version to another using
#           Helm with rolling restarts, pre/post-upgrade validation, and
#           an automated rollback trigger on failure.
#
# Usage   : ./upgrade-hybrid.sh \
#             --from-version 1.14.4 \
#             --to-version   1.15.2 \
#             --region       east
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════ $* ══════════${NC}"; }

FROM_VERSION=""
TO_VERSION=""
REGION=""
NAMESPACE="apigee"
RELEASE_NAME="apigee-hybrid"

while [[ $# -gt 0 ]]; do
  case $1 in
    --from-version) FROM_VERSION="$2"; shift 2 ;;
    --to-version)   TO_VERSION="$2";   shift 2 ;;
    --region)       REGION="$2";       shift 2 ;;
    --namespace)    NAMESPACE="$2";    shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$FROM_VERSION" ]] && { error "--from-version required"; exit 1; }
[[ -z "$TO_VERSION"   ]] && { error "--to-version required";   exit 1; }
[[ -z "$REGION"       ]] && { error "--region required";       exit 1; }

COMMON_VALUES="../../helm/values-common.yaml"
REGION_VALUES="../../helm/overrides-${REGION}.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="${SCRIPT_DIR}/../health-check/component-health-check.sh"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
LOG_FILE="/tmp/apigee-upgrade-${REGION}-${TIMESTAMP}.log"

# ── Redirect all output to log ────────────────────────────────────────────────
exec > >(tee -a "$LOG_FILE") 2>&1
info "Upgrade log: $LOG_FILE"

# ── Pre-upgrade Validation ────────────────────────────────────────────────────
section "Pre-Upgrade Validation"
info "Running component health check on current version ($FROM_VERSION)..."
"$HEALTH_CHECK" --namespace "$NAMESPACE" || {
  error "Pre-upgrade health check FAILED. Do not proceed with upgrade."
  exit 1
}

# ── Cassandra Backup ──────────────────────────────────────────────────────────
section "Cassandra Pre-Upgrade Snapshot"
info "Triggering Cassandra backup (tag: pre-upgrade-${TIMESTAMP})..."
"${SCRIPT_DIR}/../cassandra/cassandra-backup.sh" \
  --tag "pre-upgrade-${FROM_VERSION}-${TIMESTAMP}" \
  --namespace "$NAMESPACE"

# ── Helm Diff ─────────────────────────────────────────────────────────────────
section "Helm Diff — Review Changes Before Applying"
if helm plugin list | grep -q "diff"; then
  helm diff upgrade "$RELEASE_NAME" apigee/apigee \
    --namespace "$NAMESPACE" \
    --version "$TO_VERSION" \
    -f "$COMMON_VALUES" \
    -f "$REGION_VALUES" \
    --color
else
  warn "helm-diff plugin not installed. Skipping diff. (Install: helm plugin install https://github.com/databus23/helm-diff)"
fi

# ── Confirmation Prompt ───────────────────────────────────────────────────────
echo ""
read -r -p "$(echo -e "${YELLOW}Proceed with upgrade from ${FROM_VERSION} to ${TO_VERSION} in region ${REGION^^}? [yes/no]: ${NC}")" CONFIRM
[[ "$CONFIRM" == "yes" ]] || { warn "Upgrade cancelled by user."; exit 0; }

# ── CRD / Operator Upgrade ────────────────────────────────────────────────────
section "Upgrading Apigee Operator and CRDs"
helm upgrade apigee-operator apigee/apigee-operator \
  --namespace apigee-system \
  --version "$TO_VERSION" \
  --atomic \
  --timeout 10m
info "Operator upgraded to $TO_VERSION"

# ── Main Helm Upgrade ─────────────────────────────────────────────────────────
section "Upgrading Apigee Hybrid: ${FROM_VERSION} → ${TO_VERSION}"

# Rolling upgrade strategy: disable --atomic here so we can handle rollback manually
# and avoid double-rollback of CRDs.
if helm upgrade "$RELEASE_NAME" apigee/apigee \
  --namespace "$NAMESPACE" \
  --version "$TO_VERSION" \
  -f "$COMMON_VALUES" \
  -f "$REGION_VALUES" \
  --timeout 20m \
  --wait; then
  info "Helm upgrade succeeded."
else
  error "Helm upgrade FAILED. Triggering automatic rollback..."
  "${SCRIPT_DIR}/rollback-hybrid.sh" \
    --version "$FROM_VERSION" \
    --region "$REGION"
  exit 1
fi

# ── Rolling Restarts ──────────────────────────────────────────────────────────
section "Rolling Restart of All Apigee Components"
# Force rolling restart to pick up any configmap/secret changes
DEPLOYMENTS=$(kubectl get deployment -n "$NAMESPACE" \
  -l "app.kubernetes.io/managed-by=Helm" \
  -o jsonpath='{.items[*].metadata.name}')

for DEPLOY in $DEPLOYMENTS; do
  info "Rolling restart: $DEPLOY"
  kubectl rollout restart deployment "$DEPLOY" -n "$NAMESPACE"
  kubectl rollout status  deployment "$DEPLOY" -n "$NAMESPACE" --timeout=10m
done

# ── Post-Upgrade Validation ───────────────────────────────────────────────────
section "Post-Upgrade Health Check"
"$HEALTH_CHECK" --namespace "$NAMESPACE" || {
  error "Post-upgrade health check FAILED. Initiating rollback..."
  "${SCRIPT_DIR}/rollback-hybrid.sh" --version "$FROM_VERSION" --region "$REGION"
  exit 1
}

section "Upgrade Complete"
info "Apigee Hybrid successfully upgraded: ${FROM_VERSION} → ${TO_VERSION}"
info "Region: ${REGION^^}"
info "Log saved to: $LOG_FILE"
info "Update Confluence runbook with: version=$TO_VERSION, date=$(date +%Y-%m-%d), region=$REGION"
