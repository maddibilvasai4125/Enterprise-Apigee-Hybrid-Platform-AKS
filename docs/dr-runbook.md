# Disaster Recovery Runbook — Apigee Hybrid on AKS

> **Audience:** On-call SRE, Platform Team  
> **Classification:** Internal  
> **Last Updated:** 2024-11-01

---

## RTO / RPO Targets

| Scenario | RTO | RPO |
|---|---|---|
| Single pod failure | < 1 min | 0 (self-healing) |
| AKS node failure | < 5 min | 0 (pod rescheduling) |
| Region-level failure (East or West) | **< 15 min** | **< 5 min** |
| Cassandra data corruption | < 2 hours | < 1 hour |
| Full cluster loss (both regions) | < 4 hours | < 1 hour |

---

## Scenario 1: Pod Crash / CrashLoopBackOff

**Detection:** Prometheus alert `ApigeeIngressGatewayCrashLoop` or `ApigeeMessageProcessorNotReady`

```bash
# 1. Identify the failing pod
kubectl get pods -n apigee -l app=apigee-runtime

# 2. Inspect events and logs
kubectl describe pod <POD_NAME> -n apigee
kubectl logs <POD_NAME> -n apigee --previous --tail=100

# 3. Force reschedule if stuck
kubectl delete pod <POD_NAME> -n apigee

# 4. Validate recovery
./scripts/health-check/component-health-check.sh
```

---

## Scenario 2: AKS Node Failure

**Detection:** Kubernetes node NotReady, Dynatrace host unreachable alert

```bash
# 1. Check node status
kubectl get nodes -o wide

# 2. Cordon the failing node to prevent new pods
kubectl cordon <NODE_NAME>

# 3. Drain workloads to healthy nodes
kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data --timeout=5m

# 4. If node recovers — uncordon
kubectl uncordon <NODE_NAME>

# 5. If node is permanently lost — trigger AKS node pool scale
az aks nodepool scale \
  --resource-group $AZURE_RESOURCE_GROUP \
  --cluster-name $AKS_CLUSTER_EAST \
  --name apigee-runtime-east \
  --node-count 4    # temporary increase
```

---

## Scenario 3: Region Failover (East → West or West → East)

**Trigger:** East US region unavailable, Akamai health checks failing for East endpoints.

```bash
# ── Step 1: Confirm East is unhealthy ─────────────────────────────────────────
kubectl config use-context apigee-aks-east
./scripts/health-check/component-health-check.sh

# ── Step 2: Scale up West to handle full load ─────────────────────────────────
kubectl config use-context apigee-aks-west
kubectl scale deployment apigee-runtime \
  --replicas=10 -n apigee          # double capacity temporarily
kubectl scale deployment apigee-ingressgateway \
  --replicas=6 -n apigee

# Wait for West pods to be ready
kubectl rollout status deployment/apigee-runtime -n apigee --timeout=5m

# ── Step 3: Validate West health ──────────────────────────────────────────────
./scripts/health-check/component-health-check.sh

# ── Step 4: Switch Akamai traffic to West ─────────────────────────────────────
# NOTE: Requires Akamai CLI or manual property edit in Akamai Control Center
# akamai property update prod-api-east --traffic-percent 0
# akamai property update prod-api-west --traffic-percent 100

# Run smoke tests after traffic switch
./cicd/smoke-test.sh --env prod-west --base-url "$PROD_WEST_BASE_URL" --proxy ALL

# ── Step 5: Update Azure DNS TTL for fast propagation ─────────────────────────
az network dns record-set a update \
  --resource-group $AZURE_RESOURCE_GROUP \
  --zone-name "api.company.com" \
  --name "prod" \
  --set ttl=60

# ── Step 6: Notify stakeholders ───────────────────────────────────────────────
echo "Region failover East → West complete. All traffic routed to West US."
echo "Open P1 incident ticket. Begin East US remediation."
```

**Recovery (Re-enable East):**

```bash
# 1. Restore East health
kubectl config use-context apigee-aks-east
./scripts/health-check/component-health-check.sh

# 2. Gradually shift traffic back to East (50/50 first)
# akamai property update prod-api-east --traffic-percent 50
# akamai property update prod-api-west --traffic-percent 50

# 3. Monitor for 30 minutes, then return to normal split
# akamai property update prod-api-east --traffic-percent 70
# akamai property update prod-api-west --traffic-percent 30

# 4. Scale West back to normal
kubectl scale deployment apigee-runtime --replicas=3 -n apigee
kubectl scale deployment apigee-ingressgateway --replicas=3 -n apigee
```

---

## Scenario 4: Cassandra Data Corruption

**Detection:** `ApigeeCassandraNodeDown` alert, `nodetool status` shows DN nodes, proxy errors citing datastore.

```bash
# 1. Assess Cassandra cluster state
CASS_POD=$(kubectl get pod -n apigee -l app=apigee-cassandra \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n apigee $CASS_POD -- nodetool status
kubectl exec -n apigee $CASS_POD -- nodetool describecluster

# 2. Attempt repair first (non-destructive)
kubectl exec -n apigee $CASS_POD -- nodetool repair -pr
# Wait for repair to complete (may take 20-40 minutes)

# 3. If repair fails — restore from backup
./scripts/cassandra/cassandra-restore.sh \
  --tag "backup-YYYYMMDD" \           # find tag from Azure Blob
  --namespace apigee

# 4. Post-restore health check
./scripts/health-check/component-health-check.sh
```

---

## Runbook Sign-off

Every executed DR procedure must result in:

1. ✅ Incident ticket opened with timeline
2. ✅ RCA document linked in ticket within 48 hours
3. ✅ Confluence topology diagram updated if architecture changed
4. ✅ DR procedure updated if steps were modified
5. ✅ Post-incident review scheduled within 1 week
