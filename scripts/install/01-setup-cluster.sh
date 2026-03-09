#!/usr/bin/env bash
# =============================================================================
# 01-setup-cluster.sh
# Purpose : Prepare an AKS cluster for Apigee Hybrid installation.
#           Creates namespaces, storage classes, node taints/labels,
#           and installs required cluster-level operators.
#
# Usage   : ./01-setup-cluster.sh --region east --cluster apigee-aks-east
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
REGION=""
CLUSTER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)  REGION="$2";  shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "$REGION"  ]] && error "--region is required  (east|west)"
[[ -z "$CLUSTER" ]] && error "--cluster is required (AKS cluster name)"

# ── Prerequisites check ───────────────────────────────────────────────────────
info "Checking prerequisites..."
for tool in kubectl helm az jq; do
  command -v "$tool" &>/dev/null || error "$tool is not installed or not in PATH"
done
info "All prerequisites satisfied."

# ── Connect to AKS cluster ────────────────────────────────────────────────────
info "Fetching AKS credentials for cluster: $CLUSTER"
az aks get-credentials \
  --resource-group "${AZURE_RESOURCE_GROUP}" \
  --name "$CLUSTER" \
  --overwrite-existing

kubectl config use-context "$CLUSTER"
info "Connected to: $(kubectl config current-context)"

# ── Namespaces ────────────────────────────────────────────────────────────────
info "Creating Apigee namespaces..."
for ns in apigee apigee-system cert-manager; do
  if kubectl get namespace "$ns" &>/dev/null; then
    warn "Namespace '$ns' already exists — skipping."
  else
    kubectl create namespace "$ns"
    info "Created namespace: $ns"
  fi
done

# ── Node Pool Labels & Taints ─────────────────────────────────────────────────
# Labels allow Helm nodeSelector to target correct node pools.
# Taints ensure only Apigee workloads land on dedicated nodes.
info "Applying node pool labels and taints for region: $REGION..."

declare -A NODE_POOLS=(
  ["apigee-ingress-${REGION}"]="ingress"
  ["apigee-runtime-${REGION}"]="runtime"
  ["apigee-cassandra-${REGION}"]="cassandra"
)

for POOL in "${!NODE_POOLS[@]}"; do
  COMPONENT="${NODE_POOLS[$POOL]}"
  NODES=$(kubectl get nodes -l "agentpool=${POOL}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [[ -z "$NODES" ]]; then
    warn "No nodes found for pool '$POOL' — skipping label/taint."
    continue
  fi

  for NODE in $NODES; do
    kubectl label node "$NODE" "apigee-component=${COMPONENT}" --overwrite
    kubectl taint node "$NODE" "apigee-component=${COMPONENT}:NoSchedule" --overwrite 2>/dev/null || true
    info "  Labelled + tainted: $NODE → $COMPONENT"
  done
done

# ── Storage Classes ───────────────────────────────────────────────────────────
info "Applying storage classes..."
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-premium
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  kind: Managed
  cachingMode: ReadOnly
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
info "Storage class 'managed-premium' applied."

# ── cert-manager ──────────────────────────────────────────────────────────────
info "Installing cert-manager (if not already present)..."
if helm status cert-manager -n cert-manager &>/dev/null; then
  warn "cert-manager is already installed — skipping."
else
  helm repo add jetstack https://charts.jetstack.io --force-update
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version v1.13.0 \
    --set installCRDs=true \
    --wait --timeout 5m
  info "cert-manager installed."
fi

# ── Validate Cluster Readiness ────────────────────────────────────────────────
info "Validating cluster node readiness..."
NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready " | wc -l)
if [[ "$NOT_READY" -gt 0 ]]; then
  error "$NOT_READY node(s) are NOT Ready. Resolve before proceeding."
fi

info "======================================================"
info "  Cluster setup complete for: $CLUSTER ($REGION)"
info "  Next step: ./02-create-service-accounts.sh"
info "======================================================"
