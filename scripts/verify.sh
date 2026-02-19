#!/usr/bin/env bash
# =============================================================================
# K8s Security Lab - Post-Install Verification
# =============================================================================
export KUBECONFIG=~/.kube/config

PASS=0; FAIL=0
ok()  { echo "  ✔ $*"; ((PASS++)); }
fail(){ echo "  ✘ $*"; ((FAIL++)); }
hdr() { echo ""; echo "── $* ──────────────────────────────────"; }

hdr "LoadBalancer IPs (MetalLB)"
for svc_check in "ingress/nginx-ingress-controller:172.20.20.21" \
                  "monitoring/prometheus-grafana:172.20.20.23" \
                  "monitoring/kiali-server:172.20.20.24"; do
  ns="${svc_check%%/*}"; rest="${svc_check#*/}"
  svc="${rest%%:*}"; expected="${rest#*:}"
  ip=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ "$ip" == "$expected" ]] && ok "$svc → $ip" || fail "$svc expected $expected, got '$ip'"
done

hdr "Istio IngressGateway (must be ClusterIP)"
type=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.type}' 2>/dev/null)
[[ "$type" == "ClusterIP" ]] && ok "istio-ingressgateway is ClusterIP" \
  || fail "istio-ingressgateway is $type — should be ClusterIP!"

hdr "STRICT mTLS"
mode=$(kubectl get peerauthentication default -n istio-system -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
[[ "$mode" == "STRICT" ]] && ok "PeerAuthentication mode: STRICT" \
  || fail "PeerAuthentication mode: $mode (expected STRICT)"

hdr "Network Policies"
for ns in frontend backend data; do
  count=$(kubectl get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l)
  [[ "$count" -ge 1 ]] && ok "$ns: $count network policy/policies" \
    || fail "$ns: no network policies found!"
done

hdr "Application Pods"
for check in "data:app=demo-postgres" "backend:app=demo-backend" "frontend:app=demo-frontend"; do
  ns="${check%%:*}"; selector="${check#*:}"
  ready=$(kubectl get pods -n "$ns" -l "$selector" -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null | tr ' ' '\n' | grep -c true || true)
  [[ "$ready" -ge 1 ]] && ok "$ns/$selector: $ready pod(s) ready" \
    || fail "$ns/$selector: no ready pods"
done

hdr "WAF Security Test (SQL Injection)"
status=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://172.20.20.21/?id=1'%20OR%20'1'='1" --max-time 5 2>/dev/null || echo "000")
[[ "$status" == "403" ]] && ok "SQL injection blocked (HTTP 403)" \
  || fail "SQL injection returned HTTP $status (expected 403)"

hdr "Network Isolation Test"
# Frontend should NOT be able to reach postgres directly
result=$(kubectl exec -n frontend deploy/demo-frontend -- \
  curl -m 3 -s demo-postgres.data:5432 2>&1 || true)
if echo "$result" | grep -qiE "timeout|refused|no route|connection"; then
  ok "frontend → database: BLOCKED (correct)"
else
  fail "frontend → database: may not be blocked! Output: $result"
fi

hdr "Exposed Services Check (only expected LBs should exist)"
lbs=$(kubectl get svc -A --no-headers | awk '$4=="LoadBalancer"' | awk '{print $1"/"$2}')
echo "  LoadBalancer services:"
echo "$lbs" | while read -r svc; do echo "    $svc"; done

echo ""
echo "════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "  ✔ All checks passed!" || echo "  ⚠ $FAIL check(s) failed — review above"
echo "════════════════════════════════════════"
