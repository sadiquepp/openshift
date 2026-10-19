#!/usr/bin/env bash
#
# verify-baseline.sh — phase 1 of observability/aiops
#
# Pins down the facts that phases 2 and 3 are built on. READ-ONLY: it runs
# `oc get`, instant PromQL queries through thanos-querier, and Tempo reads over
# a temporary port-forward. It creates, patches and deletes nothing.
#
# It does not exit on the first problem. The point is a full picture, so it
# collects findings and prints a VALUES FOR PHASE 2 block at the end. The exit
# code is non-zero only if a hard prerequisite is missing.
#
# Usage:
#   export KUBECONFIG=~/clusters/lab/auth/kubeconfig
#   ./scripts/verify-baseline.sh
#
# Env (defaults match ../ansible/group_vars/all.yml):
#   APP_NAMESPACE=online-boutique
#   TRACING_NAMESPACE=tracing-system
#   TEMPO_STACK=tempo
#   TEMPO_TENANT=dev
#   LOOKBACK=1h          window for the trace search
#   RATE_WINDOW=5m       range selector for the latency queries
#
# Let the load generator run for ~10 minutes before trusting the numbers: the
# spanmetrics connector flushes every 15s and Prometheus scrapes every 30s.

set -uo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-online-boutique}"
TRACING_NAMESPACE="${TRACING_NAMESPACE:-tracing-system}"
TEMPO_STACK="${TEMPO_STACK:-tempo}"
TEMPO_TENANT="${TEMPO_TENANT:-dev}"
LOOKBACK="${LOOKBACK:-1h}"
RATE_WINDOW="${RATE_WINDOW:-5m}"
PF_PORT="${PF_PORT:-18080}"

c_red=$'\033[1;31m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'
c_blue=$'\033[1;34m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'

hard_fail=0
pf_pid=""

section() { printf '\n%s== %s%s\n' "$c_blue" "$*" "$c_reset"; }
ok()      { printf '  %s[ ok ]%s %s\n'   "$c_green"  "$c_reset" "$*"; }
warn()    { printf '  %s[warn]%s %s\n'   "$c_yellow" "$c_reset" "$*"; }
bad()     { printf '  %s[fail]%s %s\n'   "$c_red"    "$c_reset" "$*"; }
note()    { printf '  %s%s%s\n'          "$c_dim"    "$*" "$c_reset"; }

cleanup() {
  [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null
  wait "$pf_pid" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Values we carry to the summary.
METRIC_BASE=""
SPAN_PLACEORDER=""
SPAN_GETPRODUCT=""
P50_PLACEORDER="?"
P99_PLACEORDER="?"
P50_GETPRODUCT="?"
BUCKETS=""
EXTRA_LATENCY_STATE="?"
TEMPO_URL=""
TEMPO_SEARCH_OK="no"
RECO_FANOUT="?"
POST_SHARE="?"
CART_BACKEND=""
UNIT="?"
START=0
NOW=0

# ─────────────────────────────────────────────────────────────────────────────
# 0. Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
section "0. Prerequisites"

OC="$(command -v oc || true)"
if [[ -z "$OC" ]]; then
  bad "oc not on PATH"
  exit 1
fi

if ! WHO="$("$OC" whoami 2>/dev/null)"; then
  bad "not logged in — set KUBECONFIG or run 'oc login'"
  exit 1
fi
ok "logged in as ${WHO}"

if ! TOKEN="$("$OC" whoami -t 2>/dev/null)" || [[ -z "$TOKEN" ]]; then
  bad "could not read a bearer token ('oc whoami -t'). Certificate-only"
  note "kubeconfigs cannot query Thanos or Tempo — log in with a token."
  exit 1
fi

THANOS="$("$OC" get route thanos-querier -n openshift-monitoring \
  -o jsonpath='{.spec.host}' 2>/dev/null)"
if [[ -z "$THANOS" ]]; then
  bad "no thanos-querier route in openshift-monitoring"
  hard_fail=1
else
  ok "thanos-querier at ${THANOS}"
fi

TEMPO_READY="$("$OC" get tempostack "$TEMPO_STACK" -n "$TRACING_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
if [[ "$TEMPO_READY" == "True" ]]; then
  ok "TempoStack/${TEMPO_STACK} Ready"
else
  bad "TempoStack/${TEMPO_STACK} not Ready (got '${TEMPO_READY:-<none>}')"
  hard_fail=1
fi

COLLECTOR_PODS="$("$OC" get pods -n "$TRACING_NAMESPACE" \
  -l app.kubernetes.io/component=opentelemetry-collector \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${COLLECTOR_PODS:-0}" -gt 0 ]]; then
  ok "${COLLECTOR_PODS} collector pod(s) Running"
