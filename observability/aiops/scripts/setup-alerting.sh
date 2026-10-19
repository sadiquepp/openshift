#!/usr/bin/env bash
#
# setup-alerting.sh — phase 2 of observability/aiops
#
# Builds the signal path for beat B: spanmetrics -> PrometheusRule -> the
# user-workload Alertmanager -> Slack. No agent, no custom code.
#
# Subcommands:
#   buckets        widen the spanmetrics histogram on the live collector
#   alertmanager   enable the dedicated UWM Alertmanager + AlertmanagerConfig
#   slack          create the webhook Secret from $SLACK_WEBHOOK_URL
#   rules          apply the PrometheusRule and AlertmanagerConfig
#   all            all of the above, in order
#   status         report what is in place
#   revert         undo everything this script applied
#
# Usage:
#   export KUBECONFIG=~/.kube/config
#   export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'
#   ./scripts/setup-alerting.sh all
#
# Env:
#   TRACING_NAMESPACE=tracing-system
#   OTEL_COLLECTOR=otel
#   SLACK_CHANNEL=#aiops-demo     must match the AlertmanagerConfig
#
# The Slack webhook URL is read from the environment and stored in a Secret.
# It is never written to a file in this repository.

set -uo pipefail

TRACING_NAMESPACE="${TRACING_NAMESPACE:-tracing-system}"
OTEL_COLLECTOR="${OTEL_COLLECTOR:-otel}"
UWM_NAMESPACE="openshift-user-workload-monitoring"
SLACK_SECRET="aiops-slack-webhook"
CMD="${1:-all}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="$(cd "$HERE/../manifests" && pwd)"

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

# The finer boundaries. Kept identical to
# ../ansible/group_vars/all.yml:spanmetrics_histogram_buckets so that a later
# ansible run does not silently revert what this script applied.
BUCKETS_JSON='["1ms","2ms","5ms","10ms","20ms","30ms","50ms","100ms","250ms","500ms","1s","2500ms","5s","10s"]'
BUCKETS_COARSE='["10ms","50ms","100ms","250ms","500ms","1s","5s"]'

# ─────────────────────────────────────────────────────────────────────────────
do_buckets() {
  section "Widen the spanmetrics histogram"

  "$OC" get opentelemetrycollector "$OTEL_COLLECTOR" -n "$TRACING_NAMESPACE" \
    >/dev/null 2>&1 || die "no OpenTelemetryCollector/${OTEL_COLLECTOR} in ${TRACING_NAMESPACE}"

  local current
  current="$("$OC" get opentelemetrycollector "$OTEL_COLLECTOR" -n "$TRACING_NAMESPACE" \
    -o jsonpath='{.spec.config.connectors.spanmetrics.histogram.explicit.buckets}' 2>/dev/null)"
  note "current: ${current:-<unset>}"

  # spec.config is a structured object in the v1beta1 CRD, so a merge patch
  # replaces the array cleanly. No string surgery on an embedded YAML blob.
  if "$OC" patch opentelemetrycollector "$OTEL_COLLECTOR" -n "$TRACING_NAMESPACE" \
      --type=merge \
      -p "{\"spec\":{\"config\":{\"connectors\":{\"spanmetrics\":{\"histogram\":{\"explicit\":{\"buckets\":${BUCKETS_JSON}}}}}}}}" \
      >/dev/null; then
    ok "patched to 14 boundaries from 1ms to 10s"
  else
    die "patch failed"
  fi

  "$OC" rollout status deploy/"${OTEL_COLLECTOR}-collector" -n "$TRACING_NAMESPACE" \
    --timeout=180s 2>/dev/null \
    || warn "collector rollout not confirmed — check 'oc get pods -n ${TRACING_NAMESPACE}'"

  warn "wait ~5 minutes before trusting any p99"
  note "Series carrying the OLD le values stay in Prometheus until they age out"
  note "of the 5m rate window. Query before then and you are averaging two"
  note "different histograms, which reads as nonsense rather than as an error."
}

