#!/usr/bin/env bash
#
# Set up a connected environment for OpenShift on Azure.
#
#   Step 1  terraform apply   – VNet, NAT GW, NSG, identity, bastion VM
#   Step 2  ansible-playbook  – configure bastion, install tools, create CCO resources
#
# After this script completes, SSH into the bastion and deploy a cluster
# using openshift-install.
#
# Usage:
#   ./deploy.sh \
#     --pull-secret-file ~/pull-secret.json \
#     --openshift-version 4.18.20
#
#   --pull-secret-file is required. All other flags are optional.
#   Any extra arguments after the flags are forwarded to the Ansible playbook.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

# ── Parse arguments ──────────────────────────────────────────────────────────

PULL_SECRET_FILE=""
OPENSHIFT_VERSION=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull-secret-file)
      PULL_SECRET_FILE="$2"; shift 2 ;;
    --openshift-version)
      OPENSHIFT_VERSION="$2"; shift 2 ;;
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

if [[ -n "$OPENSHIFT_VERSION" ]]; then
  MAJOR="${OPENSHIFT_VERSION%.*}"
  MINOR="${OPENSHIFT_VERSION##*.}"
  ANSIBLE_EXTRA+=(-e "openshift_major_version=$MAJOR")
  ANSIBLE_EXTRA+=(-e "openshift_minor_version=$MINOR")
fi

# ── Step 1: Terraform (infra + bastion VM) ───────────────────────────────────

echo "================================================================"
echo "  Step 1/2 — Terraform: VNet, NAT GW, NSG, identity, bastion VM"
echo "================================================================"
cd "$TF_DIR"
terraform init -upgrade
terraform apply -auto-approve

BASTION_IP="$(terraform output -raw bastion_public_ip)"
echo ""
echo "  Bastion VM public IP: $BASTION_IP"

# ── Step 2: Ansible (configure the bastion) ──────────────────────────────────

echo ""
echo "================================================================"
echo "  Step 2/2 — Ansible: install tools, CCO resources, install-dir"
echo "================================================================"
echo "  Waiting 30s for VM SSH to become available ..."
sleep 30

ansible-playbook \
  -i "$TF_DIR/inventory.ini" \
  -e "@$TF_DIR/ansible-vars.json" \
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$SCRIPT_DIR/setup-bastion-vm-connected.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$TF_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"
ADMIN_USER="$(terraform -chdir="$TF_DIR" output -raw admin_username 2>/dev/null || echo 'azureuser')"

AZURE_REGION="$(terraform -chdir="$TF_DIR" output -raw azure_region 2>/dev/null || echo 'southeastasia')"
AZURE_SUB="$(terraform -chdir="$TF_DIR" output -raw azure_subscription_id)"
CLUSTER_DOMAIN="$(terraform -chdir="$TF_DIR" output -raw cluster_domain)"
CLUSTER_RG="$(terraform -chdir="$TF_DIR" output -raw cluster_resource_group_name)"
NETWORK_RG="$(terraform -chdir="$TF_DIR" output -raw resource_group_name)"
CCO_SUFFIX="${CLUSTER_DOMAIN%%.*}-cco"
CCO_SA="$(echo "$CCO_SUFFIX" | tr -dc 'a-z0-9' | cut -c1-24)"

cat <<EOF
================================================================
  Environment ready!

  Bastion: ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP

  The bastion has: oc, openshift-install, ccoctl, az CLI
  and CCO credentials prepared.

  ── Deploy OpenShift (IPI) ───────────────────────────────────

  1. SSH into the bastion:

     ssh -i $SSH_KEY $ADMIN_USER@$BASTION_IP

  2. Run the installer:

     ./openshift-install create cluster --dir ~/install-dir --log-level=debug

  3. Destroy and re-run:

     # Step 1: Destroy the cluster
     ./openshift-install destroy cluster --dir ~/install-dir --log-level=debug

     # Step 2: Recreate the cluster RG
     az group create --name $CLUSTER_RG --location $AZURE_REGION

     # Step 3: Delete old CCO resources
     cd ~/cco
     ccoctl azure delete \\
       --name $CCO_SUFFIX \\
       --region $AZURE_REGION \\
       --subscription-id $AZURE_SUB \\
       --storage-account-name $CCO_SA

     # Step 4: Recreate CCO resources
     rm -rf ~/cco/manifests ~/cco/tls ~/cco/jwks ~/cco/openid-configuration ~/cco/serviceaccount-signer.private ~/cco/serviceaccount-signer.public
     ccoctl azure create-all \\
       --credentials-requests-dir ~/cco/credrequests \\
       --name $CCO_SUFFIX \\
       --region $AZURE_REGION \\
       --subscription-id $AZURE_SUB \\
       --tenant-id $(terraform -chdir="$TF_DIR" output -raw azure_tenant_id) \\
       --storage-account-name $CCO_SA \\
       --installation-resource-group-name $CLUSTER_RG \\
       --network-resource-group-name $NETWORK_RG \\
       --output-dir ~/cco

     # Step 5: Recreate install-dir with fresh manifests
     rm -rf ~/install-dir
     mkdir ~/install-dir
     cp ~/install-config.yaml ~/install-dir/
     ./openshift-install create manifests --dir ~/install-dir
     cp ~/cco/manifests/* ~/install-dir/manifests/
     cp -r ~/cco/tls ~/install-dir/

     # Step 6: Re-run the installer
     ./openshift-install create cluster --dir ~/install-dir --log-level=debug

================================================================
EOF
