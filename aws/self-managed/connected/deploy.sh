#!/usr/bin/env bash
#
# Set up a connected environment for OpenShift on AWS.
#
#   Step 1  terraform apply   – VPC, IGW, NAT GW, Route53 zone, IAM role, bastion EC2
#   Step 2  ansible-playbook  – configure bastion, install tools, create STS resources
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
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"
PLAYBOOK="$REPO_ROOT/cloud/self-managed/connected/setup-bastion-vm-connected.yaml"

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

# ── Step 1: Terraform (infra + bastion EC2) ──────────────────────────────────

echo "================================================================"
echo "  Step 1/2 — Terraform: VPC, IGW, NAT GW, Route53, IAM, EC2"
echo "================================================================"
cd "$TF_DIR"
terraform init -upgrade
terraform apply -auto-approve

BASTION_IP="$(terraform output -raw installer_public_ip)"
echo ""
echo "  Bastion EC2 public IP: $BASTION_IP"

# ── Step 2: Ansible (configure the bastion) ──────────────────────────────────

echo ""
echo "================================================================"
echo "  Step 2/2 — Ansible: install tools, STS resources, install-dir"
echo "================================================================"
echo "  Waiting 30s for EC2 SSH to become available ..."
sleep 30

ansible-playbook \
  -i "$TF_DIR/inventory.ini" \
  -e "@$TF_DIR/ansible-vars.json" \
  -e "cloud_provider=aws" \
  "${ANSIBLE_EXTRA[@]}" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$TF_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"

echo ""
echo "================================================================"
echo "  Environment ready!"
echo ""
echo "  Bastion: ssh -i $SSH_KEY ec2-user@$BASTION_IP"
echo ""
echo "  The bastion has: oc, openshift-install, rosa, ccoctl, terraform"
echo "  and STS credentials prepared."
echo ""
echo "  ── Deploy a cluster ──────────────────────────────────────────"
echo ""
echo "  IPI (Installer-Provisioned Infrastructure):"
echo "    ssh ec2-user@$BASTION_IP"
echo "    ./openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo "================================================================"
