#!/usr/bin/env bash
# =============================================================================
# K8s Network Security Lab - Full Installation Script
# Follows week-by-week guide: Foundation → WAF/Mesh → App → Monitoring
# =============================================================================
set -e

REPO_DIR="$HOME/k3s-nwsec-lab"
LOG="$HOME/install.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
err() { echo "[ERROR] $*" | tee -a "$LOG"; exit 1; }

log "=== K8s Security Lab Installation ==="
log "Logs: $LOG"

# ── WEEK 1: FOUNDATION ────────────────────────────────────────────────────────

log "--- Week 1: System preparation ---"
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git vim htop net-tools

log "--- Installing k3s (traefik & servicelb disabled) ---"
curl -sfL https://get.k3s.io | sh -s - \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable servicelb

rm -rf ~/.kube && mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$USER:$USER" ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
grep -q KUBECONFIG ~/.bashrc || echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc

kubectl wait --for=condition=Ready node --all --timeout=60s
log "k3s ready: $(kubectl get nodes --no-headers)"

log "--- Installing Helm ---"
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

log "--- Installing MetalLB ---"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Wait for pods first
kubectl wait --namespace metallb-system --for=condition=ready pod \
  --selector=app=metallb --timeout=90s

# Wait for CRDs to be fully established (webhook needs time after pods are ready)
log "Waiting for MetalLB CRDs to be established..."
kubectl wait --for=condition=established crd/ipaddresspools.metallb.io --timeout=60s
kubectl wait --for=condition=established crd/l2advertisements.metallb.io --timeout=60s
sleep 5

kubectl apply -f "$REPO_DIR/infrastructure/metallb/ip-pool.yaml"
log "MetalLB pool: 172.20.20.21-172.20.20.40"

log "--- Installing cert-manager ---"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.crds.yaml
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.15.3
kubectl wait --namespace cert-manager --for=condition=ready pod \
  --selector=app=cert-manager --timeout=90s
kubectl apply -f "$REPO_DIR/infrastructure/cert-manager/cluster-issuer.yaml"

log "--- Installing Prometheus + Grafana ---"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values "$REPO_DIR/monitoring/prometheus/values.yaml"
kubectl wait --namespace monitoring --for=condition=ready pod \
  --selector=app.kubernetes.io/name=grafana --timeout=120s
log "Grafana: http://172.20.20.23 (admin/admin123)"

# ── WEEK 2: INGRESS + WAF + ISTIO ─────────────────────────────────────────────

log "--- Week 2: Namespaces ---"
kubectl apply -f "$REPO_DIR/infrastructure/namespaces/namespaces.yaml"

log "--- Installing Istio (IngressGateway as public entry point) ---"
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.24.0 sh -
sudo mv istio-1.24.0/bin/istioctl /usr/local/bin/
kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -
istioctl install -f "$REPO_DIR/infrastructure/istio/istio-config.yaml" -y
kubectl apply -f "$REPO_DIR/infrastructure/istio/peer-authentication.yaml"
kubectl apply -f "$REPO_DIR/infrastructure/istio/gateway.yaml"
kubectl apply -f "$REPO_DIR/infrastructure/istio/wasm-plugin.yaml"
kubectl apply -f "$REPO_DIR/infrastructure/istio/rate-limit.yaml"
log "Istio IngressGateway (WAF/Coraza): http://172.20.20.21"

# ── WEEK 3: SAMPLE APPLICATION + NETWORK POLICIES ────────────────────────────

log "--- Week 3: Deploying sample application ---"

log "Building images into k3s containerd (no Docker required)..."

# k3s bundles containerd — use nerdctl if available, otherwise buildah, otherwise error
if command -v nerdctl &>/dev/null; then
  log "Using nerdctl (k3s containerd CLI)"
  sudo nerdctl build -t demo-backend:v1 "$REPO_DIR/sample-app/backend/"
  sudo nerdctl build -t demo-frontend:v1 "$REPO_DIR/sample-app/frontend/"

