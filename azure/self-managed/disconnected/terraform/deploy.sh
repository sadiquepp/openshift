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
PLAYBOOK_DIR="$(cd "$SCRIPT_DIR/../../../../cloud/self-managed/disconnected" && pwd)"

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
  -e "cloud_provider=azure" \ 
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/setup-bastion.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$SCRIPT_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"
ADMIN_USER="$(terraform -chdir="$SCRIPT_DIR" output -raw admin_username 2>/dev/null || echo 'azureuser')"
CLUSTER_DOMAIN="$(terraform -chdir="$SCRIPT_DIR" output -raw cluster_domain)"
CLUSTER_RG="$(terraform -chdir="$SCRIPT_DIR" output -raw cluster_resource_group_name)"
EGRESS_VNET_ID="$(terraform -chdir="$SCRIPT_DIR" output -raw egress_vnet_id)"

AZURE_REGION="$(terraform -chdir="$SCRIPT_DIR" output -raw azure_region 2>/dev/null || echo 'southeastasia')"
AZURE_SUB="$(terraform -chdir="$SCRIPT_DIR" output -raw azure_subscription_id)"
AZURE_TENANT="$(terraform -chdir="$SCRIPT_DIR" output -raw azure_tenant_id)"
NETWORK_RG="$(terraform -chdir="$SCRIPT_DIR" output -raw resource_group_name)"
CCO_SUFFIX="${CLUSTER_DOMAIN%%.*}-cco"
CCO_SA="$(echo "$CCO_SUFFIX" | tr -dc 'a-z0-9' | cut -c1-24)"

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

  2. Start the DNS linker in the background, then run the installer:

     CLUSTER_DOMAIN="$CLUSTER_DOMAIN"
     CLUSTER_RG="$CLUSTER_RG"
     EGRESS_VNET_ID="$EGRESS_VNET_ID"

     # Background: link cluster DNS to egress VNet mid-install
     (
       az login --identity
       while ! az network private-dns zone show \\
         -g "\$CLUSTER_RG" -n "\$CLUSTER_DOMAIN" &>/dev/null; do sleep 10; done
       az network private-dns link vnet create \\
         --resource-group "\$CLUSTER_RG" \\
         --zone-name "\$CLUSTER_DOMAIN" \\
         --name egress-vnet-link \\
         --virtual-network "\$EGRESS_VNET_ID" \\
         --registration-enabled false
       echo '[dns-linker] Done.'
     ) &

     # Foreground: run the installer
     ./openshift-install create cluster --dir ~/install-dir --log-level=debug

  3. Destroy and re-run:

     # Step 1: Destroy the cluster
     ./openshift-install destroy cluster --dir ~/install-dir --log-level=debug

     # Step 2: Recreate the cluster RG
     az group create --name $CLUSTER_RG --location $AZURE_REGION

     # Step 3: Delete old CCO resources
     cd ~/cco
     /home/$ADMIN_USER/cco/ccoctl azure delete \\
       --name $CCO_SUFFIX \\
       --region $AZURE_REGION \\
       --subscription-id $AZURE_SUB \\
       --storage-account-name $CCO_SA

     # Step 4: Delete the manifests, tls, jwk, openid-configuration files and directories
     rm -rf ~/cco/manifests ~/cco/tls ~/cco/jwks ~/cco/openid-configuration ~/cco/serviceaccount-signer.private ~/cco/serviceaccount-signer.public

     # Step 5: Recreate CCO resources with role assignments for the new RG
     /home/$ADMIN_USER/cco/ccoctl azure create-all \\
       --credentials-requests-dir ~/cco/credrequests \\
       --name $CCO_SUFFIX \\
       --region $AZURE_REGION \\
       --subscription-id $AZURE_SUB \\
       --tenant-id $AZURE_TENANT \\
       --storage-account-name $CCO_SA \\
       --installation-resource-group-name $CLUSTER_RG \\
       --network-resource-group-name $NETWORK_RG \\
       --output-dir ~/cco

     # Step 6: Recreate install-dir with fresh manifests
     rm -rf ~/install-dir
     mkdir ~/install-dir
     cp ~/install-config.yaml ~/install-dir/
     ./openshift-install create manifests --dir ~/install-dir
     cp ~/cco/manifests/* ~/install-dir/manifests/
     cp -r ~/cco/tls ~/install-dir/

     # Step 7: Re-run the installer
     ./openshift-install create cluster --dir ~/install-dir --log-level=debug

================================================================
EOF
