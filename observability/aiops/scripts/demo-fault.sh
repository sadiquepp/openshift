#!/usr/bin/env bash
#
# demo-fault.sh — beat B's fault, phase 2 of observability/aiops
#
# Injects latency inside productcatalogservice with the upstream EXTRA_LATENCY
# variable: no chaos tooling, no privilege, one rollout, instantly reversible.
#
# Why this fault and not netem: EXTRA_LATENCY is a time.Sleep() at the top of
# ListProducts, GetProduct and SearchProducts, so the delay is genuinely
# in-process. Flows stay clean — TCP RTT is unaffected because the socket is
# accepted promptly and the handler simply sleeps — which makes "it is not the
# network" a measured fact rather than a presenter's claim.
#
# Measured on this cluster at 400ms, the delay lands in three places:
#   inside PlaceOrder     1x GetProduct PER CART ITEM   0.4s x items
#   recommendationservice 1x ListProducts               ~0.4s
#   confirmation page     5x GetProduct from frontend   ~2.0s
#
# The per-cart-item multiplier is the part worth knowing: PlaceOrder p99 was
# measured at 2424ms under this fault, not the ~400ms a single-item cart
# suggests, because the load generator's carts hold several items. So the alert
# captures a large share of the fault, and the post-charge remainder — the
# confirmation page's lookups, which happen after the card is charged and which
# no metric can reach — is smaller than a single-item trace implies. Read the
# real split from verify-baseline.sh's post-charge share rather than assuming.
#
# Subcommands:
#   loadgen [n]   scale the load generator (default 5) for a stable p99
#   inject [ms]   set EXTRA_LATENCY (default 400ms)
#   revert        unset it, and restore the load generator
#   status        fault state, live p99, router 5xx, and the timeout headroom
#   watch         poll the p99 until it crosses the alert threshold
#   route-timeout [dur]  raise the frontend Route's HAProxy timeout (default 120s)
#
# Usage:
#   export KUBECONFIG=~/.kube/config
#   ./scripts/demo-fault.sh loadgen
#   ./scripts/demo-fault.sh inject
#   ./scripts/demo-fault.sh watch
#   ./scripts/demo-fault.sh revert
#
# Env:
#   APP_NAMESPACE=online-boutique
#   LATENCY=400ms
#   LOADGEN_REPLICAS=5

set -uo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-online-boutique}"
TARGET_DEPLOY="productcatalogservice"
LOADGEN_DEPLOY="loadgenerator"
LATENCY="${LATENCY:-400ms}"
LOADGEN_REPLICAS="${LOADGEN_REPLICAS:-5}"
THRESHOLD_MS=250
ROUTE_NAME="${ROUTE_NAME:-frontend}"
# OpenShift Routes default to a 30s HAProxy timeout. Past it the router closes
# the client connection and returns 504 — and crucially the TRACE STILL LOOKS
# HEALTHY, because HAProxy drops the caller while the frontend handler runs on
# and its span completes normally. So the customer sees an error, the waterfall
# shows a merely slow request, and nothing in the telemetry disagrees. On a
# stage that is the worst failure available: the agent narrates latency while
# the audience watched a 504.
ROUTER_TIMEOUT_MS=30000

c_red=$'\033[1;31m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'
c_blue=$'\033[1;34m'; c_dim=$'\033[2m'; c_reset=$'\033[0m'

section() { printf '\n%s== %s%s\n' "$c_blue" "$*" "$c_reset"; }
ok()      { printf '  %s[ ok ]%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn()    { printf '  %s[warn]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
bad()     { printf '  %s[fail]%s %s\n' "$c_red"    "$c_reset" "$*"; }
note()    { printf '  %s%s%s\n'        "$c_dim"    "$*" "$c_reset"; }
die()     { bad "$*"; exit 1; }

OC="$(command -v oc || true)"
[[ -n "$OC" ]] || die "oc not on PATH"
"$OC" whoami >/dev/null 2>&1 || die "not logged in — see README 'Run it'"

CMD="${1:-status}"
ARG="${2:-}"

placeorder_p99() {
  local thanos token q
  thanos="$("$OC" get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  token="$("$OC" whoami -t 2>/dev/null)"
  [[ -n "$thanos" && -n "$token" ]] || { echo "?"; return; }
  q='histogram_quantile(0.99, sum by (le) (rate(traces_span_metrics_duration_milliseconds_bucket{service_name="checkoutservice",span_name="hipstershop.CheckoutService/PlaceOrder"}[5m])))'
  curl -sSk --max-time 25 -H "Authorization: Bearer ${token}" \
    -G --data-urlencode "query=${q}" "https://${thanos}/api/v1/query" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    r = d["data"]["result"]
    print("%.0f" % float(r[0]["value"][1]) if r else "?")
except Exception:
    print("?")
'
}

promql_scalar() {
  local thanos token
  thanos="$("$OC" get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  token="$("$OC" whoami -t 2>/dev/null)"
  [[ -n "$thanos" && -n "$token" ]] || { echo "?"; return; }
  curl -sSk --max-time 25 -H "Authorization: Bearer ${token}" \
    -G --data-urlencode "query=$1" "https://${thanos}/api/v1/query" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    r = d["data"]["result"]
    print("%g" % float(r[0]["value"][1]) if r else "0")
except Exception:
    print("?")
'
}

# 5xx seen by the router, not by the application. A HAProxy timeout never
# reaches the app, so this is the only place it is visible.
router_5xx() {
  promql_scalar "sum(rate(haproxy_server_http_responses_total{route=\"${ROUTE_NAME}\",code=\"5xx\"}[5m]))"
}

route_timeout_now() {
  "$OC" get route "$ROUTE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/timeout}' 2>/dev/null
}

current_latency() {
  "$OC" get deploy "$TARGET_DEPLOY" -n "$APP_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXTRA_LATENCY")].value}' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
