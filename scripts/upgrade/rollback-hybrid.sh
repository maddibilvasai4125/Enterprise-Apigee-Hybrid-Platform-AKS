#!/usr/bin/env bash
# =============================================================================
# rollback-hybrid.sh
# Purpose : Roll back Apigee Hybrid to a previous Helm release revision
#           with post-rollback health check and Cassandra restore option.
#
# Usage   : ./rollback-hybrid.sh --version 1.14.4 --region east
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════ $* ══════════${NC}"; }

VERSION=""
REGION=""
NAMESPACE="apigee"
RELEASE_NAME="apigee-hybrid"

while [[ $# -gt 0 ]]; do
  case $1 in
    --version)   VERSION="$2";   shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$VERSION" ]] && { error "--version required"; exit 1; }
[[ -z "$REGION"  ]] && { error "--region required";  exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="${SCRIPT_DIR}/../health-check/component-health-check.sh"

# ── Find target Helm revision ─────────────────────────────────────────────────
section "Identifying Rollback Target"
info "Helm release history for $RELEASE_NAME:"
helm history "$RELEASE_NAME" -n "$NAMESPACE" --max 10

TARGET_REVISION=$(helm history "$RELEASE_NAME" -n "$NAMESPACE" \
  --output json 2>/dev/null | \
  jq -r ".[] | select(.app_version==\"${VERSION}\") | .revision" | \
  tail -1)

if [[ -z "$TARGET_REVISION" ]]; then
  warn "Could not find exact revision for version $VERSION."
  warn "Rolling back to previous revision (revision - 1)..."
  CURRENT=$(helm history "$RELEASE_NAME" -n "$NAMESPACE" --output json | jq -r 'last.revision')
  TARGET_REVISION=$((CURRENT - 1))
fi

info "Rolling back to revision: $TARGET_REVISION (version: $VERSION)"

# ── Rollback ──────────────────────────────────────────────────────────────────
section "Executing Helm Rollback to Revision $TARGET_REVISION"
helm rollback "$RELEASE_NAME" "$TARGET_REVISION" \
  --namespace "$NAMESPACE" \
  --wait \
  --timeout 15m
info "Helm rollback completed."

# ── Also rollback Operator / CRDs ─────────────────────────────────────────────
section "Rolling Back Apigee Operator to v${VERSION}"
helm upgrade apigee-operator apigee/apigee-operator \
  --namespace apigee-system \
  --version "$VERSION" \
  --atomic \
  --timeout 10m
info "Operator rolled back to $VERSION"

# ── Post-Rollback Health Check ────────────────────────────────────────────────
section "Post-Rollback Health Check"
"$HEALTH_CHECK" --namespace "$NAMESPACE" || {
  error "Health check failed after rollback. Manual intervention required."
  error "Escalate to on-call SRE. Check Cassandra consistency and pod events."
  exit 1
}

section "Rollback Complete"
info "Apigee Hybrid rolled back to version: $VERSION"
info "Region: ${REGION^^}"
warn "ACTION REQUIRED: Open incident ticket and document root cause."
warn "ACTION REQUIRED: If Cassandra data is suspect, run cassandra-restore.sh."