# ─────────────────────────────────────────────────────────────────────────────
do_alertmanager() {
  section "Enable the dedicated user-workload Alertmanager"

  # Read-modify-write, like ../ansible does for cluster-monitoring-config: this
  # ConfigMap may already carry retention, node placement or resource settings
  # that must survive.
  local existing merged
  existing="$("$OC" get configmap user-workload-monitoring-config -n "$UWM_NAMESPACE" \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null)"

  merged="$(printf '%s' "${existing:-}" | python3 -c '
import sys, json
try:
    import yaml
except ImportError:
    sys.stderr.write("PyYAML missing\n")
    sys.exit(2)
raw = sys.stdin.read()
doc = yaml.safe_load(raw) if raw.strip() else {}
if not isinstance(doc, dict):
    doc = {}
am = doc.setdefault("alertmanager", {})
am["enabled"] = True
am["enableAlertmanagerConfig"] = True
print(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False))
')"

  if [[ $? -ne 0 || -z "$merged" ]]; then
    bad "could not merge the UWM config"
    note "Needs PyYAML (pip install pyyaml), or set both keys by hand:"
    note "  alertmanager: {enabled: true, enableAlertmanagerConfig: true}"
    note "in configmap/user-workload-monitoring-config -n ${UWM_NAMESPACE}"
    return 1
  fi

  "$OC" create configmap user-workload-monitoring-config -n "$UWM_NAMESPACE" \
    --from-literal=config.yaml="$merged" \
    --dry-run=client -o yaml | "$OC" apply -f - >/dev/null \
    || die "could not write the UWM config"
  ok "alertmanager.enabled + enableAlertmanagerConfig set"

  note "waiting for the Alertmanager StatefulSet (cluster-monitoring-operator"
  note "reconciles this; it is not instant)"
  local i
  for i in $(seq 1 40); do
    if "$OC" get statefulset alertmanager-user-workload -n "$UWM_NAMESPACE" \
         >/dev/null 2>&1; then
      "$OC" rollout status statefulset/alertmanager-user-workload -n "$UWM_NAMESPACE" \
        --timeout=180s >/dev/null 2>&1 \
        && { ok "alertmanager-user-workload is up"; return 0; }
    fi
    sleep 15
  done
  warn "alertmanager-user-workload did not appear within 10 minutes"
  note "Without it the AlertmanagerConfig is accepted and silently ignored."
  note "Check: oc -n ${UWM_NAMESPACE} get pods,statefulset"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
do_slack() {
  section "Create the Slack webhook Secret"

  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    bad "SLACK_WEBHOOK_URL is not set"
    note "Create a Slack incoming webhook for the demo channel, then:"
    note "  export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'"
    note "It is stored in a Secret and never written to this repository."
    return 1
  fi

  case "$SLACK_WEBHOOK_URL" in
    https://hooks.slack.com/*) : ;;
    *) warn "that does not look like a Slack incoming webhook URL" ;;
  esac

  "$OC" create secret generic "$SLACK_SECRET" -n "$TRACING_NAMESPACE" \
    --from-literal=url="$SLACK_WEBHOOK_URL" \
    --dry-run=client -o yaml | "$OC" apply -f - >/dev/null \
    || die "could not create secret/${SLACK_SECRET}"
  ok "secret/${SLACK_SECRET} in ${TRACING_NAMESPACE}"
}

# ─────────────────────────────────────────────────────────────────────────────
do_rules() {
  section "Apply the alert rule and the Slack route"

  "$OC" apply -f "$MANIFESTS/prometheusrule-checkout-latency.yaml" >/dev/null \
    && ok "PrometheusRule/aiops-checkout-latency" \
    || die "PrometheusRule apply failed"

  if "$OC" apply -f "$MANIFESTS/alertmanagerconfig-slack.yaml" >/dev/null 2>&1; then
    ok "AlertmanagerConfig/aiops-slack"
  else
    warn "AlertmanagerConfig apply failed — trying v1alpha1"
    note "The CRD is v1beta1 on current OpenShift and v1alpha1 on older ones."
    sed 's|monitoring.coreos.com/v1beta1|monitoring.coreos.com/v1alpha1|' \
      "$MANIFESTS/alertmanagerconfig-slack.yaml" \
      | "$OC" apply -f - >/dev/null \
      && ok "AlertmanagerConfig/aiops-slack (v1alpha1)" \
      || die "AlertmanagerConfig apply failed on both versions"
  fi

  note "The rule needs one evaluation interval plus its 2m 'for' before it can"
  note "fire, so nothing will happen for at least that long after a fault."
}

