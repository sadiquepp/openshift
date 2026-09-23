#!/usr/bin/env bash
# One-shot diagnostic dump for "the descheduler is not rebalancing".
#
# Walks the same ladder as resilience-testing.md, "Troubleshooting the
# descheduler": operator install -> CR accepted -> rendered policy -> is there a
# violation -> operand log -> PDB headroom. Read the output top to bottom and
# stop at the first section that looks wrong; each step rules out the ones above
# it.
#
# Read-only -- it changes nothing.
set -uo pipefail

NS="${NS:-openshift-kube-descheduler-operator}"
APP_NS="${APP_NS:-az-resilience-demo}"
SELECTOR="${SELECTOR:-app=hello-az}"
TAIL="${TAIL:-200}"

hr() { printf '\n=== %s ===\n' "$1"; }

hr "0. The two settings that silently disable it"
echo "mode must be Automatic (default Predictive only simulates)."
echo "profiles must include EvictPodsWithLocalStorage (hello-az mounts emptyDir)."
oc get kubedescheduler cluster -n "$NS" \
  -o jsonpath='mode={.spec.mode}{"\n"}profiles={.spec.profiles}{"\n"}interval={.spec.deschedulingIntervalSeconds}{"\n"}evictionLimits={.spec.evictionLimits}{"\n"}' 2>&1
echo
mode=$(oc get kubedescheduler cluster -n "$NS" -o jsonpath='{.spec.mode}' 2>/dev/null)
[[ "$mode" == "Automatic" ]] || echo ">>> PROBLEM: mode is '${mode:-<unset, defaults to Predictive>}' -- nothing will actually be evicted."
oc get kubedescheduler cluster -n "$NS" -o jsonpath='{.spec.profiles}' 2>/dev/null \
  | grep -q EvictPodsWithLocalStorage \
  || echo ">>> PROBLEM: EvictPodsWithLocalStorage not in profiles -- emptyDir pods are exempt from eviction."

hr "1. Operator install (CSV must be Succeeded)"
oc get csv -n "$NS" 2>&1
oc get subscription -n "$NS" 2>&1
oc get installplan -n "$NS" 2>&1

hr "2a. KubeDescheduler CRs cluster-wide (must be named 'cluster', in $NS)"
oc get kubedescheduler -A 2>&1

hr "2b. CR status conditions"
oc get kubedescheduler cluster -n "$NS" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' 2>&1

hr "2c. CR spec"
oc get kubedescheduler cluster -n "$NS" -o jsonpath='{.spec}' 2>&1 | python3 -m json.tool 2>/dev/null \
  || oc get kubedescheduler cluster -n "$NS" -o yaml 2>&1 | sed -n '/^spec:/,/^status:/p'

hr "2d. Pods (expect operator + operand; check AGE against your last CR edit)"
oc get pods -n "$NS" -o wide 2>&1

hr "3. Rendered policy (RemovePodsViolatingTopologySpreadConstraint must appear)"
oc get cm -n "$NS" 2>&1
for cm in $(oc get cm -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
  policy=$(oc get cm "$cm" -n "$NS" -o jsonpath='{.data.policy\.yaml}' 2>/dev/null)
  if [[ -n "$policy" ]]; then
    printf -- '--- configmap/%s : policy.yaml ---\n%s\n' "$cm" "$policy"
  fi
done

hr "4a. Worker nodes and zones (a zone with no Ready node is not a domain)"
oc get nodes -l node-role.kubernetes.io/worker -L topology.kubernetes.io/zone 2>&1

hr "4b. Machines (a stranded Machine means the recovered zone has nowhere to land)"
oc get machines -n openshift-machine-api 2>&1

hr "4c. Current pod spread"
oc get pods -n "$APP_NS" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | while IFS=$'\t' read -r node phase; do
      if [[ -z "$node" ]]; then
        echo "<unscheduled>	$phase"
      else
        zone=$(oc get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "<gone>")
        echo "$zone	$phase"
      fi
    done | sort | uniq -c

hr "5. Operand log, last $TAIL lines"
oc logs deployment/descheduler -n "$NS" --tail="$TAIL" 2>&1

hr "5b. Just the decisions"
oc logs deployment/descheduler -n "$NS" --tail=1000 2>/dev/null \
  | grep -iE 'evict|topolog|skew|violat|pdb|disruption|exclud' | tail -40

hr "6. PDB headroom (ALLOWED DISRUPTIONS must be > 0)"
oc get pdb -n "$APP_NS" 2>&1
oc describe pdb -n "$APP_NS" 2>&1 | grep -E 'Name:|Allowed|Current|Desired|Min available|Max unavailable'

hr "7. Recent eviction and scheduling events"
oc get events -n "$APP_NS" --sort-by=.lastTimestamp 2>&1 \
  | grep -iE 'evict|failedscheduling|topolog' | tail -20

hr "done"
echo "Work down the sections in order; stop at the first that looks wrong."
echo "See resilience-testing.md, 'Troubleshooting the descheduler'."
