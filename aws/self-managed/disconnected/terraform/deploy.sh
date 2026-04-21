#!/usr/bin/env bash
#
# Set up a disconnected environment for OpenShift on AWS.
#
#   Step 1  terraform apply   – VPCs, transit GW, endpoints, bastion EC2
#   Step 2  ansible-playbook  – configure bastion, mirror registry, mirror images
#   Step 3  ansible-playbook  – prepare install-dir-upi (manifests + ignition)
#
# After this script completes, SSH into the bastion and deploy a cluster
# using the method of your choice: IPI, UPI, or ROSA.
#
# Usage:
#   ./deploy.sh -e "pull_secret=$(cat ~/pull-secret.json)"
#
#   Any extra arguments are forwarded to the Ansible playbooks.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Step 1: Terraform (infra + bastion EC2) ──────────────────────────────────

echo "================================================================"
echo "  Step 1/3 — Terraform: VPCs, transit GW, endpoints, bastion EC2"
echo "================================================================"
cd "$SCRIPT_DIR"
terraform init -upgrade
terraform apply

BASTION_IP="$(terraform output -raw installer_public_ip)"
echo ""
echo "  Bastion EC2 public IP: $BASTION_IP"

# ── Step 2: Ansible (configure the bastion) ──────────────────────────────────

echo ""
echo "================================================================"
echo "  Step 2/3 — Ansible: configure bastion, mirror registry, images"
echo "================================================================"
echo "  Waiting 30s for EC2 SSH to become available ..."
sleep 30

EXTRA_ARGS=()
if [[ $# -gt 0 ]]; then
  EXTRA_ARGS=("$@")
fi

ansible-playbook \
  -i "$SCRIPT_DIR/inventory.ini" \
  -e "@$SCRIPT_DIR/ansible-vars.json" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/setup-bastion-ec2.yaml"

# ── Step 3: Prepare UPI install directory ────────────────────────────────────

echo ""
echo "================================================================"
echo "  Step 3/3 — Ansible: prepare install-dir-upi (manifests + ignition)"
echo "================================================================"

ansible-playbook \
  -i "$SCRIPT_DIR/inventory.ini" \
  -e "@$SCRIPT_DIR/ansible-vars.json" \
  "${EXTRA_ARGS[@]}" \
  "$PLAYBOOK_DIR/prepare-upi-install-dir.yaml"

# ── Done ─────────────────────────────────────────────────────────────────────

SSH_KEY="$(terraform -chdir="$SCRIPT_DIR" output -raw ssh_private_key_path 2>/dev/null || echo '~/.ssh/id_rsa')"

echo ""
echo "================================================================"
echo "  Environment ready!"
echo ""
echo "  Bastion: ssh -i $SSH_KEY ec2-user@$BASTION_IP"
echo ""
echo "  The bastion has: oc, openshift-install, rosa, terraform,"
echo "  mirror registry (port 8443), squid proxy, and mirrored"
echo "  OpenShift images."
echo ""
echo "  ── Choose a deployment method ─────────────────────────────"
echo ""
echo "  IPI (Installer-Provisioned Infrastructure):"
echo "    install-dir is already prepared on the bastion."
echo "    ssh ec2-user@$BASTION_IP"
echo "    openshift-install create cluster --dir ~/install-dir --log-level=debug"
echo ""
echo "  UPI (User-Provisioned Infrastructure):"
echo "    install-dir-upi and upi-terraform are ready on the bastion."
echo "    NLB + Route53 DNS are pre-configured (create_nlb_and_dns=true in tfvars)."
echo "    Set to false if you prefer to bring your own LB and DNS."
echo "    1. Edit ~/upi-terraform/terraform.tfvars (set rhcos_ami_id + private IPs)"
echo "    2. cd ~/upi-terraform && terraform init && terraform apply"
echo "    See upi/terraform-three-az/README.md for details."
echo ""
echo "  ROSA (Red Hat OpenShift Service on AWS):"
echo "    ROSA scripts are pre-templated on the bastion."
echo "    ssh ec2-user@$BASTION_IP"
echo "    rosa login --token=<token>"
echo "    ./rosa-create-cluster-hcp.sh   # or other rosa-*.sh variants"
echo "================================================================"
