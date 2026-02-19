# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

A Kubernetes network security lab running on a single k3s node (172.20.20.5). It demonstrates enterprise security patterns (WAF, mTLS, microsegmentation, GitOps) using cloud-native tooling. This is a learning/portfolio lab, not a production system.

## Key Commands

### Cluster Management
```bash
# Verify cluster health after changes
./scripts/verify.sh

# Generate traffic for observability demos (Grafana/Kiali/Jaeger)
./scripts/traffic-gen.sh [count] [host]   # default: 200 requests to demo.lab.local

# Full install (fresh start)
./scripts/install.sh

# Teardown options
./scripts/cleanup.sh app          # Remove sample app only
./scripts/cleanup.sh monitoring   # Remove Prometheus/Grafana/Kiali/Jaeger
./scripts/cleanup.sh all          # Remove everything except k3s
./scripts/cleanup.sh wipe         # Full teardown including k3s uninstall
```

### kubectl Quick Checks
```bash
export KUBECONFIG=~/.kube/config

# Check all pods are running
kubectl get pods -A | grep -v Running | grep -v Completed

# Check LoadBalancer IPs are assigned
kubectl get svc -A | grep LoadBalancer

# Check network policies exist in all three app namespaces
kubectl get networkpolicies -A

# Verify STRICT mTLS is enforced
kubectl get peerauthentication -n istio-system

# Warning events
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20
```

### Applying Changes
```bash
# Apply a modified manifest
kubectl apply -f <file>.yaml

# Restart a deployment (e.g., after config change or to inject Istio sidecar)
kubectl rollout restart deployment <name> -n <namespace>

# Scale down to save memory
kubectl scale deployment demo-backend -n backend --replicas=1
kubectl scale deployment demo-frontend -n frontend --replicas=1
```

### Building Sample App Images
Images are built directly into k3s containerd (no Docker daemon). The install script handles this automatically, but for manual rebuilds:
```bash
sudo nerdctl build -t demo-backend:v1 ./sample-app/backend/
sudo nerdctl build -t demo-frontend:v1 ./sample-app/frontend/
sudo k3s ctr images ls | grep demo  # verify import
```

### Security Testing
```bash
# WAF test — expect 403
curl -v "http://172.20.20.21/?id=1' OR '1'='1"

# Rate limiting test — expect 429 after ~100 req/min
for i in {1..110}; do curl -s -o /dev/null -w "%{http_code}\n" http://demo.lab.local; done

# Network isolation — should FAIL (timeout)
kubectl exec -n frontend deploy/demo-frontend -- curl -m 5 demo-postgres.data:5432
```

## Architecture

### Traffic Flow (Defense-in-Depth)
```
Internet → Istio IngressGateway (LoadBalancer 172.20.20.21)
             + Coraza WasmPlugin (OWASP CRS — blocks SQLi/XSS)
             + EnvoyFilter (local rate limiting, 100 req/min)
           → App Pods (mTLS enforced)
```
- **Istio IngressGateway** (`istio-system`): External entry point, Coraza WAF (OWASP CRS via WasmPlugin), local rate limiting (EnvoyFilter), security response headers (VirtualService)
- **Application namespaces**: `frontend`, `backend`, `data` — each with default-deny NetworkPolicy + explicit allow rules

### Namespace Structure
| Namespace | Contents | Istio Sidecar |
|---|---|---|
| `istio-system` | Istio control plane, IngressGateway (public entry + Coraza WAF) | N/A |
| `frontend` | React/HTML app (nginx) | Yes |
| `backend` | FastAPI Todo API | Yes |
| `data` | PostgreSQL StatefulSet | Yes |
| `monitoring` | Prometheus, Grafana, Kiali | No |
| `observability` | Jaeger (via jaeger-operator v1.51.0) | No |
| `cert-manager` | Certificate lifecycle | No |
| `metallb-system` | Bare-metal LoadBalancer | No |

### MetalLB IP Allocation
| IP | Service | Port |
|---|---|---|
| 172.20.20.21 | Istio IngressGateway (public entry + Coraza WAF) | 80, 443 |
| 172.20.20.22 | ArgoCD | 443 |
| 172.20.20.23 | Grafana | 80 |
| 172.20.20.24 | Kiali | 20001 |
| 172.20.20.25 | Jaeger | 16686 |
| 172.20.20.26 | Prometheus | 9090 |

### Sample App
- **Frontend** (`sample-app/frontend/`): Static HTML/JS served by nginx, calls `/api/todos` — routed via Istio VirtualService
- **Backend** (`sample-app/backend/main.py`): FastAPI with CRUD endpoints for a todo list, connects to PostgreSQL using `demo-db-credentials` secret
- **Database** (`sample-app/database.yaml`): PostgreSQL StatefulSet in `data` namespace
- DB credentials secret exists only in `data` namespace; install script copies it to `backend` namespace

### Key Security Invariants
- Istio IngressGateway **must** be `LoadBalancer` with IP `172.20.20.21` — verify.sh checks this
- WasmPlugin `coraza-waf` and EnvoyFilter `ingress-rate-limit` must exist in `istio-system` — verify.sh checks these
- PeerAuthentication mode **must** be `STRICT` in `istio-system`
- All three app namespaces must have `default-deny-all` NetworkPolicy
- Namespaces need label `istio-injection=enabled` for sidecar injection

### Helm Releases
| Release | Namespace | Chart |
|---|---|---|
| `prometheus` | monitoring | prometheus-community/kube-prometheus-stack |
| `cert-manager` | cert-manager | jetstack/cert-manager |
| `kiali-server` | monitoring | kiali/kiali-server |

### ArgoCD GitOps
`argocd/applications.yaml` uses the app-of-apps pattern to manage all components. ArgoCD detects drift (e.g., manually deleted NetworkPolicy) and auto-restores within ~3 minutes.

## Common Pitfalls

- **Istio sidecar not injecting**: Check namespace has `istio-injection=enabled` label, then restart pods
- **Jaeger shows no traces**: Restart app pods after Jaeger is deployed; generate traffic with `traffic-gen.sh`
- **Jaeger operator not reconciling**: It uses leader election — if a stale lease exists from a previous pod, delete it: `kubectl delete lease 31e04290.jaegertracing.io -n observability`
- **Jaeger namespace**: jaeger-operator v1.51.0 hardcodes `observability` namespace; deploying to any other namespace causes resource conflicts. Jaeger CR must also be in `observability`.
- **Grafana missing Istio metrics**: Apply `monitoring/prometheus/istio-scrape-targets.yaml`
- **Pods OOMKilled**: Scale down replicas — this is a single node with 24GB RAM shared across everything
- **Coraza WasmPlugin not blocking**: Verify the plugin loaded with `kubectl get wasmplugin -n istio-system`; check IngressGateway logs for WASM errors
- **WAF false positives**: Add `SecRuleRemoveById <id>` directives to the `pluginConfig` in `infrastructure/istio/wasm-plugin.yaml`
