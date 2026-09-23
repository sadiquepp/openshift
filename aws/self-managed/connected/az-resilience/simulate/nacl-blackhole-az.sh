#!/usr/bin/env bash
# AZ failure simulation #2 -- network ACL blackhole (hard, reversible).
#
# Associates every subnet in one AZ with an empty network ACL. A freshly created
# NACL denies all ingress and egress, so the nodes in that zone are instantly
# unreachable: the kubelet stops reporting, the node goes NotReady, and the
# node.kubernetes.io/unreachable:NoExecute taint evicts the pods. This is the
# closest reversible approximation of a real zone outage, and unlike a drain it
# exercises nodeTaintsPolicy: Honor.
#
# The original NACL association IDs are written to a state file so the blackhole
# can be undone exactly.
#
# Requires: aws CLI v2, jq, and permission for ec2:*NetworkAcl*.
#
# Usage:  VPC_ID=vpc-0123 ./nacl-blackhole-az.sh us-east-1a
#         VPC_ID=vpc-0123 ./nacl-blackhole-az.sh us-east-1a --undo
set -euo pipefail

ZONE="${1:?usage: VPC_ID=vpc-xxx $0 <availability-zone> [--undo]}"
UNDO="${2:-}"
VPC_ID="${VPC_ID:?set VPC_ID to the cluster VPC}"
STATE_FILE="${STATE_FILE:-/tmp/nacl-blackhole-${ZONE}.json}"

if [[ "$UNDO" == "--undo" ]]; then
  [[ -f "$STATE_FILE" ]] || { echo "no state file at $STATE_FILE" >&2; exit 1; }
  BLACKHOLE_ID=$(jq -r '.blackhole_nacl_id' "$STATE_FILE")

  while read -r subnet original_nacl; do
    # Replacing an association mints a new association ID, so the one recorded
    # at blackhole time is stale. Look up the live association the blackhole
    # NACL now holds for this subnet.
    live_assoc=$(aws ec2 describe-network-acls \
      --filters "Name=association.subnet-id,Values=${subnet}" \
      --query "NetworkAcls[].Associations[?SubnetId=='${subnet}'].NetworkAclAssociationId" \
      --output text | head -n1)
    if [[ -z "$live_assoc" || "$live_assoc" == "None" ]]; then
      echo "no live association for subnet $subnet, skipping" >&2
      continue
    fi
    echo "restoring subnet $subnet -> NACL $original_nacl"
    aws ec2 replace-network-acl-association \
      --association-id "$live_assoc" \
      --network-acl-id "$original_nacl" >/dev/null
  done < <(jq -r '.associations[] | "\(.SubnetId) \(.NetworkAclId)"' "$STATE_FILE")

  echo "deleting blackhole NACL $BLACKHOLE_ID"
  aws ec2 delete-network-acl --network-acl-id "$BLACKHOLE_ID" || true
  rm -f "$STATE_FILE"
  echo "zone ${ZONE} restored. Nodes rejoin within a few minutes."
  exit 0
fi

echo "finding subnets in ${ZONE} of ${VPC_ID}"
SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=availability-zone,Values=${ZONE}" \
  --query 'Subnets[].SubnetId' --output text)
[[ -n "$SUBNETS" ]] || { echo "no subnets found" >&2; exit 1; }
echo "subnets: $SUBNETS"

# A new NACL starts with only the implicit deny-all rules -- no allow rules are
# added, which is exactly the blackhole we want.
BLACKHOLE_ID=$(aws ec2 create-network-acl --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=network-acl,Tags=[{Key=Name,Value=az-blackhole-${ZONE}}]" \
  --query 'NetworkAcl.NetworkAclId' --output text)
echo "created blackhole NACL $BLACKHOLE_ID"

ASSOCS='[]'
for subnet in $SUBNETS; do
  entry=$(aws ec2 describe-network-acls \
    --filters "Name=association.subnet-id,Values=${subnet}" \
    --query "NetworkAcls[].Associations[?SubnetId=='${subnet}']" --output json | jq -c '.[0][0]')
  ASSOCS=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$ASSOCS")
  assoc_id=$(jq -r '.NetworkAclAssociationId' <<<"$entry")
  echo "blackholing subnet $subnet (was ${assoc_id})"
  aws ec2 replace-network-acl-association \
    --association-id "$assoc_id" \
    --network-acl-id "$BLACKHOLE_ID" >/dev/null
done

jq -n --arg id "$BLACKHOLE_ID" --argjson a "$(jq -c '[.[] | {AssociationId: .NetworkAclAssociationId, NetworkAclId: .NetworkAclId, SubnetId: .SubnetId}]' <<<"$ASSOCS")" \
  '{blackhole_nacl_id: $id, associations: $a}' > "$STATE_FILE"

echo
echo "zone ${ZONE} is blackholed. State saved to ${STATE_FILE}"
echo "Undo with: VPC_ID=${VPC_ID} $0 ${ZONE} --undo"
