#!/usr/bin/env bash
#
# Set up a disconnected environment for OpenShift on GCP.
#
#   Step 1  terraform apply   – VPCs, peering, PSC, bastion VM
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
#   --pull-secret-file and --mirror-registry-password are required.
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

if [[ -z "$PULL_SECRET_FILE" || -z "$MIRROR_REGISTRY_PASSWORD" ]]; then
  echo "Error: --pull-secret-file and --mirror-registry-password are required" >&2
  echo "Usage: $0 --pull-secret-file ~/pull-secret.json --mirror-registry-password 'MyP@ss' [options...]" >&2
  exit 1
fi

ANSIBLE_EXTRA=(-e "pull_secret=$(cat "$PULL_SECRET_FILE")")
ANSIBLE_EXTRA+=(-e "mirror_registry_password=$MIRROR_REGISTRY_PASSWORD")

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
echo "  Step 1/2 — Terraform: VPCs, peering, PSC, firewall, bastion VM"
echo "================================================================"
cd "$TF_DIR"
terraform init -upgrade
terraform apply --auto-approve

BASTION_IP="$(terraform output -raw bastion_public_ip)"
echo ""
echo "  Bastion VM external IP: $BASTION_IP"

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
  -e "cloud_provider=gcp" \
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/setup-bastion.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$TF_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"
ADMIN_USER="$(terraform -chdir="$TF_DIR" output -raw admin_username 2>/dev/null || echo 'ocpuser')"
GCP_PROJECT="$(terraform -chdir="$TF_DIR" output -raw gcp_project_id)"
GCP_REGION="$(terraform -chdir="$TF_DIR" output -raw gcp_region)"
CLUSTER_DOMAIN="$(terraform -chdir="$TF_DIR" output -raw cluster_domain)"
CCO_SUFFIX="${CLUSTER_DOMAIN%%.*}-cco"
HOME_DIR="/home/$ADMIN_USER"

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
echo "  2. Run the installer:"
echo ""
echo "     ./openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo ""
echo "  3. Destroy and re-run:"
echo ""
echo "     # Step 1: Destroy the cluster"
echo "     ./openshift-install destroy cluster --dir ~/install-dir --log-level=debug"
echo ""
echo "     # Step 2: Delete old CCO resources"
echo "     cd ~/cco"
echo "     $HOME_DIR/cco/ccoctl gcp delete \\"
echo "       --name $CCO_SUFFIX \\"
echo "       --project $GCP_PROJECT \\"
echo "       --credentials-requests-dir $HOME_DIR/cco/credrequests"
echo ""
echo "     # Step 3: Recreate CCO resources"
echo "     rm -rf ~/cco/manifests ~/cco/tls"
echo "     $HOME_DIR/cco/ccoctl gcp create-all \\"
echo "       --credentials-requests-dir $HOME_DIR/cco/credrequests \\"
echo "       --name $CCO_SUFFIX \\"
echo "       --region $GCP_REGION \\"
echo "       --project $GCP_PROJECT \\"
echo "       --output-dir $HOME_DIR/cco"
echo ""
echo "     # Step 4: Recreate install-dir with fresh manifests"
echo "     rm -rf ~/install-dir"
echo "     mkdir ~/install-dir"
echo "     cp ~/install-config.yaml ~/install-dir/"
echo "     ./openshift-install create manifests --dir ~/install-dir"
echo "     cp ~/cco/manifests/* ~/install-dir/manifests/"
echo "     cp -r ~/cco/tls ~/install-dir/"
echo ""
echo "     # Step 5: Re-run the installer"
echo "     ./openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo ""
echo "================================================================"
