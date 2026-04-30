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

# ── Step 1: Terraform (infra + bastion VM) ───────────────────────────────────

echo "================================================================"
echo "  Step 1/2 — Terraform: VNets, peering, private endpoints, bastion VM"
echo "================================================================"
cd "$SCRIPT_DIR"
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
  -i "$SCRIPT_DIR/inventory.ini" \
  -e "@$SCRIPT_DIR/ansible-vars.json" \
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/setup-bastion-vm.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$SCRIPT_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"
ADMIN_USER="$(terraform -chdir="$SCRIPT_DIR" output -raw admin_username 2>/dev/null || echo 'azureuser')"
CLUSTER_DOMAIN="$(terraform -chdir="$SCRIPT_DIR" output -raw cluster_domain)"
CLUSTER_RG="$(terraform -chdir="$SCRIPT_DIR" output -raw cluster_resource_group_name)"
EGRESS_VNET_ID="$(terraform -chdir="$SCRIPT_DIR" output -raw egress_vnet_id)"

echo ""
echo "================================================================"
echo "  Environment ready!"
echo ""
echo "  Bastion: ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP"
echo ""
echo "  The bastion has: oc, openshift-install, terraform,"
echo "  mirror registry (port 8444), squid proxy, and mirrored"
echo "  OpenShift images."
echo ""
echo "  ── Deploy OpenShift (IPI) ───────────────────────────────────"
echo ""
echo "  1. SSH into the bastion:"
echo ""
echo "     ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP"
echo ""
echo "  2. Start the DNS linker in the background, then run the installer:"
echo ""
echo "     CLUSTER_DOMAIN=\"$CLUSTER_DOMAIN\""
echo "     CLUSTER_RG=\"$CLUSTER_RG\""
echo "     EGRESS_VNET_ID=\"$EGRESS_VNET_ID\""
echo ""
echo "     # Background: link cluster DNS to egress VNet mid-install"
echo "     ("
echo "       while ! az network private-dns zone show \\"
echo "         -g \"\$CLUSTER_RG\" -n \"\$CLUSTER_DOMAIN\" &>/dev/null; do sleep 10; done"
echo "       az network private-dns link vnet create \\"
echo "         --resource-group \"\$CLUSTER_RG\" \\"
echo "         --zone-name \"\$CLUSTER_DOMAIN\" \\"
echo "         --name egress-vnet-link \\"
echo "         --virtual-network \"\$EGRESS_VNET_ID\" \\"
echo "         --registration-enabled false"
echo "       echo '[dns-linker] Done.'"
echo "     ) &"
echo ""
echo "     # Foreground: run the installer"
echo "     ./openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo ""
AZURE_REGION="$(terraform -chdir="$SCRIPT_DIR" output -raw azure_region 2>/dev/null || echo 'southeastasia')"
AZURE_SUB="$(terraform -chdir="$SCRIPT_DIR" output -raw azure_subscription_id)"
AZURE_TENANT="$(terraform -chdir="$SCRIPT_DIR" output -raw azure_tenant_id)"
NETWORK_RG="$(terraform -chdir="$SCRIPT_DIR" output -raw resource_group_name)"
CCO_SUFFIX="${CLUSTER_DOMAIN%%.*}-cco"
CCO_SA="$(echo "$CCO_SUFFIX" | tr -dc 'a-z0-9' | cut -c1-24)"

echo "  3. Destroy and re-run:"
echo ""
echo "     # Step 1: Destroy the cluster"
echo "     ./openshift-install destroy cluster --dir ~/install-dir --log-level=debug"
echo ""
echo "     # Step 2: Recreate the cluster RG"
echo "     az group create --name $CLUSTER_RG --location $AZURE_REGION"
echo ""
echo "     # Step 3: Delete old CCO resources"
echo "     cd ~/cco"
echo "     /home/azureuser/cco/ccoctl azure delete \\"
echo "       --name $CCO_SUFFIX \\"
echo "       --region $AZURE_REGION \\"
echo "       --subscription-id $AZURE_SUB \\"
echo "       --tenant-id $AZURE_TENANT"
echo ""
echo "     # Step 4: Recreate CCO resources with role assignments for the new RG"
echo "     /home/azureuser/cco/ccoctl azure create-all \\"
echo "       --credentials-requests-dir ~/cco/credrequests \\"
echo "       --name $CCO_SUFFIX \\"
echo "       --region $AZURE_REGION \\"
echo "       --subscription-id $AZURE_SUB \\"
echo "       --tenant-id $AZURE_TENANT \\"
echo "       --storage-account-name $CCO_SA \\"
echo "       --installation-resource-group-name $CLUSTER_RG \\"
echo "       --network-resource-group-name $NETWORK_RG \\"
echo "       --output-dir ~/cco"
echo ""
echo "     # Step 5: Recreate install-dir with fresh manifests"
echo "     rm -rf ~/install-dir"
echo "     mkdir ~/install-dir"
echo "     cp ~/install-config.yaml ~/install-dir/"
echo "     ./openshift-install create manifests --dir ~/install-dir"
echo "     cp ~/cco/manifests/* ~/install-dir/manifests/"
echo "     cp -r ~/cco/tls ~/install-dir/"
echo ""
echo "     # Step 6: Re-run the installer"
echo "     ./openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo ""
echo "================================================================"
