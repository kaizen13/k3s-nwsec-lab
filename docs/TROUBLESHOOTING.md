# Troubleshooting Guide

## Quick Diagnostics

```bash
# Overall cluster health
kubectl get pods -A | grep -v Running | grep -v Completed

# Events (last 20 warnings)
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20

# Node resources
kubectl top nodes
```

---

## Common Issues

### Pods stuck in Pending
```bash
kubectl describe pod <pod-name> -n <namespace>
# Look for: Insufficient cpu/memory, no nodes available, PVC not bound
# Fix: Reduce resource requests in deployment YAML
```

### LoadBalancer IP not assigned
```bash
kubectl get svc -A | grep LoadBalancer | grep "<pending>"
kubectl get pods -n metallb-system
# Fix: Verify MetalLB pod is running and IP pool is correct
kubectl get ipaddresspool -n metallb-system
```

### ServiceMonitor error on NGINX install
**Cause**: Prometheus not installed before NGINX Ingress.
```bash
# Fix: Install Prometheus first, then reinstall NGINX Ingress
helm install prometheus ... (see install.sh)
helm upgrade nginx-ingress ...
```

### DNS not resolving inside pods
```bash
kubectl exec -n frontend deploy/demo-frontend -- nslookup demo-backend.backend.svc.cluster.local
# If failing, restart CoreDNS
kubectl delete pods -n kube-system -l k8s-app=kube-dns
```

### Network policy blocking traffic
```bash
# Check which policies apply to a pod
kubectl get networkpolicies -n <namespace> -o yaml

# Labels must match exactly — verify pod labels
kubectl get pods -n <namespace> --show-labels

# Check policy selectors
kubectl describe networkpolicy <name> -n <namespace>
```

### Istio sidecar not injecting
```bash
kubectl get namespace <name> --show-labels | grep istio-injection
# Fix: Add label to namespace
kubectl label namespace <name> istio-injection=enabled
# Restart pods to get sidecar injected
kubectl rollout restart deployment -n <namespace>
```

### Jaeger shows no traces
```bash
# Verify Istio tracing config points to Jaeger
kubectl get configmap istio -n istio-system -o yaml | grep tracing

# Restart app pods after Jaeger is deployed
kubectl rollout restart deployment -n frontend
kubectl rollout restart deployment -n backend

# Generate traffic to populate traces
./scripts/traffic-gen.sh 50
```

### Certificate not issued
```bash
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>
# Check cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager | tail -50
```

### Grafana shows no Istio metrics
```bash
# Apply Istio scrape targets
kubectl apply -f monitoring/prometheus/istio-scrape-targets.yaml

# Check Prometheus targets
# http://172.20.20.26:9090/targets (filter: istio)
```

### Out of memory / pods OOMKilled
```bash
kubectl top pods -A --sort-by memory
# Reduce replicas
kubectl scale deployment demo-backend -n backend --replicas=1
kubectl scale deployment demo-frontend -n frontend --replicas=1
```

### WAF not blocking SQL injection (returns 200 instead of 403)
```bash
# Verify ModSecurity is enabled on the ingress
kubectl get configmap -n ingress nginx-ingress-controller -o yaml | grep modsecurity

# Check NGINX logs
kubectl logs -n ingress deploy/nginx-ingress-controller | grep -i "ModSecurity"

# Force enable on specific ingress annotation:
# nginx.ingress.kubernetes.io/enable-modsecurity: "true"
```

---

## Emergency Recovery

### Reset a namespace
```bash
kubectl delete namespace <name> && kubectl create namespace <name>
kubectl label namespace <name> istio-injection=enabled
kubectl apply -f infrastructure/network-policies/default-deny.yaml
```

### Backup before changes
```bash
mkdir -p ~/k8s-backups/$(date +%Y%m%d)
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  kubectl get all,configmap,networkpolicy -n $ns -o yaml \
    > ~/k8s-backups/$(date +%Y%m%d)/$ns.yaml
done
```

### Full wipe and reinstall
```bash
./scripts/cleanup.sh wipe
# Reboot, then:
./scripts/install.sh
```
