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
PLAYBOOK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ── Step 0: Create service principal for openshift-install ───────────────────
# openshift-install requires an SP with a client secret (it cannot use
# managed identities). We create it here with az CLI (which has the
# Entra ID permissions) and pass the credentials into Terraform as variables.

cd "$SCRIPT_DIR"

SP_CLIENT_ID=""
SP_CLIENT_SECRET=""

if terraform state show azurerm_resource_group.main &>/dev/null; then
  SP_CLIENT_ID="$(terraform output -raw installer_sp_client_id 2>/dev/null || true)"
fi

if [[ -z "$SP_CLIENT_ID" ]]; then
  SUB_ID="$(terraform -chdir="$SCRIPT_DIR" console -no-color <<< 'var.azure_subscription_id' 2>/dev/null | tr -d '"')"
  CLUSTER_NAME="$(terraform -chdir="$SCRIPT_DIR" console -no-color <<< '"${var.prefix_for_name}-${var.openshift_cluster_name_suffix}"' 2>/dev/null | tr -d '"')"

  echo "================================================================"
  echo "  Creating service principal: ${CLUSTER_NAME}-installer"
  echo "================================================================"

  SP_JSON=$(az ad sp create-for-rbac \
    --name "${CLUSTER_NAME}-installer" \
    --role Contributor \
    --scopes "/subscriptions/${SUB_ID}" \
    --output json)

  SP_CLIENT_ID=$(echo "$SP_JSON" | jq -r '.appId')
  SP_CLIENT_SECRET=$(echo "$SP_JSON" | jq -r '.password')

  az role assignment create \
    --assignee "$SP_CLIENT_ID" \
    --role "User Access Administrator" \
    --scope "/subscriptions/${SUB_ID}" \
    --output none

  echo "  Service principal created: $SP_CLIENT_ID"
fi

# ── Step 1: Terraform (infra + bastion VM) ───────────────────────────────────

echo "================================================================"
echo "  Step 1/2 — Terraform: VNets, peering, private endpoints, bastion VM"
echo "================================================================"
cd "$SCRIPT_DIR"
terraform init -upgrade

TF_ARGS=()
if [[ -n "$SP_CLIENT_ID" ]]; then
  TF_ARGS+=(-var "installer_sp_client_id=$SP_CLIENT_ID")
fi
if [[ -n "$SP_CLIENT_SECRET" ]]; then
  TF_ARGS+=(-var "installer_sp_client_secret=$SP_CLIENT_SECRET")
fi

terraform apply "${TF_ARGS[@]}" --auto-approve

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
  -i "$SCRIPT_DIR/inventory.ini" \
  -e "@$SCRIPT_DIR/ansible-vars.json" \
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/setup-bastion-vm.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$SCRIPT_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"
ADMIN_USER="$(terraform -chdir="$SCRIPT_DIR" output -raw admin_username 2>/dev/null || echo 'azureuser')"

echo ""
echo "================================================================"
echo "  Environment ready!"
echo ""
echo "  Bastion: ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP"
echo ""
echo "  The bastion has: oc, openshift-install, terraform,"
echo "  mirror registry (port 8443), squid proxy, and mirrored"
echo "  OpenShift images."
echo ""
echo "  ── Deploy OpenShift (IPI) ───────────────────────────────────"
echo ""
echo "  IPI (Installer-Provisioned Infrastructure):"
echo "    install-dir is already prepared on the bastion."
echo "    ssh $ADMIN_USER@$BASTION_IP"
echo "    ./openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo "================================================================"
