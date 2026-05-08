#!/usr/bin/env bash
#
# Set up a disconnected environment for OpenShift on Azure.
#
#   Step 1  terraform apply   – VNets, peering, private endpoints, bastion VM
#   Step 2  ansible-playbook  – configure bastion, mirror registry, mirror images
#
# After this script completes, SSH into the bastion and deploy a cluster
# using the IPI method.
#
# Usage:
#   ./deploy.sh \
#     --pull-secret-file ~/pull-secret.json \
#     --mirror-registry-password 'MyP@ss' \
#     --openshift-version 4.20.0 \
#     --operators 'aws-load-balancer-operator,cluster-logging,elasticsearch-operator'
#
#   All flags are optional except --pull-secret-file.
#   Any extra arguments after the flags are forwarded to the Ansible playbook.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
PLAYBOOK_DIR="$(cd "$SCRIPT_DIR/../../../cloud/self-managed/disconnected" && pwd)"

# ── Parse arguments ──────────────────────────────────────────────────────────

PULL_SECRET_FILE=""
MIRROR_REGISTRY_PASSWORD=""
OPENSHIFT_VERSION=""
OPERATORS=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull-secret-file)
      PULL_SECRET_FILE="$2"; shift 2 ;;
    --mirror-registry-password)
      MIRROR_REGISTRY_PASSWORD="$2"; shift 2 ;;
    --openshift-version)
      OPENSHIFT_VERSION="$2"; shift 2 ;;
    --operators)
      OPERATORS="$2"; shift 2 ;;
    *)
      EXTRA_ARGS+=("$1"); shift ;;
  esac
done

if [[ -z "$PULL_SECRET_FILE" ]]; then
  echo "Error: --pull-secret-file is required" >&2
  echo "Usage: $0 --pull-secret-file ~/pull-secret.json [options...]" >&2
  exit 1
fi

ANSIBLE_EXTRA=(-e "pull_secret=$(cat "$PULL_SECRET_FILE")")

if [[ -n "$MIRROR_REGISTRY_PASSWORD" ]]; then
  ANSIBLE_EXTRA+=(-e "mirror_registry_password=$MIRROR_REGISTRY_PASSWORD")
fi

if [[ -n "$OPENSHIFT_VERSION" ]]; then
  MAJOR="${OPENSHIFT_VERSION%.*}"
  MINOR="${OPENSHIFT_VERSION##*.}"
  ANSIBLE_EXTRA+=(-e "openshift_major_version=$MAJOR")
  ANSIBLE_EXTRA+=(-e "openshift_minor_version=$MINOR")
fi

if [[ -n "$OPERATORS" ]]; then
  OPS_JSON=$(echo "$OPERATORS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s -c .)
  ANSIBLE_EXTRA+=(-e "{\"mirror_operators\": $OPS_JSON}")
fi

# ── Step 1: Terraform (infra + bastion VM) ───────────────────────────────────

echo "================================================================"
echo "  Step 1/2 — Terraform: VNets, peering, private endpoints, bastion VM"
echo "================================================================"
cd "$TF_DIR"
terraform init -upgrade
terraform apply --auto-approve

BASTION_IP="$(terraform output -raw bastion_public_ip)"
echo ""
echo "  Bastion VM public IP: $BASTION_IP"

# ── Step 2: Ansible (configure the bastion) ──────────────────────────────────

echo ""
echo "================================================================"
echo "  Step 2/2 — Ansible: configure bastion, mirror registry, images"
echo "================================================================"
echo "  Waiting 30s for VM SSH to become available ..."
sleep 30

ansible-playbook \
  -i "$TF_DIR/inventory.ini" \
  -e "@$TF_DIR/ansible-vars.json" \
  -e "cloud_provider=azure" \
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/setup-bastion.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$TF_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"
ADMIN_USER="$(terraform -chdir="$TF_DIR" output -raw admin_username 2>/dev/null || echo 'azureuser')"

cat <<EOF
================================================================
  Environment ready!

  Bastion: ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP

  The bastion has: oc, openshift-install, terraform,
  mirror registry (port 8444), squid proxy, and mirrored
  OpenShift images.

  ── Deploy OpenShift (IPI) ───────────────────────────────────

  1. SSH into the bastion:

     ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP

  2. Run the install script (handles DNS linking + installer):

     ~/install-cluster.sh

  3. Destroy and re-run (all-in-one):

     ~/reinstall-cluster.sh

================================================================
EOF
