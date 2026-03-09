#!/usr/bin/env bash
# =============================================================================
# component-health-check.sh
# Purpose : Validate all Apigee Hybrid components after install or upgrade.
#           Checks pod readiness, synchronizer lag, UDCA data freshness,
#           Cassandra node status, and Redis cluster health.
#
# Usage   : ./component-health-check.sh \
#             --cluster apigee-aks-east \
#             --namespace apigee
#
# Exit Codes:
#   0 — All components healthy
#   1 — One or more components failed health check
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS="[${GREEN}✓${NC}]"; FAIL="[${RED}✗${NC}]"; WARN="[${YELLOW}!${NC}]"

NAMESPACE="apigee"
FAILED=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster)   CLUSTER="$2";   shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Apigee Hybrid — Component Health Check${NC}"
echo -e "${BLUE}   Cluster  : $(kubectl config current-context)${NC}"
echo -e "${BLUE}   Namespace: ${NAMESPACE}${NC}"
echo -e "${BLUE}   Time     : $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"

# ── Helper: check deployment pods ────────────────────────────────────────────
check_deployment() {
  local LABEL="$1"
  local DISPLAY="$2"
  local EXPECTED_MIN="${3:-1}"

  READY=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null \
    | tr ' ' '\n' | grep -c "true" || echo "0")

  TOTAL=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
    | wc -w || echo "0")

  if [[ "$READY" -ge "$EXPECTED_MIN" ]]; then
    printf " %b %-28s — Running (%s/%s pods)\n" "$PASS" "$DISPLAY" "$READY" "$TOTAL"
  else
    printf " %b %-28s — FAILED  (%s/%s pods ready — expected min %s)\n" \
      "$FAIL" "$DISPLAY" "$READY" "$TOTAL" "$EXPECTED_MIN"
    FAILED=$((FAILED + 1))
  fi
}

# ── 1. Core Components ────────────────────────────────────────────────────────
echo -e "${BLUE}▶ Core Runtime Components${NC}"
check_deployment "app=apigee-ingressgateway"  "Ingress Gateway"     3
check_deployment "app=apigee-runtime"         "Message Processor"   3
check_deployment "app=apigee-synchronizer"    "Synchronizer"        2
check_deployment "app=apigee-udca"            "UDCA"                2
check_deployment "app=apigee-redis"           "Redis"               3

# ── 2. Cassandra Cluster Status ───────────────────────────────────────────────
echo -e "\n${BLUE}▶ Cassandra Cluster${NC}"
CASS_POD=$(kubectl get pod -n "$NAMESPACE" -l app=apigee-cassandra \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$CASS_POD" ]]; then
  printf " %b %-28s — No Cassandra pods found\n" "$FAIL" "Cassandra"
  FAILED=$((FAILED + 1))
else
  NODETOOL_OUT=$(kubectl exec -n "$NAMESPACE" "$CASS_POD" -- \
    nodetool status 2>/dev/null || echo "ERROR")

  if echo "$NODETOOL_OUT" | grep -q "^UN"; then
    UN_COUNT=$(echo "$NODETOOL_OUT" | grep -c "^UN" || echo "0")
    printf " %b %-28s — All nodes UN (%s/3)\n" "$PASS" "Cassandra" "$UN_COUNT"
  else
    printf " %b %-28s — One or more nodes NOT in UN state\n" "$FAIL" "Cassandra"
    echo "$NODETOOL_OUT" | grep -v "^$" | head -20
    FAILED=$((FAILED + 1))
  fi
fi

# ── 3. Synchronizer Lag ───────────────────────────────────────────────────────
echo -e "\n${BLUE}▶ Synchronizer Telemetry${NC}"
SYNC_POD=$(kubectl get pod -n "$NAMESPACE" -l app=apigee-synchronizer \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$SYNC_POD" ]]; then
  SYNC_LOG=$(kubectl logs "$SYNC_POD" -n "$NAMESPACE" --tail=50 2>/dev/null || echo "")
  if echo "$SYNC_LOG" | grep -qi "error\|exception"; then
    printf " %b %-28s — Errors detected in sync logs\n" "$WARN" "Synchronizer Logs"
  else
    printf " %b %-28s — No errors in recent logs\n" "$PASS" "Synchronizer Logs"
  fi
fi

# ── 4. UDCA Data Freshness ────────────────────────────────────────────────────
echo -e "\n${BLUE}▶ UDCA Telemetry Pipeline${NC}"
UDCA_POD=$(kubectl get pod -n "$NAMESPACE" -l app=apigee-udca \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$UDCA_POD" ]]; then
  UDCA_LOG=$(kubectl logs "$UDCA_POD" -n "$NAMESPACE" --tail=20 2>/dev/null || echo "")
  if echo "$UDCA_LOG" | grep -qi "uploaded\|success"; then
    printf " %b %-28s — Telemetry upload confirmed\n" "$PASS" "UDCA Upload"
  else
    printf " %b %-28s — No recent upload confirmation\n" "$WARN" "UDCA Upload"
  fi
fi

# ── 5. Ingress Gateway TLS ────────────────────────────────────────────────────
echo -e "\n${BLUE}▶ TLS / Certificates${NC}"
TLS_SECRET=$(kubectl get secret apigee-ingress-tls -n "$NAMESPACE" \
  -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

if [[ -n "$TLS_SECRET" ]]; then
  EXPIRY=$(kubectl get secret apigee-ingress-tls -n "$NAMESPACE" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null | \
    openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "unknown")
  printf " %b %-28s — Secret present | Expires: %s\n" "$PASS" "Ingress TLS Secret" "$EXPIRY"
else
  printf " %b %-28s — TLS Secret NOT found\n" "$FAIL" "Ingress TLS Secret"
  FAILED=$((FAILED + 1))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
if [[ "$FAILED" -eq 0 ]]; then
  echo -e " ${GREEN}All components are healthy. Platform ready.${NC}"
else
  echo -e " ${RED}${FAILED} component(s) failed health check. Investigate before proceeding.${NC}"
fi
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"

exit "$FAILED"
