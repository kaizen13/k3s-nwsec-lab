#!/usr/bin/env bash
# =============================================================================
# K8s Security Lab - Post-Install Verification
# =============================================================================
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

PASS=0; FAIL=0
ok()  { echo "  ✔ $*"; PASS=$((PASS+1)); }
fail(){ echo "  ✘ $*"; FAIL=$((FAIL+1)); }
hdr() { echo ""; echo "── $* ──────────────────────────────────"; }

hdr "LoadBalancer IPs (MetalLB)"
# CHANGEME: if you adapted the subnet, update these IPs to match your MetalLB assignments
# (infrastructure/metallb/ip-pool.yaml and the individual service values files)
for svc_check in "istio-system/istio-ingressgateway:172.20.20.21" \
                  "monitoring/prometheus-grafana:172.20.20.23" \
                  "monitoring/kiali:172.20.20.24" \
                  "observability/jaeger-query:172.20.20.25"; do
  ns="${svc_check%%/*}"; rest="${svc_check#*/}"
  svc="${rest%%:*}"; expected="${rest#*:}"
  ip=$(kubectl get svc "$svc" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [[ "$ip" == "$expected" ]] && ok "$svc → $ip" || fail "$svc expected $expected, got '$ip'"
done

hdr "Coraza WAF + Rate Limit (Istio extensions)"
wp=$(kubectl get wasmplugin coraza-waf -n istio-system --no-headers 2>/dev/null | wc -l)
[[ "$wp" -ge 1 ]] && ok "WasmPlugin coraza-waf present" \
  || fail "WasmPlugin coraza-waf not found"
ef=$(kubectl get envoyfilter ingress-rate-limit -n istio-system --no-headers 2>/dev/null | wc -l)
[[ "$ef" -ge 1 ]] && ok "EnvoyFilter ingress-rate-limit present" \
  || fail "EnvoyFilter ingress-rate-limit not found"

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
lbs=$(kubectl get svc -A --no-headers | awk '$3=="LoadBalancer" {print $1"/"$2}')
echo "  LoadBalancer services:"
echo "$lbs" | while read -r svc; do echo "    $svc"; done

echo ""
echo "════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "  ✔ All checks passed!" || echo "  ⚠ $FAIL check(s) failed — review above"
echo "════════════════════════════════════════"