do_loadgen() {
  local n="${ARG:-$LOADGEN_REPLICAS}"
  section "Scale the load generator to ${n}"

  "$OC" get deploy "$LOADGEN_DEPLOY" -n "$APP_NAMESPACE" >/dev/null 2>&1 \
    || die "no deploy/${LOADGEN_DEPLOY} in ${APP_NAMESPACE} (deployed with the no-loadgenerator overlay?)"

  "$OC" scale deploy "$LOADGEN_DEPLOY" -n "$APP_NAMESPACE" --replicas="$n" >/dev/null \
    && ok "scaled to ${n}" || die "scale failed"
  "$OC" rollout status deploy/"$LOADGEN_DEPLOY" -n "$APP_NAMESPACE" --timeout=180s 2>/dev/null \
    || warn "rollout not confirmed"

  note "Measured baseline was 0.089 rps — about 11 PlaceOrder samples in the"
  note "alert's 5m window, which is too few for a p99 to sit still on stage."
  note "This raises it roughly in proportion. Allow ~5 minutes for the rate"
  note "window to refill before reading any percentile."
}

# ─────────────────────────────────────────────────────────────────────────────
do_inject() {
  local ms="${ARG:-$LATENCY}"
  section "Inject ${ms} into ${TARGET_DEPLOY}"

  local existing
  existing="$(current_latency)"
  [[ -n "$existing" ]] && warn "EXTRA_LATENCY is already ${existing} — replacing"

  local before
  before="$(placeorder_p99)"
  note "PlaceOrder p99 before: ${before}ms"

  "$OC" set env deploy/"$TARGET_DEPLOY" -n "$APP_NAMESPACE" "EXTRA_LATENCY=${ms}" >/dev/null \
    && ok "EXTRA_LATENCY=${ms}" || die "could not set the variable"

  "$OC" rollout status deploy/"$TARGET_DEPLOY" -n "$APP_NAMESPACE" --timeout=180s 2>/dev/null \
    && ok "rollout complete" || warn "rollout not confirmed"

  printf '\n'
  ok "the pod logs now carry the second signal:"
  note "  oc logs -n ${APP_NAMESPACE} deploy/${TARGET_DEPLOY} | grep -i 'extra latency'"
  note "It is emitted at startup, so its timestamp matches the latency onset."
  note "That is what names the cause — the trace cannot, because a sleep emits"
  note "no span."

  printf '\n'
  note "Expect the alert in roughly 3-5 minutes: the 5m rate window has to fill"
  note "with slow samples, then the rule's 'for: 2m' has to elapse."
  note "Follow it with: $0 watch"
}

# ─────────────────────────────────────────────────────────────────────────────
do_revert() {
  section "Revert"

  if [[ -z "$(current_latency)" ]]; then
    ok "EXTRA_LATENCY already unset"
  else
    "$OC" set env deploy/"$TARGET_DEPLOY" -n "$APP_NAMESPACE" EXTRA_LATENCY- >/dev/null \
      && ok "EXTRA_LATENCY removed" || warn "could not remove the variable"
    "$OC" rollout status deploy/"$TARGET_DEPLOY" -n "$APP_NAMESPACE" --timeout=180s 2>/dev/null \
      || warn "rollout not confirmed"
  fi

  "$OC" scale deploy "$LOADGEN_DEPLOY" -n "$APP_NAMESPACE" --replicas=1 >/dev/null 2>&1 \
    && ok "load generator back to 1" || warn "could not scale the load generator"

  note "The alert resolves on the same delay it fired on — the 5m window has to"
  note "flush the slow samples first. sendResolved is on, so Slack gets the"
  note "all-clear rather than silence."
}

