#!/usr/bin/env bash
# =============================================================================
# 02-create-service-accounts.sh
# Purpose : Create GCP service accounts for all Apigee Hybrid components,
#           bind the minimum required IAM roles (least-privilege), and
#           create + stage Kubernetes Secrets from the generated key files.
#
# Usage   : ./02-create-service-accounts.sh \
#             --project my-gcp-project \
#             --org    my-apigee-org
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
PROJECT=""
ORG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT="$2"; shift 2 ;;
    --org)     ORG="$2";     shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "$PROJECT" ]] && error "--project is required"
[[ -z "$ORG"     ]] && error "--org is required"

KEY_DIR="./sa-keys"
mkdir -p "$KEY_DIR"

# ── Service Account Definitions ───────────────────────────────────────────────
# Format: "sa-short-name|display-name|space-separated-IAM-roles"
declare -A SA_ROLES
SA_ROLES["apigee-connect"]="apigee-connect-agent-sa|Apigee Connect Agent|roles/apigeeconnect.Agent"
SA_ROLES["apigee-sync"]="apigee-sync-sa|Apigee Synchronizer|roles/apigee.synchronizerManager"
SA_ROLES["apigee-udca"]="apigee-udca-sa|Apigee UDCA|roles/apigee.analyticsAgent"
SA_ROLES["apigee-metrics"]="apigee-metrics-sa|Apigee Metrics|roles/monitoring.metricWriter roles/logging.logWriter"
SA_ROLES["apigee-cassandra"]="apigee-cassandra-sa|Apigee Cassandra Backup|roles/storage.objectAdmin"
SA_ROLES["apigee-watcher"]="apigee-watcher-sa|Apigee Watcher|roles/apigee.runtimeAgent"

# ── Helper: create or skip ────────────────────────────────────────────────────
create_sa() {
  local SA_NAME="$1"
  local DISPLAY="$2"
  local SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

  if gcloud iam service-accounts describe "$SA_EMAIL" \
       --project="$PROJECT" &>/dev/null 2>&1; then
    warn "Service account '$SA_EMAIL' already exists — skipping creation."
  else
    gcloud iam service-accounts create "$SA_NAME" \
      --display-name="$DISPLAY" \
      --project="$PROJECT"
    info "Created: $SA_EMAIL"
  fi
  echo "$SA_EMAIL"
}

# ── Helper: bind IAM roles ────────────────────────────────────────────────────
bind_roles() {
  local SA_EMAIL="$1"
  shift
  for ROLE in "$@"; do
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$ROLE" \
      --condition=None \
      --quiet
    info "  Bound $ROLE → $SA_EMAIL"
  done
}

# ── Helper: create key + K8s Secret ──────────────────────────────────────────
create_key_and_secret() {
  local SA_EMAIL="$1"
  local SECRET_NAME="$2"
  local KEY_FILE="${KEY_DIR}/${SECRET_NAME}.json"

  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT"
  info "Key created: $KEY_FILE"

  kubectl create secret generic "$SECRET_NAME" \
    --from-file=client_secret.json="$KEY_FILE" \
    --namespace=apigee \
    --dry-run=client -o yaml | kubectl apply -f -
  info "Kubernetes Secret applied: $SECRET_NAME"

  # Remove local key file after staging to K8s Secret
  rm -f "$KEY_FILE"
  info "Local key file removed (stored only in K8s Secret)"
}

# ── Main Loop ─────────────────────────────────────────────────────────────────
info "Starting service account setup for project: $PROJECT | org: $ORG"

for KEY in "${!SA_ROLES[@]}"; do
  IFS='|' read -r SA_NAME DISPLAY ROLES <<< "${SA_ROLES[$KEY]}"
  info "--- Processing: $SA_NAME ---"

  SA_EMAIL=$(create_sa "$SA_NAME" "$DISPLAY")
  # shellcheck disable=SC2086
  bind_roles "$SA_EMAIL" $ROLES
  create_key_and_secret "$SA_EMAIL" "${SA_NAME}-svc-account"
done

# ── Synchronizer — additional org-level binding ───────────────────────────────
SYNC_EMAIL="apigee-sync-sa@${PROJECT}.iam.gserviceaccount.com"
info "Granting Synchronizer access to Apigee org: $ORG"
curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${ORG}:setSyncAuthorization" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d "{\"identities\":[\"serviceAccount:${SYNC_EMAIL}\"]}" | jq .

info "======================================================"
info "  Service account setup complete."
info "  All keys stored as Kubernetes Secrets in namespace: apigee"
info "  Next step: ./03-install-apigee-hybrid.sh"
info "======================================================"