else
  warn "no Running collector pod found by label — check 'oc get pods -n ${TRACING_NAMESPACE}'"
fi

UWM_PODS="$("$OC" get pods -n openshift-user-workload-monitoring \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${UWM_PODS:-0}" -gt 0 ]]; then
  ok "${UWM_PODS} user-workload-monitoring pod(s) Running"
else
  bad "user workload monitoring is not running — spanmetrics are not being scraped"
  hard_fail=1
fi

# ─────────────────────────────────────────────────────────────────────────────
# PromQL helper
# ─────────────────────────────────────────────────────────────────────────────
promql() {
  # $1 = query. Prints the raw JSON response on stdout.
  curl -sSk --max-time 30 \
    -H "Authorization: Bearer ${TOKEN}" \
    -G --data-urlencode "query=$1" \
    "https://${THANOS}/api/v1/query" 2>/dev/null
}

# Reads a Prometheus instant-query response on stdin and prints one
# "<label-value>\t<sample-value>" line per series, sorted by sample descending.
pq_pairs() {
  local label="$1"
  python3 -c '
import json, sys
label = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("status") != "success":
    sys.exit(0)
rows = []
for r in d.get("data", {}).get("result", []):
    key = r.get("metric", {}).get(label, "")
    try:
        val = float(r.get("value", [0, "nan"])[1])
    except (TypeError, ValueError):
        val = float("nan")
    rows.append((key, val))
rows.sort(key=lambda x: (x[1] != x[1], -x[1]))
for k, v in rows:
    print("%s\t%g" % (k, v))
' "$label"
}

# Reads an instant-query response on stdin and prints the single scalar value.
pq_scalar() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    r = d["data"]["result"]
    print("%g" % float(r[0]["value"][1]) if r else "?")
except Exception:
    print("?")
'
}

if [[ "$hard_fail" -ne 0 ]]; then
  printf '\n%sPrerequisites failed — fix the above before trusting anything below.%s\n' \
    "$c_red" "$c_reset"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Which spanmetrics series exist, and what are they called
# ─────────────────────────────────────────────────────────────────────────────
section "1. spanmetrics metric names and span_name label values"

NAMES="$(curl -sSk --max-time 30 -H "Authorization: Bearer ${TOKEN}" \
  "https://${THANOS}/api/v1/label/__name__/values" 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for n in d.get("data", []) or []:
    if "span_metrics" in n or "spanmetrics" in n:
        print(n)
')"

if [[ -z "$NAMES" ]]; then
  bad "no spanmetrics series in Thanos at all"
  note "Check the ServiceMonitor selector first — it is the usual cause and it"
  note "fails silently: up{namespace=\"${TRACING_NAMESPACE}\"} should be two series."
  note "See ../README.md 'Scrape the collector'."
else
  ok "spanmetrics series present:"
  while IFS= read -r n; do
    [[ -n "$n" ]] && printf '       %s\n' "$n"
  done <<<"$NAMES"
fi

# Prefer the duration histogram; record whether it is ms or seconds.
if grep -q '^traces_span_metrics_duration_milliseconds_bucket$' <<<"$NAMES"; then
  METRIC_BASE="traces_span_metrics_duration_milliseconds"
  UNIT="ms"
