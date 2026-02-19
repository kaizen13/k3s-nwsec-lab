# Kubernetes Network Security Lab

> **Enterprise-grade Kubernetes security architecture** — translating traditional network security concepts (Cisco/Fortinet/PaloAlto) into cloud-native implementations.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/kubernetes-v1.28+-blue)](https://kubernetes.io/)
[![Istio](https://img.shields.io/badge/istio-1.24-blueviolet)](https://istio.io/)
[![k3s](https://img.shields.io/badge/k3s-latest-orange)](https://k3s.io/)

---

## Architecture Overview

```
Internet / External
        │
        ▼
┌─────────────────────────────────────┐
│   172.20.20.21:80 / :443            │
│   NGINX Ingress (LoadBalancer)       │
│   ✔ ModSecurity WAF (OWASP rules)   │
│   ✔ Rate Limiting (100 req/min)     │
│   ✔ TLS Termination                 │
└──────────────────┬──────────────────┘
                   │ Filtered Traffic
                   ▼
┌─────────────────────────────────────┐
│   Istio IngressGateway (ClusterIP)  │
│   ✔ No External IP                  │
│   ✔ STRICT mTLS Enforcement         │
│   ✔ Internal Only                   │
└──────────────────┬──────────────────┘
                   │ Encrypted (mTLS)
                   ▼
┌─────────────────────────────────────┐
│   APPLICATION PODS (ClusterIP)       │
│   React Frontend → FastAPI Backend   │
│              ↓                       │
│   PostgreSQL (data namespace)        │
│   ✔ Network Policies (default-deny)  │
│   ✔ Zero-Trust Microsegmentation     │
└─────────────────────────────────────┘

MONITORING (Direct LoadBalancer IPs — internal network only):
  172.20.20.23:80    → Grafana   (Dashboards)
  172.20.20.24:20001 → Kiali     (Service Mesh Visualization)
  172.20.20.25:16686 → Jaeger    (Distributed Tracing)
  172.20.20.26:9090  → Prometheus (Metrics)
```

---

## Security Architecture: Traditional vs Cloud-Native

| Traditional (Cisco/Fortinet/PaloAlto) | Kubernetes Equivalent |
|---|---|
| DMZ Firewall | NGINX Ingress + ModSecurity WAF |
| Next-Gen Firewall (NGFW) | Istio with STRICT mTLS |
| VLAN Microsegmentation | Kubernetes Network Policies |
| IDS/IPS | Falco (optional) |
| PKI / Certificate Management | cert-manager + Let's Encrypt |
| Monitoring / SIEM | Prometheus + Grafana + Jaeger |

---

## Defense-in-Depth Layers

| Layer | Component | Controls |
|---|---|---|
| **Layer 1 – Perimeter** | NGINX + ModSecurity | WAF, rate limiting, TLS termination |
| **Layer 2 – Service Mesh** | Istio | STRICT mTLS, zero-trust service auth |
| **Layer 3 – Microsegmentation** | Network Policies | Default-deny, explicit allow rules |
| **Layer 4 – Pod Security** | K8s Security Context | Non-root, read-only FS, resource limits |

---

## IP Allocation (172.20.20.0/26)

| IP Address | Service | Port(s) | Access |
|---|---|---|---|
| 172.20.20.5 | Kubernetes Node (SSH) | 22 | Admin only |
| **172.20.20.21** | **NGINX Ingress** | **80, 443** | **Public entry point** |
| 172.20.20.22 | ArgoCD | 443 | Admin only |
| 172.20.20.23 | Grafana | 80 | Internal network |
| 172.20.20.24 | Kiali | 20001 | Internal network |
| 172.20.20.25 | Jaeger | 16686 | Internal network |
| 172.20.20.26 | Prometheus | 9090 | Internal network |
| 172.20.20.27–40 | Reserved | — | Future use |

---

## Components

- **k3s** — Lightweight Kubernetes (traefik & servicelb disabled)
- **MetalLB** — Bare-metal LoadBalancer IP assignment
- **cert-manager** — Automated TLS certificate lifecycle
- **NGINX Ingress** — External entry point with ModSecurity WAF
- **Istio** — Service mesh: mTLS, observability, traffic management
- **Prometheus + Grafana** — Metrics and dashboards
- **Kiali** — Service mesh topology visualization
- **Jaeger** — Distributed tracing
- **ArgoCD** — GitOps continuous delivery
- **Demo App** — React frontend + FastAPI backend + PostgreSQL

---

## Repository Structure

```
k3s-nwsec-lab/
├── README.md
├── infrastructure/
│   ├── namespaces/          # Namespace definitions with security labels
│   ├── metallb/             # MetalLB IP pool configuration
│   ├── cert-manager/        # ClusterIssuers and CA certificates
│   ├── istio/               # Istio install config, Gateway, mTLS PeerAuth
│   └── network-policies/    # Default-deny + per-tier allow rules
├── ingress/
│   └── nginx-ingress/       # Helm values with WAF/ModSecurity config
├── monitoring/
│   ├── prometheus/          # kube-prometheus-stack Helm values
│   ├── kiali/               # Kiali Helm values
│   └── jaeger/              # Jaeger operator + instance
├── argocd/
│   ├── values.yaml          # ArgoCD Helm values (LoadBalancer 172.20.20.22)
│   └── applications.yaml    # App-of-apps pattern for all components
├── sample-app/
│   ├── backend/             # FastAPI application + Dockerfile
│   ├── frontend/            # React/HTML frontend + nginx.conf + Dockerfile
│   ├── database.yaml        # PostgreSQL StatefulSet (data namespace)
│   ├── backend-deploy.yaml  # FastAPI Deployment + Service
│   ├── frontend-deploy.yaml # Frontend Deployment + Service
│   ├── virtualservice.yaml  # Istio VirtualService routing
│   └── ingress.yaml         # NGINX Ingress → Istio Gateway
├── scripts/
│   ├── install.sh           # Full lab installation (Weeks 1–4)
│   ├── verify.sh            # Post-install verification checks
│   ├── traffic-gen.sh       # Traffic generator for observability demos
│   └── cleanup.sh           # Complete environment teardown
└── docs/
    └── TROUBLESHOOTING.md   # Common issues and solutions
```

---

## Quick Start

### Prerequisites
- Hypervisor VM: 12 vCPU / 24GB RAM / 80GB disk
- Ubuntu Server 24.04 LTS
- Static IP: 172.20.20.5/26
- Network access to 172.20.20.0/26 subnet

### Installation

```bash
# Clone the repository
git clone https://github.com/kaizen13/k3s-nwsec-lab.git
cd k3s-nwsec-lab

# Full automated install (Weeks 1–4)
chmod +x scripts/install.sh
./scripts/install.sh

# Or follow the week-by-week guide:
# Week 1: Foundation (k3s, MetalLB, cert-manager, Prometheus)
# Week 2: Ingress, WAF, Istio service mesh
# Week 3: Sample application + Network Policies
# Week 4: Kiali, Jaeger, ArgoCD, security testing
```

### Post-Install Verification

```bash
./scripts/verify.sh

# Manual checks:
kubectl get svc -A | grep LoadBalancer
kubectl get pods -A
kubectl get networkpolicies -A
kubectl get peerauthentication -n istio-system
```

### Access the Lab

```bash
# Add to /etc/hosts on your local machine
echo "172.20.20.21 demo.lab.local" | sudo tee -a /etc/hosts

# Demo application
open http://demo.lab.local

# Monitoring (from internal network)
open http://172.20.20.23      # Grafana (admin/admin123)
open http://172.20.20.24:20001 # Kiali
open http://172.20.20.25:16686 # Jaeger
```

---

## Security Testing

```bash
# Test WAF blocks SQL injection
curl -v "http://172.20.20.21/?id=1' OR '1'='1"
# Expected: 403 Forbidden

# Test rate limiting
for i in {1..110}; do curl -s -o /dev/null -w "%{http_code}\n" http://demo.lab.local; done
# Expected: 429 Too Many Requests after ~100 req/min

# Test network isolation (should FAIL - frontend cannot reach DB directly)
kubectl exec -n frontend deploy/demo-frontend -- curl -m 5 demo-postgres.data:5432
# Expected: Connection timeout

# Verify mTLS enforcement
kubectl get peerauthentication -n istio-system
# Expected: mode: STRICT

# Verify no unauthorized exposed services
kubectl get svc -A | grep LoadBalancer
# Expected: Only nginx (21), grafana (23), kiali (24), jaeger (25)
```

---

## ArgoCD GitOps Demo

```bash
# Access ArgoCD (after install)
open https://172.20.20.22

# Demo: GitOps drift detection
# 1. Manually delete a network policy
kubectl delete networkpolicy frontend-demo-policy -n frontend
# 2. Watch ArgoCD detect drift and auto-restore within ~3 minutes
```

---

## References

- [Kubernetes Docs](https://kubernetes.io/docs/)
- [Istio Docs](https://istio.io/latest/docs/)
- [NGINX Ingress + ModSecurity](https://kubernetes.github.io/ingress-nginx/user-guide/third-party-addons/modsecurity/)
- [cert-manager](https://cert-manager.io/docs/)
- [MetalLB](https://metallb.universe.tf/)
- [OWASP ModSecurity CRS](https://coreruleset.org/)
- [ArgoCD](https://argo-cd.readthedocs.io/)

---

## License

MIT License — see [LICENSE](LICENSE)
