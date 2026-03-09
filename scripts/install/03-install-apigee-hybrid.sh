#!/usr/bin/env bash
# =============================================================================
# 03-install-apigee-hybrid.sh
# Purpose : Install Apigee Hybrid via Helm on the target AKS cluster.
#           Handles chart repo setup, CRD installation, and full deployment
#           with atomic rollback on failure.
#
# Usage   : ./03-install-apigee-hybrid.sh \
#             --region  east \
#             --version 1.15.2
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════════${NC}"; \
            echo -e "${BLUE}  $*${NC}"; \
            echo -e "${BLUE}══════════════════════════════════════════${NC}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
REGION=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)  REGION="$2";  shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "$REGION"  ]] && error "--region is required  (east|west)"
[[ -z "$VERSION" ]] && error "--version is required (e.g. 1.15.2)"

COMMON_VALUES="../../helm/values-common.yaml"
REGION_VALUES="../../helm/overrides-${REGION}.yaml"
NAMESPACE="apigee"
RELEASE_NAME="apigee-hybrid"

[[ -f "$COMMON_VALUES" ]] || error "Common values not found: $COMMON_VALUES"
[[ -f "$REGION_VALUES" ]] || error "Region values not found: $REGION_VALUES"

# ── Helm Repo ─────────────────────────────────────────────────────────────────
section "Setting up Apigee Helm chart repository"
helm repo add apigee https://storage.googleapis.com/apigee-release/hybrid/apigee-operator/etc/charts \
  --force-update 2>/dev/null || warn "Repo already configured."
helm repo update
info "Helm repo updated."

# ── CRD Installation ──────────────────────────────────────────────────────────
section "Installing / upgrading Apigee CRDs"
helm upgrade --install apigee-operator apigee/apigee-operator \
  --namespace apigee-system \
  --version "$VERSION" \
  --atomic \
  --timeout 10m
info "Apigee operator/CRDs installed at version $VERSION"

# ── Dry Run ───────────────────────────────────────────────────────────────────
section "Performing Helm dry-run (validation)"
helm upgrade --install "$RELEASE_NAME" apigee/apigee \
  --namespace "$NAMESPACE" \
  --version "$VERSION" \
  -f "$COMMON_VALUES" \
  -f "$REGION_VALUES" \
  --dry-run \
  --timeout 15m
info "Dry-run passed — no validation errors."

# ── Full Install ──────────────────────────────────────────────────────────────
section "Installing Apigee Hybrid v${VERSION} in region: ${REGION^^}"
helm upgrade --install "$RELEASE_NAME" apigee/apigee \
  --namespace "$NAMESPACE" \
  --version "$VERSION" \
  -f "$COMMON_VALUES" \
  -f "$REGION_VALUES" \
  --atomic \
  --timeout 20m \
  --wait

info "Helm install complete. Waiting for pods to reach Running state..."

# ── Wait for Key Components ───────────────────────────────────────────────────
section "Waiting for Apigee components to become ready"
COMPONENTS=(
  "apigee-ingressgateway"
  "apigee-runtime"
  "apigee-synchronizer"
  "apigee-udca"
  "apigee-redis"
)

for COMPONENT in "${COMPONENTS[@]}"; do
  info "Waiting for: $COMPONENT"
  kubectl rollout status deployment \
    -l "app.kubernetes.io/component=${COMPONENT}" \
    -n "$NAMESPACE" \
    --timeout=10m || warn "$COMPONENT rollout timed out — check pod events."
done

# ── Post-Install Health Check ─────────────────────────────────────────────────
section "Running post-install component health check"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/../health-check/component-health-check.sh" \
  --cluster "$(kubectl config current-context)" \
  --namespace "$NAMESPACE"

section "Installation Complete"
info "Apigee Hybrid v${VERSION} is running in region: ${REGION^^}"
info "Run './scripts/health-check/component-health-check.sh' at any time to re-validate."
