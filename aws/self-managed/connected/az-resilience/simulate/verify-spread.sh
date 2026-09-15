#!/usr/bin/env bash
# Print the live zone/node distribution of the hello-az replicas.
# Run this before, during and after a simulated AZ failure -- its output is the
# evidence table in resilience-testing.md.
set -euo pipefail

NAMESPACE="${NAMESPACE:-az-resilience-demo}"
SELECTOR="${SELECTOR:-app=hello-az}"

echo "== nodes =="
oc get nodes -l node-role.kubernetes.io/worker \
  -L topology.kubernetes.io/zone \
  -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,READY:.status.conditions[-1].type,STATUS:.status.conditions[-1].status

echo
echo "== pods per zone =="
# Join each Running pod to its node's zone label and count.
oc get pods -n "$NAMESPACE" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' \
  | while IFS=$'\t' read -r node phase; do
      if [[ -z "$node" ]]; then
        echo "<unscheduled>	$phase"
      else
        zone=$(oc get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "<gone>")
        echo "$zone	$phase"
      fi
    done | sort | uniq -c

echo
echo "== pending pods =="
oc get pods -n "$NAMESPACE" -l "$SELECTOR" --field-selector=status.phase=Pending \
  -o custom-columns=NAME:.metadata.name,REASON:.status.conditions[0].message || true

echo
echo "== machinesets =="
oc get machinesets -n openshift-machine-api \
  -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,CURRENT:.status.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas
