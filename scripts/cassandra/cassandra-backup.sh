#!/usr/bin/env bash
# =============================================================================
# cassandra-backup.sh
# Purpose : Take a Cassandra snapshot of all Apigee keyspaces and upload
#           to Azure Blob Storage. Used for daily backups, pre-upgrade
#           snapshots, and DR preparedness.
#
# Usage   : ./cassandra-backup.sh \
#             --tag  pre-upgrade-1.14.4-20241101 \
#             --namespace apigee
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

TAG="backup-$(date +%Y%m%d%H%M%S)"
NAMESPACE="apigee"
STORAGE_CONTAINER="${CASSANDRA_BACKUP_CONTAINER:-apigee-cassandra-backups}"
STORAGE_ACCOUNT="${AZURE_STORAGE_ACCOUNT:-}"
KEYSPACES=("apigee_runtime" "apigee_analytics" "system_auth")

while [[ $# -gt 0 ]]; do
  case $1 in
    --tag)       TAG="$2";       shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) error "Unknown: $1" ;;
  esac
done

[[ -z "$STORAGE_ACCOUNT" ]] && error "AZURE_STORAGE_ACCOUNT env var is required"

# ── Get all Cassandra pods ─────────────────────────────────────────────────────
info "Discovering Cassandra pods in namespace: $NAMESPACE"
CASS_PODS=$(kubectl get pods -n "$NAMESPACE" -l app=apigee-cassandra \
  -o jsonpath='{.items[*].metadata.name}')

[[ -z "$CASS_PODS" ]] && error "No Cassandra pods found."

POD_COUNT=$(echo "$CASS_PODS" | wc -w)
info "Found $POD_COUNT Cassandra pod(s): $CASS_PODS"

# ── Take Snapshots ────────────────────────────────────────────────────────────
for POD in $CASS_PODS; do
  info "── Snapshotting pod: $POD"

  for KS in "${KEYSPACES[@]}"; do
    info "   Keyspace: $KS"
    kubectl exec "$POD" -n "$NAMESPACE" -- \
      nodetool snapshot --tag "$TAG" --keyspaces "$KS" 2>/dev/null || \
      warn "   Snapshot failed for keyspace $KS on $POD — may not exist, skipping."
  done

  # ── Compress snapshot data ────────────────────────────────────────────────
  info "   Compressing snapshot data on $POD..."
  ARCHIVE="/tmp/${POD}-${TAG}.tar.gz"

  kubectl exec "$POD" -n "$NAMESPACE" -- \
    bash -c "find /var/lib/cassandra/data -name 'snapshots' -path '*/${TAG}/*' \
             | tar -czf /tmp/snapshot-${TAG}.tar.gz -T - 2>/dev/null && \
             echo 'Archive created: /tmp/snapshot-${TAG}.tar.gz'" || \
    warn "   Compression encountered non-fatal errors (empty keyspaces likely)."

  # ── Copy archive from pod to local ───────────────────────────────────────
  info "   Copying archive from pod to local..."
  kubectl cp \
    "${NAMESPACE}/${POD}:/tmp/snapshot-${TAG}.tar.gz" \
    "/tmp/${POD}-${TAG}.tar.gz" 2>/dev/null || {
    warn "   Copy failed for pod $POD — skipping upload for this pod."
    continue
  }

  ARCHIVE_SIZE=$(du -sh "/tmp/${POD}-${TAG}.tar.gz" | cut -f1)
  info "   Archive size: $ARCHIVE_SIZE"

  # ── Upload to Azure Blob Storage ──────────────────────────────────────────
  info "   Uploading to Azure Blob: $STORAGE_CONTAINER/${POD}/${TAG}/"
  az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$STORAGE_CONTAINER" \
    --name "${POD}/${TAG}/snapshot.tar.gz" \
    --file "/tmp/${POD}-${TAG}.tar.gz" \
    --auth-mode login \
    --overwrite true

  info "   Upload complete."

  # ── Cleanup local temp file ───────────────────────────────────────────────
  rm -f "/tmp/${POD}-${TAG}.tar.gz"

  # ── Clear snapshot from Cassandra to free disk ────────────────────────────
  info "   Clearing snapshot from Cassandra node to free disk space..."
  kubectl exec "$POD" -n "$NAMESPACE" -- \
    nodetool clearsnapshot --tag "$TAG" 2>/dev/null || true
done

# ── Write manifest (metadata) to Blob ────────────────────────────────────────
MANIFEST=$(cat <<EOF
{
  "tag":        "$TAG",
  "namespace":  "$NAMESPACE",
  "pods":       "$CASS_PODS",
  "keyspaces":  ["apigee_runtime","apigee_analytics","system_auth"],
  "timestamp":  "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster":    "$(kubectl config current-context)"
}
EOF
)

echo "$MANIFEST" > "/tmp/manifest-${TAG}.json"
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$STORAGE_CONTAINER" \
  --name "${TAG}/manifest.json" \
  --file "/tmp/manifest-${TAG}.json" \
  --auth-mode login \
  --overwrite true

rm -f "/tmp/manifest-${TAG}.json"

info "======================================================"
info "  Cassandra backup complete."
info "  Tag       : $TAG"
info "  Container : $STORAGE_CONTAINER"
info "  Pods      : $POD_COUNT"
info "======================================================"
info "To restore: ./cassandra-restore.sh --tag $TAG"