# ─────────────────────────────────────────────────────────────────────────────
do_status() {
  section "Fault state"
  local el reps p99
  el="$(current_latency)"
  if [[ -z "$el" ]]; then ok "EXTRA_LATENCY: unset (clean)"
  else warn "EXTRA_LATENCY: ${el} (fault active)"; fi

  reps="$("$OC" get deploy "$LOADGEN_DEPLOY" -n "$APP_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  note "load generator replicas: ${reps:-?}"

  p99="$(placeorder_p99)"
  if [[ "$p99" == "?" ]]; then
    warn "PlaceOrder p99: unavailable"
  elif python3 -c "import sys; sys.exit(0 if float('$p99') > $THRESHOLD_MS else 1)" 2>/dev/null; then
    warn "PlaceOrder p99: ${p99}ms — above the ${THRESHOLD_MS}ms threshold"
  else
    ok "PlaceOrder p99: ${p99}ms — below the ${THRESHOLD_MS}ms threshold"
  fi

  # ── router headroom ───────────────────────────────────────────────────────
  section "Router headroom"
  local rt limit_ms
  rt="$(route_timeout_now)"
  if [[ -n "$rt" ]]; then
    ok "route/${ROUTE_NAME} timeout annotation: ${rt}"
    # Compute headroom against the configured value rather than giving up on
    # it: once the annotation is set, its number is the one that matters.
    limit_ms="$(python3 -c '
import re, sys
m = re.match(r"^([0-9.]+)\s*(ms|s|m|h)$", sys.argv[1].strip())
if not m:
    print("?")
else:
    mult = {"ms": 1, "s": 1000, "m": 60000, "h": 3600000}[m.group(2)]
    print(int(float(m.group(1)) * mult))
' "$rt" 2>/dev/null || echo '?')"
  else
    warn "route/${ROUTE_NAME} has no timeout annotation — the 30s default applies"
    limit_ms="$ROUTER_TIMEOUT_MS"
  fi

  if [[ -n "$el" && "$limit_ms" != "?" ]]; then
    # Post-charge work is a fixed six sleeps regardless of cart size (one
    # ListProducts for the recommendations, five GetProduct for the
    # confirmation page). Everything before the charge scales with the cart, so
    # the ceiling is a cart size, not a latency.
    python3 - "$el" "$limit_ms" <<'PY'
import re, sys
raw, limit = sys.argv[1], float(sys.argv[2])
m = re.match(r'^([0-9.]+)\s*(ms|s)$', raw.strip())
if not m:
    sys.exit(0)
ms = float(m.group(1)) * (1000 if m.group(2) == 's' else 1)
if ms <= 0:
    sys.exit(0)
post = 6 * ms
items = (limit - post) / ms
print("  at %gms per call, post-charge work is ~%.1fs and the router cuts off" % (ms, post / 1000))
print("  at %.0fs, so a cart over ~%d items would 504 - and the trace would"
      % (limit / 1000, int(items)))
print("  still look healthy, because HAProxy drops the caller and the handler")
print("  runs on. Raise it with: ./scripts/demo-fault.sh route-timeout 120s")
PY
  fi

  local errs
  errs="$(router_5xx)"
  if [[ "$errs" == "?" ]]; then
    warn "router 5xx rate: unavailable"
  elif python3 -c "import sys; sys.exit(0 if float('$errs') > 0.001 else 1)" 2>/dev/null; then
    bad "router 5xx on route/${ROUTE_NAME}: ${errs}/s — requests ARE being cut off"
    note "This is the failure the traces cannot show you. Either lower the"
    note "latency or raise the route timeout before demoing."
  else
    ok "router 5xx on route/${ROUTE_NAME}: none"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
do_route_timeout() {
  local dur="${ARG:-120s}"
  section "Raise the frontend Route's HAProxy timeout to ${dur}"
  "$OC" annotate route "$ROUTE_NAME" -n "$APP_NAMESPACE" --overwrite \
    "haproxy.router.openshift.io/timeout=${dur}" >/dev/null \
    && ok "route/${ROUTE_NAME} timeout = ${dur}" \
    || die "could not annotate the route"
  note "Cheap insurance rather than a fix: it buys headroom so a large cart"
  note "cannot turn the latency demo into an intermittent 504 demo. Remove it"
  note "with: oc annotate route ${ROUTE_NAME} -n ${APP_NAMESPACE} \\"
  note "  haproxy.router.openshift.io/timeout-"
}

# ─────────────────────────────────────────────────────────────────────────────
do_watch() {
  section "Watching PlaceOrder p99 (threshold ${THRESHOLD_MS}ms)"
  note "Ctrl-C to stop. Polls every 30s for up to 15 minutes."
  local i p99
  for i in $(seq 1 30); do
    p99="$(placeorder_p99)"
    if [[ "$p99" == "?" ]]; then
      printf '  %s  p99 unavailable\n' "$(date +%H:%M:%S)"
    elif python3 -c "import sys; sys.exit(0 if float('$p99') > $THRESHOLD_MS else 1)" 2>/dev/null; then
      printf '  %s  p99 %sms  %sover threshold%s\n' \
        "$(date +%H:%M:%S)" "$p99" "$c_yellow" "$c_reset"
    else
      printf '  %s  p99 %sms\n' "$(date +%H:%M:%S)" "$p99"
    fi
    sleep 30
  done
}

case "$CMD" in
  loadgen) do_loadgen ;;
  inject)  do_inject ;;
  revert)  do_revert ;;
  status)  do_status ;;
  watch)   do_watch ;;
  route-timeout) do_route_timeout ;;
  *)
    printf 'usage: %s [loadgen [n]|inject [ms]|revert|status|watch|route-timeout [dur]]\n' "$0" >&2
    exit 1 ;;
esac
