#!/usr/bin/env bash
# AZ failure simulation #1 -- node drain (graceful).
#
# Cordons and drains every worker in one zone. This models a planned zone
# evacuation, NOT a real outage: the kubelet stays healthy, pods terminate
# gracefully, and the node keeps a NoSchedule (not NoExecute) taint. Use it to
# validate the topology spread + autoscaler path quickly; use the NACL or FIS
# method to validate the failure path the NoExecute taint drives.
#
# Usage:  ./drain-az.sh us-east-1a
#         ./drain-az.sh us-east-1a --undo
set -euo pipefail

ZONE="${1:?usage: $0 <availability-zone> [--undo]}"
UNDO="${2:-}"

mapfile -t NODES < <(oc get nodes \
  -l "node-role.kubernetes.io/worker,topology.kubernetes.io/zone=${ZONE}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "no worker nodes found in zone ${ZONE}" >&2
  exit 1
fi

if [[ "$UNDO" == "--undo" ]]; then
  for n in "${NODES[@]}"; do
    echo "uncordoning $n"
    oc adm uncordon "$n"
  done
  exit 0
fi

for n in "${NODES[@]}"; do
  echo "draining $n"
  oc adm drain "$n" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --timeout=300s
done

echo
echo "zone ${ZONE} drained. Watch the displaced pods with:"
echo "  ./verify-spread.sh"
