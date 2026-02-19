#!/usr/bin/env bash
# =============================================================================
# Traffic Generator — populates Grafana, Jaeger, and Kiali with real data
# Usage: ./traffic-gen.sh [request_count] [host]
# =============================================================================

COUNT="${1:-200}"
HOST="${2:-demo.lab.local}"
BASE="http://$HOST"

echo "Generating $COUNT requests to $BASE..."
echo "This will populate: Grafana dashboards | Kiali topology | Jaeger traces"
echo ""

# Normal requests
for i in $(seq 1 $((COUNT / 4))); do
  curl -s -o /dev/null "$BASE/" &
  curl -s -o /dev/null "$BASE/api/todos" &
  curl -s -o /dev/null -X POST "$BASE/api/todos" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Task $RANDOM\",\"completed\":false}" &
done

# Simulate WAF triggers (SQL injection — should return 403)
echo "Sending WAF test requests (expect 403s in logs)..."
for i in $(seq 1 10); do
  curl -s -o /dev/null -w "WAF test $i: %{http_code}\n" \
    "$BASE/?id=1' OR '1'='1" &
done

# Simulate 404s
for i in $(seq 1 10); do
  curl -s -o /dev/null "$BASE/nonexistent-$RANDOM" &
done

wait
echo ""
echo "Done! Check:"
echo "  Grafana:  http://172.20.20.23       → Kubernetes / Istio dashboards"
echo "  Kiali:    http://172.20.20.24:20001 → Graph tab (select 'default' namespace)"
echo "  Jaeger:   http://172.20.20.25:16686 → Search: service=demo-frontend"
