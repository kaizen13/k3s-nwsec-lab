#!/usr/bin/env bash
# Rebuild both sample-app container images into k3s containerd and restart pods.
# Must be run in a terminal (sudo requires a TTY).
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Building demo-backend:v1 (connection pool fix)..."
sudo nerdctl build -t demo-backend:v1 "$REPO_DIR/sample-app/backend/"

echo "Building demo-frontend:v1 (nginx.conf cleanup + traffic path update)..."
sudo nerdctl build -t demo-frontend:v1 "$REPO_DIR/sample-app/frontend/"

echo "Verifying images in k3s containerd..."
sudo k3s ctr images ls | grep -E "demo-backend|demo-frontend"

echo "Rolling restart to pick up new images..."
kubectl rollout restart deployment demo-backend  -n backend
kubectl rollout restart deployment demo-frontend -n frontend

kubectl rollout status deployment demo-backend  -n backend --timeout=60s
kubectl rollout status deployment demo-frontend -n frontend --timeout=60s

echo ""
echo "Done. Testing API..."
curl -s --max-time 5 --resolve "demo.lab.local:80:172.20.20.21" \
  http://demo.lab.local/api/todos | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(f'  {len(d)} todos returned — backend OK')"