# ─────────────────────────────────────────────────────────────────────────────
do_status() {
  section "Status"

  local b
  b="$("$OC" get opentelemetrycollector "$OTEL_COLLECTOR" -n "$TRACING_NAMESPACE" \
    -o jsonpath='{.spec.config.connectors.spanmetrics.histogram.explicit.buckets}' 2>/dev/null)"
  if [[ "$b" == *"20ms"* ]]; then ok "buckets: widened"
  else warn "buckets: still coarse (${b:-unset})"; fi

  if "$OC" get statefulset alertmanager-user-workload -n "$UWM_NAMESPACE" >/dev/null 2>&1; then
    local ready
    ready="$("$OC" get statefulset alertmanager-user-workload -n "$UWM_NAMESPACE" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    ok "alertmanager-user-workload: ${ready:-0} ready"
  else
    warn "alertmanager-user-workload: absent — AlertmanagerConfig will be ignored"
  fi

  "$OC" get secret "$SLACK_SECRET" -n "$TRACING_NAMESPACE" >/dev/null 2>&1 \
    && ok "secret/${SLACK_SECRET}: present" \
    || warn "secret/${SLACK_SECRET}: absent"

  "$OC" get prometheusrule aiops-checkout-latency -n "$TRACING_NAMESPACE" >/dev/null 2>&1 \
    && ok "PrometheusRule: present" || warn "PrometheusRule: absent"

  "$OC" get alertmanagerconfig aiops-slack -n "$TRACING_NAMESPACE" >/dev/null 2>&1 \
    && ok "AlertmanagerConfig: present" || warn "AlertmanagerConfig: absent"

  printf '\n'
  note "Alert state (needs a token; empty means not firing):"
  local thanos token
  thanos="$("$OC" get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)"
  token="$("$OC" whoami -t 2>/dev/null)"
  if [[ -n "$thanos" && -n "$token" ]]; then
    curl -sSk --max-time 20 -H "Authorization: Bearer ${token}" \
      -G --data-urlencode 'query=ALERTS{alertname="CheckoutPlaceOrderSlow"}' \
      "https://${thanos}/api/v1/query" 2>/dev/null \
      | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("    (could not read)"); sys.exit(0)
rs = d.get("data", {}).get("result", [])
if not rs:
    print("    not firing"); sys.exit(0)
for r in rs:
    m = r.get("metric", {})
    print("    %s state=%s" % (m.get("alertname"), m.get("alertstate")))
'
  else
    note "    (no route or token)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
do_revert() {
  section "Revert"
  note "Leaves the UWM Alertmanager enabled — other work may now rely on it."
  note "Disable it by hand if you want it gone."

  "$OC" delete alertmanagerconfig aiops-slack -n "$TRACING_NAMESPACE" --ignore-not-found >/dev/null 2>&1
  ok "AlertmanagerConfig removed"
  "$OC" delete prometheusrule aiops-checkout-latency -n "$TRACING_NAMESPACE" --ignore-not-found >/dev/null 2>&1
  ok "PrometheusRule removed"
  "$OC" delete secret "$SLACK_SECRET" -n "$TRACING_NAMESPACE" --ignore-not-found >/dev/null 2>&1
  ok "Slack Secret removed"

  "$OC" patch opentelemetrycollector "$OTEL_COLLECTOR" -n "$TRACING_NAMESPACE" \
    --type=merge \
    -p "{\"spec\":{\"config\":{\"connectors\":{\"spanmetrics\":{\"histogram\":{\"explicit\":{\"buckets\":${BUCKETS_COARSE}}}}}}}}" \
    >/dev/null 2>&1 \
    && ok "buckets back to the upstream default" \
    || warn "could not revert buckets"
  note "../ansible/group_vars/all.yml still carries the finer list, so the next"
  note "ansible run re-applies it. Change it there for a durable revert."
}

case "$CMD" in
  buckets)      do_buckets ;;
  alertmanager) do_alertmanager ;;
  slack)        do_slack ;;
  rules)        do_rules ;;
  status)       do_status ;;
  revert)       do_revert ;;
  all)
    do_buckets
    do_alertmanager || warn "continuing — the route will not deliver until this is fixed"
    do_slack        || warn "continuing — no Slack delivery without the Secret"
    do_rules
    do_status
    printf '\n%sNext: ./scripts/demo-fault.sh loadgen, then inject.%s\n' "$c_dim" "$c_reset"
    ;;
  *)
    printf 'usage: %s [all|buckets|alertmanager|slack|rules|status|revert]\n' "$0" >&2
    exit 1 ;;
esac