elif grep -q '^traces_span_metrics_duration_seconds_bucket$' <<<"$NAMES"; then
  METRIC_BASE="traces_span_metrics_duration_seconds"
  UNIT="s"
  warn "durations are in SECONDS, not milliseconds — phase 2 thresholds must match"
else
  METRIC_BASE=""
  UNIT="?"
  bad "no traces_span_metrics_duration_*_bucket series found"
fi
[[ -n "$METRIC_BASE" ]] && ok "using ${METRIC_BASE} (unit: ${UNIT})"

if [[ -n "$METRIC_BASE" ]]; then
  for svc in checkoutservice productcatalogservice; do
    printf '\n  span_name values for service_name=%s:\n' "$svc"
    OUT="$(promql "count by (span_name) (${METRIC_BASE}_count{service_name=\"${svc}\"})" | pq_pairs span_name)"
    if [[ -z "$OUT" ]]; then
      warn "none — is ${svc} emitting spans? has the load generator been running?"
    else
      while IFS=$'\t' read -r name _; do
        printf '    %s\n' "$name"
      done <<<"$OUT"
      case "$svc" in
        checkoutservice)
          SPAN_PLACEORDER="$(grep -i 'placeorder' <<<"$OUT" | head -1 | cut -f1)" ;;
        productcatalogservice)
          SPAN_GETPRODUCT="$(grep -iE 'getproduct' <<<"$OUT" | head -1 | cut -f1)" ;;
      esac
    fi
  done

  printf '\n'
  if [[ -n "$SPAN_PLACEORDER" ]]; then
    ok "PlaceOrder span name: ${SPAN_PLACEORDER}"
  else
    bad "could not find a PlaceOrder span name on checkoutservice"
    note "Phase 2's alert expression depends on this exact string."
  fi
  if [[ -n "$SPAN_GETPRODUCT" ]]; then
    ok "GetProduct span name (server side): ${SPAN_GETPRODUCT}"
  else
    warn "could not find a GetProduct span name on productcatalogservice"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Baselines and bucket boundaries
# ─────────────────────────────────────────────────────────────────────────────
section "2. Current baselines and histogram buckets"

