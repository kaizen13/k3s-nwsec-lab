#!/usr/bin/env bash
# =============================================================================
# App Traffic Generator — showcases real application traffic flows for Kiali
#
# Generates realistic CRUD traffic across the full service mesh path:
#   Istio IngressGateway → demo-frontend (/)
#   Istio IngressGateway → demo-backend  (/api/*) → demo-postgres
#
# Usage: ./app-traffic.sh [duration_seconds] [host] [gateway_ip]
# Default: 120 seconds, demo.lab.local, 172.20.20.21
#
# Kiali settings to see mTLS and all flows:
#   Graph → Namespaces: frontend + backend + data
#   Display → Security (shows mTLS padlocks)
#   Display → Traffic Animation
#   Display → Request Rate / Response Time (edge labels)
#   Time range: Last 1m   Refresh: Every 30s
# =============================================================================

DURATION="${1:-120}"
HOST="${2:-demo.lab.local}"
GW_IP="${3:-172.20.20.21}"   # CHANGEME if you adapted the subnet
BASE="http://$HOST"

if getent hosts "$HOST" &>/dev/null; then
  RESOLVE=()
else
  RESOLVE=(--resolve "${HOST}:80:${GW_IP}")
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  App Traffic Generator  |  target: $BASE (→ $GW_IP)"
echo "  Duration: ${DURATION}s  |  All CRUD ops + frontend pages"
echo "  Kiali graph: select namespaces frontend + backend + data"
echo "  Enable Display → Security to see mTLS padlocks"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Helper: silent curl ───────────────────────────────────────────────────────
req() { curl -s -o /dev/null --max-time 5 "${RESOLVE[@]}" "$@"; }
api() { curl -s --max-time 5 "${RESOLVE[@]}" "$@"; }

# ── Seed: ensure a handful of todos exist to toggle/delete ───────────────────
echo "Seeding initial todos..."
for title in "Review Istio mTLS setup" "Check Kiali service graph" \
             "Verify NetworkPolicies" "Monitor Grafana dashboards" \
             "Test Coraza WAF rules"; do
  api -s -X POST "$BASE/api/todos" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$title\",\"completed\":false}" -o /dev/null
done
echo "Done."
echo ""

# ── Main loop ────────────────────────────────────────────────────────────────
END=$(( $(date +%s) + DURATION ))
TICK=0

echo "Running traffic for ${DURATION}s... (Ctrl-C to stop early)"
echo ""

while [[ $(date +%s) -lt $END ]]; do
  TICK=$(( TICK + 1 ))

  # ── Frontend page loads (IngressGateway → frontend) ──────────────────────
  req "$BASE/"
  req "$BASE/"

  # ── API reads (IngressGateway → backend → postgres) ──────────────────────
  TODO_LIST=$(api "$BASE/api/todos")
  req "$BASE/api/todos"

  # ── API write (create) ───────────────────────────────────────────────────
  NEW_ID=$(api -X POST "$BASE/api/todos" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Task $RANDOM\",\"completed\":false}" | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  # ── API update (toggle an existing todo) ─────────────────────────────────
  TOGGLE_ID=$(echo "$TODO_LIST" | python3 -c "
import sys,json,random
try:
  todos=[t for t in json.load(sys.stdin) if t.get('id')]
  if todos: print(random.choice(todos)['id'])
except: pass
" 2>/dev/null)
  if [[ -n "$TOGGLE_ID" ]]; then
    CURRENT=$(echo "$TODO_LIST" | python3 -c "
import sys,json
try:
  todos={t['id']:t for t in json.load(sys.stdin)}
  t=todos.get($TOGGLE_ID,{})
  print(str(not t.get('completed',False)).lower())
except: print('true')
" 2>/dev/null || echo "true")
    req -X PATCH "$BASE/api/todos/$TOGGLE_ID" \
      -H "Content-Type: application/json" \
      -d "{\"completed\":$CURRENT}"
  fi

  # ── API delete (remove the todo we just created) ─────────────────────────
  if [[ -n "$NEW_ID" ]]; then
    req -X DELETE "$BASE/api/todos/$NEW_ID"
  fi

  # ── Progress output every 10 ticks ───────────────────────────────────────
  if (( TICK % 10 == 0 )); then
    REMAINING=$(( END - $(date +%s) ))
    printf "  tick %-4d | ~%ds remaining | flows: GW→frontend, GW→backend→postgres\n" \
      "$TICK" "$REMAINING"
  fi

  sleep 0.8
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done — ${TICK} request cycles sent"
echo ""
echo "  Kiali:  http://172.20.20.24:20001"   # CHANGEME if subnet differs
echo "    Graph → Namespaces: frontend, backend, data"
echo "    Display → ✔ Security  ✔ Traffic Animation"
echo "    Edge labels: Request rate / Response time"
echo "    Time range: Last 1m   Refresh: 30s"
echo ""
echo "  Jaeger: http://172.20.20.25:16686"   # CHANGEME if subnet differs
echo "    Service: istio-ingressgateway  Operation: all"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
