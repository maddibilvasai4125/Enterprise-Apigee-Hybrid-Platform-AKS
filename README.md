# Apigee Hybrid on AKS — Multi-Region Production Platform

> **Enterprise-grade Apigee Hybrid deployment on Azure Kubernetes Service (AKS) spanning East/West regions with full CI/CD, observability, disaster recovery, and security hardening.**

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Helm Configuration](#helm-configuration)
- [CI/CD Pipeline](#cicd-pipeline)
- [Observability & Alerting](#observability--alerting)
- [Upgrade Runbook](#upgrade-runbook)
- [Security Hardening](#security-hardening)
- [Disaster Recovery](#disaster-recovery)
- [Contributing](#contributing)

---

## Overview

This repository contains all Infrastructure-as-Code, automation scripts, Helm overrides, Kubernetes manifests, CI/CD pipelines, and operational runbooks for a **production-grade Apigee Hybrid platform** running on **Azure Kubernetes Service (AKS)** across two Azure regions (East US / West US).

### What This Platform Delivers

| Capability | Details |
|---|---|
| **Runtime Topology** | Active-Active East/West AKS clusters |
| **API Traffic Capacity** | Horizontally scaled via HPA, tuned per region |
| **Ingress** | Akamai CDN + Azure DNS with traffic-switch automation |
| **Observability** | Dynatrace APM + Prometheus/Grafana + structured logging |
| **Security** | TLS 1.2+ / mTLS, RBAC, keystore rotation, zero-downtime cert renewal |
| **CI/CD** | Jenkins pipeline with policy linting, env parameterization, staged promotions |
| **DR** | Cassandra snapshots, RTO/RPO-backed recovery procedures |
| **Analytics** | UDCA telemetry pipeline from runtime → management plane |

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                         APIGEE HYBRID — MULTI-REGION                   │
│                                                                        │
│   ┌──────── EAST US ────────┐         ┌──────── WEST US ────────┐      │
│   │  AKS Cluster (East)     │         │  AKS Cluster (West)     │      │
│   │                         │         │                         │      │
│   │  ┌─────────────────┐    │         │  ┌─────────────────┐    │      │
│   │  │  Apigee Runtime  │   │◄───────►│  │  Apigee Runtime  │   │      │
│   │  │  ┌───────────┐  │    │  Sync   │  │  ┌───────────┐  │    │      │
│   │  │  │ Ingress GW│  │    │         │  │  │ Ingress GW│  │    │      │
│   │  │  │ Message   │  │    │         │  │  │ Message   │  │    │      │
│   │  │  │ Processor │  │    │         │  │  │ Processor │  │    │      │
│   │  │  │ Synchronzr│  │    │         │  │  │ Synchronzr│  │    │      │
│   │  │  │ UDCA      │  │    │         │  │  │ UDCA      │  │    │      │
│   │  │  │ Redis     │  │    │         │  │  │ Redis     │  │    │      │
│   │  │  └───────────┘  │    │         │  │  └───────────┘  │    │      │
│   │  └────────┬────────┘    │         │  └────────┬────────┘    │      │
│   │           │             │         │           │             │      │
│   │  ┌────────▼────────┐    │         │  ┌────────▼────────┐    │      │
│   │  │  Cassandra       │◄──┼─────────┼──│  Cassandra       │   │      │
│   │  │  (Datastore)     │   │  Cross- │  │  (Datastore)     │   │      │
│   │  └─────────────────┘    │  Region │  └─────────────────┘    │      │
│   └─────────────────────────┘  Repl.  └─────────────────────────┘      │
│                                                                        │
│   ┌──────────────────────────────────────────────────────────────────┐ │
│   │               APIGEE MANAGEMENT PLANE (Google Cloud)             │ │
│   │   Apigee Org  │  Environments  │  Analytics  │  Control Plane    │ │
│   └──────────────────────────────────────────────────────────────────┘ │
│                                                                        │
│   ┌─────────────────────────────────┐                                  │
│   │  INGRESS / DNS                  │                                  │
│   │  Akamai CDN  │  Azure DNS       │                                  │
│   └─────────────────────────────────┘                                  │
└────────────────────────────────────────────────────────────────────────┘
```

### Component Health Matrix

| Component | Namespace | Health Endpoint | Alert Threshold |
|---|---|---|---|
| Ingress Gateway | `apigee` | `/healthz` | 99.9% uptime |
| Message Processor | `apigee` | pod ready | < 1% error rate |
| Synchronizer | `apigee` | sync lag | < 30s lag |
| UDCA | `apigee` | data freshness | < 5min staleness |
| Redis | `apigee` | cluster ping | < 5ms latency |
| Cassandra | `apigee` | nodetool status | All nodes UN |

---

## Repository Structure

```
apigee-hybrid-aks-multiregion/
│
├── README.md                          # This file
│
├── helm/                              # Helm overrides per region/environment
│   ├── overrides-east.yaml            # East US cluster overrides
│   ├── overrides-west.yaml            # West US cluster overrides
│   └── values-common.yaml             # Shared values across regions
│
├── scripts/
│   ├── install/
│   │   ├── 01-setup-cluster.sh        # AKS cluster baseline setup
│   │   ├── 02-create-service-accounts.sh  # GCP service accounts + key bindings
│   │   └── 03-install-apigee-hybrid.sh    # Full Apigee Hybrid install
│   │
│   ├── upgrade/
│   │   ├── upgrade-hybrid.sh          # Version upgrade automation (e.g., 1.14 → 1.15)
│   │   └── rollback-hybrid.sh         # Safe rollback with state preservation
│   │
│   ├── health-check/
│   │   └── component-health-check.sh  # Post-install / post-upgrade validation
│   │
│   └── cassandra/
│       ├── cassandra-backup.sh        # Snapshot + upload to Azure Blob
│       └── cassandra-restore.sh       # Point-in-time restore from snapshot
│
├── kubernetes/
│   ├── hpa/
│   │   └── apigee-hpa.yaml            # HPA for Message Processor + Ingress GW
│   ├── rbac/
│   │   └── service-account-rbac.yaml  # Least-privilege RBAC for all components
│   └── monitoring/
│       ├── prometheus-alerts.yaml     # PromQL alert rules (latency, CPU, errors)
│       └── grafana-dashboard.json     # Grafana dashboard for Apigee platform
│
├── cicd/
│   └── Jenkinsfile                    # Jenkins pipeline: lint → deploy → validate
│
├── policies/
│   ├── shared-flows/
│   │   ├── sf-auth/                   # Centralized auth Shared Flow (OAuth/API Key)
│   │   └── sf-logging/                # Structured logging Shared Flow
│   └── flow-hooks/
│       └── pre-request-flow-hook.xml  # Pre-request Flow Hook attachment
│
└── docs/
    ├── topology-diagram.md            # Detailed topology + network flow
    ├── upgrade-runbook.md             # Step-by-step upgrade procedure
    └── dr-runbook.md                  # DR procedures with RTO/RPO targets
```

---

## Prerequisites

### Tools Required

```bash
# Verify all required tools are installed
kubectl version --client          # >= 1.27
helm version                      # >= 3.12
apigeectl version                 # >= 1.15
az --version                      # Azure CLI >= 2.50
gcloud --version                  # Google Cloud SDK >= 440
jq --version                      # jq >= 1.6
```

### Required Access

| Resource | Permission Level |
|---|---|
| Azure Subscription | Contributor (AKS node pool management) |
| GCP Project | Apigee Admin + IAM Admin |
| Jenkins | Pipeline Execute + Credential Manage |
| Akamai | DNS + CDN property edit |

### Environment Variables

```bash
# Copy and populate before running any script
cp .env.example .env

# Required variables
export APIGEE_ORG="your-apigee-org"
export APIGEE_ENV_EAST="prod-east"
export APIGEE_ENV_WEST="prod-west"
export GCP_PROJECT_ID="your-gcp-project"
export AKS_CLUSTER_EAST="apigee-aks-east"
export AKS_CLUSTER_WEST="apigee-aks-west"
export AZURE_RESOURCE_GROUP="rg-apigee-prod"
export HYBRID_VERSION="1.15.2"
export CASSANDRA_BACKUP_CONTAINER="apigee-cassandra-backups"
```

---

## Quick Start

### 1. Set Up AKS Cluster

```bash
cd scripts/install
chmod +x *.sh

# Step 1: Prepare AKS cluster (namespaces, storage classes, node taints)
./01-setup-cluster.sh --region east --cluster apigee-aks-east

# Step 2: Create and bind GCP service accounts
./02-create-service-accounts.sh --project $GCP_PROJECT_ID --org $APIGEE_ORG

# Step 3: Install Apigee Hybrid via Helm
./03-install-apigee-hybrid.sh --region east --version $HYBRID_VERSION
```

### 2. Validate Component Health

```bash
cd scripts/health-check
./component-health-check.sh --cluster apigee-aks-east --namespace apigee
```

Expected output:
```
[✓] Ingress Gateway    — Running (3/3 pods)
[✓] Message Processor  — Running (3/3 pods)
[✓] Synchronizer       — Running (2/2 pods) | Lag: 4s
[✓] UDCA               — Running (2/2 pods) | Data Age: 2min
[✓] Redis              — Running (3/3 pods) | Latency: 2ms
[✓] Cassandra          — All nodes UN (3/3)
```

### 3. Deploy an API Proxy via CI/CD

```bash
# Trigger Jenkins pipeline (or run locally)
./cicd/deploy-proxy.sh \
  --proxy HelloWorld \
  --env prod-east \
  --validate true
```

---

## Helm Configuration

Overrides are split by region to allow independent tuning. Common values (org name, project ID, cert paths) live in `values-common.yaml`.

```bash
# Install East region
helm upgrade apigee-hybrid apigee/apigee \
  -f helm/values-common.yaml \
  -f helm/overrides-east.yaml \
  --namespace apigee \
  --version $HYBRID_VERSION \
  --atomic \
  --timeout 15m

# Install West region
helm upgrade apigee-hybrid apigee/apigee \
  -f helm/values-common.yaml \
  -f helm/overrides-west.yaml \
  --namespace apigee \
  --version $HYBRID_VERSION \
  --atomic \
  --timeout 15m
```

See [`helm/overrides-east.yaml`](helm/overrides-east.yaml) and [`helm/overrides-west.yaml`](helm/overrides-west.yaml) for full resource tuning, replica counts, and HPA settings.

---

## CI/CD Pipeline

The Jenkins pipeline (`cicd/Jenkinsfile`) enforces the following promotion gate:

```
[Lint & Validate] → [Deploy to Dev] → [Smoke Test] → [Deploy to Staging]
      → [Load Test] → [Approval Gate] → [Deploy to Prod East]
             → [Health Check] → [Deploy to Prod West] → [Final Validation]
```

### Policy Linting Rules Enforced Pre-Deploy

- No `AssignMessage` policies with hardcoded credentials
- All `ServiceCallout` policies must have timeout set
- `JavaScript` policies must pass ESLint
- Quota policies must reference KVM-backed thresholds (no hardcoded limits)

---

## Observability & Alerting

### Prometheus Alerts (Key Rules)

| Alert | Condition | Severity |
|---|---|---|
| `ApigeeHighLatency` | p99 > 2s over 5m | critical |
| `ApigeeHighErrorRate` | 5xx rate > 1% over 5m | critical |
| `ApigeeSynchronizerLag` | sync lag > 60s | warning |
| `ApigeeUDCADataStale` | data age > 10min | warning |
| `ApigeeCassandraNodeDown` | node not UN | critical |
| `ApigeeIngressPodCrash` | restart count > 3 | warning |

### Grafana Dashboard Panels

- API Latency (p50 / p95 / p99) by proxy
- Request volume East vs. West (split view)
- Error rate heatmap by environment
- JVM heap usage — Message Processors
- Cassandra read/write latency
- Synchronizer lag timeline
- UDCA telemetry freshness

### Dynatrace Integration

All AKS nodes are instrumented with the Dynatrace OneAgent DaemonSet. Custom dashboards are maintained for:
- Service-level traffic maps (proxy → target)
- Anomaly detection on CPU/memory hotspots
- Log ingestion with structured JSON (severity, proxy name, correlation ID)

---

### High-Level Steps (e.g., 1.14.x → 1.15.x)

```bash
# 1. Pre-upgrade: snapshot Cassandra + export current state
./scripts/cassandra/cassandra-backup.sh --tag pre-upgrade-$(date +%Y%m%d)

# 2. Review Helm diff before applying
helm diff upgrade apigee-hybrid apigee/apigee \
  -f helm/values-common.yaml \
  -f helm/overrides-east.yaml \
  --version 1.15.2

# 3. Apply upgrade with rolling restart
./scripts/upgrade/upgrade-hybrid.sh \
  --from-version 1.14.4 \
  --to-version 1.15.2 \
  --region east

# 4. Post-upgrade validation
./scripts/health-check/component-health-check.sh

# 5. If issues detected — rollback
./scripts/upgrade/rollback-hybrid.sh --version 1.14.4 --region east
```

---

## Security Hardening

### TLS / mTLS

- All ingress endpoints enforce **TLS 1.2 minimum** (TLS 1.3 preferred)
- Target server connections use **mTLS** with client certificates stored in keystores
- Keystore/truststore rotation is automated with **zero-downtime** rolling update

### RBAC

- Each Apigee component runs under a dedicated Kubernetes ServiceAccount
- Service accounts are bound to the minimum required GCP IAM roles
- No component uses the default service account

### Structured Logging

All API proxies emit structured JSON logs via the centralized `sf-logging` Shared Flow:

```json
{
  "timestamp": "2024-11-01T12:00:00Z",
  "severity": "INFO",
  "proxy": "payments-v2",
  "environment": "prod-east",
  "correlation_id": "abc-123-xyz",
  "client_ip": "10.0.0.1",
  "latency_ms": 142,
  "status_code": 200
}
```

---

## Disaster Recovery

| Scenario | RTO | RPO | Strategy |
|---|---|---|---|
| Single pod failure | < 1 min | 0 | Kubernetes self-heal |
| AKS node failure | < 5 min | 0 | HPA + node pool autoscale |
| Region-level failure | < 15 min | < 5 min | Traffic switch East↔West via Akamai |
| Cassandra data corruption | < 2 hours | < 1 hour | Point-in-time restore from Azure Blob snapshot |
| Full cluster loss | < 4 hours | < 1 hour | Re-provision from IaC + restore from backup |

### Cassandra Backup Schedule

```
Daily  @ 02:00 UTC  — Full snapshot → Azure Blob (30-day retention)
Hourly             — Incremental commit log backup
Pre-upgrade        — Manual tagged snapshot
```

---

## Migration: OPDK → Hybrid

A dedicated compatibility matrix and migration guide.

### Migration Checklist Summary

- [x] Proxy inventory audit (deprecated proxies removed)
- [x] Policy gap analysis (OPDK-only policies mapped to Hybrid equivalents)
- [x] Shared Flow consolidation (auth, logging, error handling)
- [x] Flow Hook standardization across all environments
- [x] TargetServer / KVM re-creation in Hybrid management plane
- [x] Traffic cutover tested with BlazeMeter load tests
- [x] Rollback path validated per environment

---

## Contributing

1. Branch from `main` using the naming convention: `feature/<short-description>`
2. Run `./scripts/lint/lint-all.sh` before opening a PR
3. All PRs require 2 approvals and passing Jenkins pipeline
4. Runbooks must be updated in `docs/` for any infrastructure change

---

## 👤 Author

**Bilva Sai Eswar Maddi**

- 🐙 GitHub: [@maddibilvasai4125](https://github.com/maddibilvasai4125)
- 💼 LinkedIn: [Bilva Sai Eswar Maddi](https://www.linkedin.com/in/bilva-sai-eswar-maddi/)
- 📧 Email: catchbilvasaieswar@gmail.com
- 🌐 Portfolio: [My Portfolio](https://bilvasaieswarmaddi.com/)

| Apigee Hybrid v1.15.x | AKS 1.27+*
