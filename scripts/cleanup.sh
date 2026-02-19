#!/usr/bin/env bash
# =============================================================================
# Cleanup Script — selective or full teardown
# Usage: ./cleanup.sh [app|monitoring|all|wipe]
# =============================================================================
export KUBECONFIG=~/.kube/config
REPO_DIR="$HOME/k3s-nwsec-lab"
MODE="${1:-app}"

remove_app() {
  echo "Removing sample application..."
  kubectl delete -f "$REPO_DIR/sample-app/virtualservice.yaml" --ignore-not-found
  kubectl delete -f "$REPO_DIR/sample-app/frontend-deploy.yaml" --ignore-not-found
  kubectl delete -f "$REPO_DIR/sample-app/backend-deploy.yaml" --ignore-not-found
  kubectl delete -f "$REPO_DIR/sample-app/database.yaml" --ignore-not-found
  kubectl delete -f "$REPO_DIR/infrastructure/network-policies/" --ignore-not-found
  kubectl delete secret demo-db-credentials -n backend --ignore-not-found
  sudo sed -i '/demo.lab.local/d' /etc/hosts
  echo "Sample app removed."
}

remove_monitoring() {
  echo "Removing monitoring stack..."
  helm uninstall kiali-server -n monitoring 2>/dev/null || true
  kubectl delete jaeger jaeger -n observability 2>/dev/null || true
  kubectl delete -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.51.0/jaeger-operator.yaml -n observability 2>/dev/null || true
  kubectl delete namespace observability --ignore-not-found
  helm uninstall prometheus -n monitoring 2>/dev/null || true
  kubectl delete namespace monitoring --ignore-not-found
  echo "Monitoring removed."
}

remove_all() {
  remove_app
  remove_monitoring
  echo "Removing Istio..."
  istioctl uninstall --purge -y 2>/dev/null || true
  kubectl delete namespace istio-system --ignore-not-found
  echo "Removing cert-manager..."
  helm uninstall cert-manager -n cert-manager 2>/dev/null || true
  kubectl delete namespace cert-manager --ignore-not-found
  echo "Removing MetalLB..."
  kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml 2>/dev/null || true
  kubectl delete namespace metallb-system --ignore-not-found
  echo "All components removed. k3s is still running."
}

full_wipe() {
  echo "WARNING: Full wipe — k3s will be uninstalled!"
  read -p "Type 'WIPE' to confirm: " confirm
  [[ "$confirm" != "WIPE" ]] && { echo "Aborted."; exit 0; }
  remove_all
  echo "Uninstalling k3s..."
  sudo systemctl stop k3s
  sudo /usr/local/bin/k3s-uninstall.sh
  sudo rm -rf /var/lib/rancher /etc/rancher ~/.kube
  sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
  docker system prune -a -f 2>/dev/null || true
  echo "Wipe complete. Reboot recommended: sudo reboot"
}

case "$MODE" in
  app)        remove_app ;;
  monitoring) remove_monitoring ;;
  all)        remove_all ;;
  wipe)       full_wipe ;;
  *)          echo "Usage: $0 [app|monitoring|all|wipe]"; exit 1 ;;
esac