if [[ -n "$METRIC_BASE" ]]; then
  BUCKETS="$(promql "count by (le) (${METRIC_BASE}_bucket{service_name=\"checkoutservice\"})" \
    | pq_pairs le | cut -f1 | python3 -c '
import sys
vals = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        vals.append((float(line), line))
    except ValueError:
        vals.append((float("inf"), line))
vals.sort()
print(", ".join(v[1] for v in vals))
')"
  if [[ -n "$BUCKETS" ]]; then
    ok "bucket boundaries (le, in ${UNIT}): ${BUCKETS}"
    _nb="$(tr ',' '\n' <<<"$BUCKETS" | grep -c .)"
    if [[ "${_nb:-0}" -le 8 ]]; then
      warn "only ${_nb} boundaries — histogram_quantile will report an edge"
      note "rather than a measurement near this workload's baseline."
      note "Fix: ./scripts/setup-alerting.sh buckets"
    fi
  else
    warn "could not read bucket boundaries"
  fi

  if [[ -n "$SPAN_PLACEORDER" ]]; then
    q_base="sum by (le) (rate(${METRIC_BASE}_bucket{service_name=\"checkoutservice\",span_name=\"${SPAN_PLACEORDER}\"}[${RATE_WINDOW}]))"
    P50_PLACEORDER="$(promql "histogram_quantile(0.50, ${q_base})" | pq_scalar)"
    P99_PLACEORDER="$(promql "histogram_quantile(0.99, ${q_base})" | pq_scalar)"
    ok "PlaceOrder  p50=${P50_PLACEORDER}${UNIT}  p99=${P99_PLACEORDER}${UNIT}"

    RPS="$(promql "sum(rate(${METRIC_BASE}_count{service_name=\"checkoutservice\",span_name=\"${SPAN_PLACEORDER}\"}[${RATE_WINDOW}]))" | pq_scalar)"
    ok "PlaceOrder  rate=${RPS} rps"
    if [[ "$RPS" != "?" ]] && python3 -c "import sys; sys.exit(0 if float('${RPS}') < 0.05 else 1)" 2>/dev/null; then
      warn "that rate is very low — the load generator may not be placing orders"
    fi
  fi

  if [[ -n "$SPAN_GETPRODUCT" ]]; then
    q_gp="sum by (le) (rate(${METRIC_BASE}_bucket{service_name=\"productcatalogservice\",span_name=\"${SPAN_GETPRODUCT}\"}[${RATE_WINDOW}]))"
    P50_GETPRODUCT="$(promql "histogram_quantile(0.50, ${q_gp})" | pq_scalar)"
    ok "GetProduct (server span) p50=${P50_GETPRODUCT}${UNIT}"
    note "This is the number the analyzer compares against under fault."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Is the fault already applied
# ─────────────────────────────────────────────────────────────────────────────
section "3. Fault state"

EL="$("$OC" get deploy productcatalogservice -n "$APP_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXTRA_LATENCY")].value}' 2>/dev/null)"
if [[ -z "$EL" ]]; then
  EXTRA_LATENCY_STATE="unset"
  ok "EXTRA_LATENCY is unset on productcatalogservice (clean baseline)"
else
  EXTRA_LATENCY_STATE="$EL"
  warn "EXTRA_LATENCY is already set to '${EL}' — baselines above are NOT clean"
  note "Clear it with: oc set env deploy/productcatalogservice -n ${APP_NAMESPACE} EXTRA_LATENCY-"
fi

REPLICAS="$("$OC" get deploy productcatalogservice -n "$APP_NAMESPACE" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null)"
note "productcatalogservice replicas: ${REPLICAS:-?} (all must carry the flag for a clean fault)"

CART_BACKEND="$("$OC" get deploy cartservice -n "$APP_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REDIS_ADDR")].value}' 2>/dev/null)"
if [[ -n "$CART_BACKEND" ]]; then
  ok "beat A target path: cartservice → ${CART_BACKEND}"
else
  warn "could not read REDIS_ADDR from cartservice — confirm the beat A path by hand"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Tempo gateway: resolve the query URL and prove a token gets through
# ─────────────────────────────────────────────────────────────────────────────
section "4. Tempo gateway query path"

GW_SVC="tempo-${TEMPO_STACK}-gateway"
PORTS="$("$OC" get svc "$GW_SVC" -n "$TRACING_NAMESPACE" \
  -o jsonpath='{range .spec.ports[*]}{.name}={.port} {end}' 2>/dev/null)"
if [[ -z "$PORTS" ]]; then
  bad "no Service/${GW_SVC} in ${TRACING_NAMESPACE}"
else
  ok "Service/${GW_SVC} ports: ${PORTS}"
fi

GW_PORT="$("$OC" get svc "$GW_SVC" -n "$TRACING_NAMESPACE" \
  -o jsonpath='{.spec.ports[?(@.name=="public")].port}' 2>/dev/null)"
[[ -z "$GW_PORT" ]] && GW_PORT=8080
note "using gateway port ${GW_PORT} for queries"

"$OC" port-forward -n "$TRACING_NAMESPACE" "svc/${GW_SVC}" \
  "${PF_PORT}:${GW_PORT}" >/dev/null 2>&1 &
pf_pid=$!

for _ in $(seq 1 20); do
  if (exec 3<>/dev/tcp/127.0.0.1/"${PF_PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null
    break
  fi
  sleep 0.5
done

if ! kill -0 "$pf_pid" 2>/dev/null; then
  bad "port-forward to ${GW_SVC}:${GW_PORT} did not start"
  pf_pid=""
else
  NOW="$(date +%s)"
  case "$LOOKBACK" in
    *h) START=$(( NOW - ${LOOKBACK%h} * 3600 )) ;;
    *m) START=$(( NOW - ${LOOKBACK%m} * 60 )) ;;
    *)  START=$(( NOW - 3600 )) ;;
  esac

  TRACEQL='{ resource.service.name = "checkoutservice" }'

  for scheme in https http; do
    URL="${scheme}://127.0.0.1:${PF_PORT}/api/traces/v1/${TEMPO_TENANT}/tempo/api/search"
    BODY="$(curl -sSk --max-time 25 \
      -H "Authorization: Bearer ${TOKEN}" \
      -G --data-urlencode "q=${TRACEQL}" \
      --data-urlencode "limit=5" \
      --data-urlencode "start=${START}" \
      --data-urlencode "end=${NOW}" \
      "$URL" 2>/dev/null)"
    if grep -q '"traces"' <<<"$BODY" 2>/dev/null; then
      TEMPO_URL="${scheme}://${GW_SVC}.${TRACING_NAMESPACE}.svc.cluster.local:${GW_PORT}/api/traces/v1/${TEMPO_TENANT}/tempo"
      TEMPO_SEARCH_OK="yes"
      ok "TraceQL search works over ${scheme}"
      ok "in-cluster base URL for phase 3: ${TEMPO_URL}"
      break
    fi
  done

  if [[ "$TEMPO_SEARCH_OK" != "yes" ]]; then
    bad "TraceQL search did not return a trace list on either scheme"
    note "Last response (truncated): ${BODY:0:300}"
    note "If this is a 401/403, the account needs tempostack-traces-reader for"
    note "tenant '${TEMPO_TENANT}'. See ../README.md and ../demo/README.md."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Trace shape: does the post-charge work actually appear
# ─────────────────────────────────────────────────────────────────────────────
section "5. Trace shape of one checkout"

if [[ "$TEMPO_SEARCH_OK" != "yes" ]]; then
  warn "skipped — no working Tempo query path"
else
  SCHEME="${TEMPO_URL%%://*}"
  BASE="${SCHEME}://127.0.0.1:${PF_PORT}/api/traces/v1/${TEMPO_TENANT}/tempo"

  # Select on the server with TraceQL rather than picking a maximum from
  # whatever the search happened to return.
  #
  # Sorting client-side was wrong twice over: Tempo's search returns recent
  # matches rather than slow ones, and if the response carries no durationMs
  # every candidate ties at zero, so the first one wins and gets *labelled* the
  # slowest. With a fault minutes old inside an hour-long window, that reliably
  # produced a pre-fault trace while the metrics said the fault was live. A
  # duration floor in the query means every candidate is genuinely slow.
  FLOOR_MS="${MIN_TRACE_MS:-0}"
  if [[ "$FLOOR_MS" == "0" && -n "$EXTRA_LATENCY_STATE" && "$EXTRA_LATENCY_STATE" != "unset" && "$EXTRA_LATENCY_STATE" != "?" ]]; then
    FLOOR_MS=250
    note "EXTRA_LATENCY is active — asking Tempo for traces over ${FLOOR_MS}ms"
    note "so the shape below is the faulted one, not one from before injection"
  fi

  search_traces() {
    # $1 = TraceQL. Emits "traceID<TAB>durationMs" per hit, plus a trailing
    # "#meta<TAB>count<TAB>have_duration" line.
    curl -sSk --max-time 25 \
      -H "Authorization: Bearer ${TOKEN}" \
      -G --data-urlencode "q=$1" \
      --data-urlencode "limit=50" \
      --data-urlencode "start=${START}" \
      --data-urlencode "end=${NOW}" \
      "${BASE}/api/search" 2>/dev/null \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("#meta\t0\tno"); sys.exit(0)
rows, have = [], False
for t in d.get("traces") or []:
    tid = t.get("traceID") or t.get("traceId")
    raw = t.get("durationMs")
    if raw not in (None, ""):
        have = True
    try:
        ms = float(raw or 0)
    except (TypeError, ValueError):
        ms = 0.0
    if tid:
        rows.append((ms, tid))
rows.sort(reverse=True)
for ms, tid in rows:
    print("%s\t%g" % (tid, ms))
print("#meta\t%d\t%s" % (len(rows), "yes" if have else "no"))
'
  }

  TRACEQL_BASE='resource.service.name = "checkoutservice"'
  if [[ "$FLOOR_MS" != "0" ]]; then
    HITS="$(search_traces "{ ${TRACEQL_BASE} && trace:duration > ${FLOOR_MS}ms }")"
    if [[ -z "$(grep -v '^#meta' <<<"$HITS")" ]]; then
      warn "no trace over ${FLOOR_MS}ms in the last ${LOOKBACK}"
      note "Either the fault has not reached Tempo yet, or this Tempo does not"
      note "support the trace:duration filter. Falling back to an unfiltered"
      note "search — check the durations below before trusting the shape."
      HITS="$(search_traces "{ ${TRACEQL_BASE} }")"
    fi
  else
    HITS="$(search_traces "{ ${TRACEQL_BASE} }")"
  fi

  META="$(grep '^#meta' <<<"$HITS" | head -1)"
  CANDIDATES="$(grep -v '^#meta' <<<"$HITS")"
  N_HITS="$(cut -f2 <<<"$META")"
  HAVE_DUR="$(cut -f3 <<<"$META")"
  note "search returned ${N_HITS:-0} trace(s); durationMs reported: ${HAVE_DUR:-no}"
  if [[ "$HAVE_DUR" == "no" ]]; then
    warn "this Tempo's search omits durationMs, so the pick below is arbitrary"
    note "rather than the slowest — read the span table, not the label."
  fi

  TRACE_ID="$(head -1 <<<"$CANDIDATES" | cut -f1)"
  TRACE_MS="$(head -1 <<<"$CANDIDATES" | cut -f2)"

  if [[ -z "$TRACE_ID" ]]; then
    warn "search returned no trace IDs in the last ${LOOKBACK}"
  else
    ok "checkout trace ${TRACE_ID} (search reported ${TRACE_MS:-?}ms)"
    SPANS="$(curl -sSk --max-time 25 -H "Authorization: Bearer ${TOKEN}" \
      "${BASE}/api/traces/${TRACE_ID}" 2>/dev/null \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = []
for rs in d.get("batches") or d.get("resourceSpans") or []:
    svc = "?"
    res = rs.get("resource") or {}
    for a in res.get("attributes") or []:
        if a.get("key") == "service.name":
            v = a.get("value") or {}
            svc = v.get("stringValue") or v.get("string_value") or "?"
    for ss in rs.get("scopeSpans") or rs.get("instrumentationLibrarySpans") or []:
        for sp in ss.get("spans") or []:
            try:
                start = int(sp.get("startTimeUnixNano") or 0)
                end = int(sp.get("endTimeUnixNano") or 0)
            except (TypeError, ValueError):
                start = end = 0
            rows.append((start, svc, sp.get("name") or "?", (end - start) / 1e6,
                         sp.get("kind") or ""))
rows.sort()
t0 = rows[0][0] if rows else 0
print("    %-10s %-24s %-52s %9s" % ("offset", "service", "span", "duration"))
for start, svc, name, ms, kind in rows:
    print("    %8.1fms %-24s %-52s %7.2fms" % ((start - t0) / 1e6, svc[:24], name[:52], ms))
print("TOTAL_SPANS=%d" % len(rows))

# The number the demo actually rests on: how much of the request happens after
# the card is charged. Computed rather than eyeballed off the offsets, because
# it is the claim beat B is built on and it moves with cart size.
if rows:
    span_end = max(s + int(ms * 1e6) for s, _, _, ms, _ in rows)
    total_ms = (span_end - t0) / 1e6
    charge_end = None
    for start, svc, name, ms, kind in rows:
        if "PaymentService/Charge" in name and svc == "checkoutservice":
            charge_end = start + int(ms * 1e6)
            break
    if charge_end is not None:
        post_ms = (span_end - charge_end) / 1e6
        pct = (post_ms / total_ms * 100) if total_ms > 0 else 0
        print("SUMMARY\ttotal=%.1f\tcharge_at=%.1f\tpost=%.1f\tpct=%.0f"
              % (total_ms, (charge_end - t0) / 1e6, post_ms, pct))
    else:
        print("SUMMARY\ttotal=%.1f\tcharge_at=\tpost=\tpct=" % total_ms)
')"
    if [[ -z "$SPANS" ]]; then
      warn "could not parse the trace payload"
    else
      printf '%s\n' "$SPANS" | grep -vE '^(TOTAL_SPANS=|SUMMARY)'
      N="$(grep -o 'TOTAL_SPANS=[0-9]*' <<<"$SPANS" | cut -d= -f2)"
      ok "${N:-?} spans in that trace"

      SUMMARY_LINE="$(grep '^SUMMARY' <<<"$SPANS" | head -1)"
      if [[ -n "$SUMMARY_LINE" ]]; then
        TOTAL_MS="$(sed -n 's/.*total=\([0-9.]*\).*/\1/p' <<<"$SUMMARY_LINE")"
        CHARGE_AT="$(sed -n 's/.*charge_at=\([0-9.]*\).*/\1/p' <<<"$SUMMARY_LINE")"
        POST_MS="$(sed -n 's/.*post=\([0-9.]*\).*/\1/p' <<<"$SUMMARY_LINE")"
        POST_PCT="$(sed -n 's/.*pct=\([0-9]*\).*/\1/p' <<<"$SUMMARY_LINE")"
        printf '\n'
        if [[ -n "$CHARGE_AT" ]]; then
          ok "request total ${TOTAL_MS}ms; charge completed at ${CHARGE_AT}ms"
          ok "post-charge wait ${POST_MS}ms — ${POST_PCT}% of the request"
          POST_SHARE="${POST_PCT}% (${POST_MS}ms of ${TOTAL_MS}ms)"
        else
          warn "no checkoutservice PaymentService/Charge span — cannot split pre/post charge"
          POST_SHARE="n/a"
        fi
      fi

      RECO_FANOUT="$(printf '%s\n' "$SPANS" | grep -ci 'recommendation' || true)"
      printf '\n'
      if [[ "${RECO_FANOUT:-0}" -gt 0 ]]; then
        ok "recommendationservice appears ${RECO_FANOUT}× in this trace"
        note "Check the offsets above: spans starting AFTER the Charge span are"
        note "the post-charge wait that beat B is built on."
      else
        warn "no recommendationservice spans in this trace"
        note "This trace may be a server-side checkoutservice trace rather than"
        note "the frontend POST. Re-check with a frontend-rooted trace before"
        note "committing to the post-charge narrative — it is beat B's punchline."
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
section "VALUES FOR PHASE 2"

cat <<SUMMARY
  metric base          ${METRIC_BASE:-<none>}   (unit: ${UNIT:-?})
  PlaceOrder span      ${SPAN_PLACEORDER:-<not found>}
  GetProduct span      ${SPAN_GETPRODUCT:-<not found>}
  PlaceOrder p50/p99   ${P50_PLACEORDER} / ${P99_PLACEORDER} ${UNIT:-}
  GetProduct p50       ${P50_GETPRODUCT} ${UNIT:-}
  bucket boundaries    ${BUCKETS:-<unknown>}
  EXTRA_LATENCY        ${EXTRA_LATENCY_STATE}
  cart backend         ${CART_BACKEND:-<unknown>}
  Tempo query base     ${TEMPO_URL:-<unresolved>}
  TraceQL search       ${TEMPO_SEARCH_OK}
  reco spans in trace  ${RECO_FANOUT}
  post-charge share    ${POST_SHARE}
SUMMARY

printf '\n%sPaste this block back to continue with phase 2.%s\n' "$c_dim" "$c_reset"
exit 0