elif command -v buildah &>/dev/null; then
  log "Using buildah"
  buildah bud -t demo-backend:v1 "$REPO_DIR/sample-app/backend/"
  buildah bud -t demo-frontend:v1 "$REPO_DIR/sample-app/frontend/"
  # Export from buildah and import into k3s containerd
  buildah push demo-backend:v1 oci-archive:/tmp/demo-backend.tar
  buildah push demo-frontend:v1 oci-archive:/tmp/demo-frontend.tar
  sudo k3s ctr images import /tmp/demo-backend.tar
  sudo k3s ctr images import /tmp/demo-frontend.tar
  rm -f /tmp/demo-backend.tar /tmp/demo-frontend.tar

else
  log "Neither nerdctl nor buildah found — installing nerdctl..."
  NERDCTL_VERSION="1.7.6"
  wget -q "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-amd64.tar.gz" -O /tmp/nerdctl.tar.gz
  sudo tar -xzf /tmp/nerdctl.tar.gz -C /usr/local/bin nerdctl
  rm /tmp/nerdctl.tar.gz
  sudo nerdctl build -t demo-backend:v1 "$REPO_DIR/sample-app/backend/"
  sudo nerdctl build -t demo-frontend:v1 "$REPO_DIR/sample-app/frontend/"
fi

# Verify images are visible to k3s
sudo k3s ctr images ls | grep -E "demo-backend|demo-frontend" \
  && log "Images imported into k3s containerd successfully" \
  || err "Images not found in k3s containerd — check build output above"
cd ~

kubectl apply -f "$REPO_DIR/sample-app/database.yaml"
kubectl wait --for=condition=ready pod -l app=demo-postgres -n data --timeout=120s

# Copy DB secret to backend namespace
kubectl get secret demo-db-credentials -n data -o yaml | \
  sed 's/namespace: data/namespace: backend/' | kubectl apply -f -

kubectl apply -f "$REPO_DIR/sample-app/backend-deploy.yaml"
kubectl apply -f "$REPO_DIR/sample-app/frontend-deploy.yaml"
kubectl apply -f "$REPO_DIR/sample-app/virtualservice.yaml"

log "--- Applying Network Policies (default-deny + allow rules) ---"
kubectl apply -f "$REPO_DIR/infrastructure/network-policies/default-deny.yaml"
kubectl apply -f "$REPO_DIR/infrastructure/network-policies/frontend-policy.yaml"
kubectl apply -f "$REPO_DIR/infrastructure/network-policies/backend-data-policy.yaml"
kubectl apply -f "$REPO_DIR/monitoring/prometheus/istio-scrape-targets.yaml"

# ── WEEK 4: KIALI + JAEGER ───────────────────────────────────────────────────

log "--- Week 4: Kiali (service mesh visualization) ---"
helm repo add kiali https://kiali.org/helm-charts
helm repo update
helm upgrade --install kiali-server kiali/kiali-server \
  --namespace monitoring \
  --values "$REPO_DIR/monitoring/kiali/values.yaml"
log "Kiali: http://172.20.20.24:20001"

log "--- Jaeger (distributed tracing) ---"
# NOTE: jaeger-operator v1.51.0 hardcodes the 'observability' namespace internally;
# applying with -n <other-namespace> causes resource conflicts. Use its own namespace.
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.51.0/jaeger-operator.yaml \
  -n observability 2>/dev/null || true
kubectl wait --namespace observability --for=condition=ready pod \
  --selector=app.kubernetes.io/name=jaeger-operator --timeout=90s
kubectl apply -f "$REPO_DIR/monitoring/jaeger/jaeger.yaml"
sleep 15
kubectl patch svc jaeger-query -n observability \
  -p '{"spec":{"type":"LoadBalancer"},"metadata":{"annotations":{"metallb.universe.tf/loadBalancerIPs":"172.20.20.25"}}}' \
  2>/dev/null || true
log "Jaeger: http://172.20.20.25:16686"

# ── DONE ─────────────────────────────────────────────────────────────────────

log ""
log "=== Installation Complete! ==="
log ""
log "Add to /etc/hosts on your local machine:"
log "  172.20.20.21  demo.lab.local"
log ""
log "Access:"
log "  Demo App:   http://demo.lab.local"
log "  Grafana:    http://172.20.20.23       (admin/admin123)"
log "  Kiali:      http://172.20.20.24:20001"
log "  Jaeger:     http://172.20.20.25:16686"
log ""
log "Run ./scripts/verify.sh to validate the installation."
