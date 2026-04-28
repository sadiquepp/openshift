# Disconnected OpenShift Environment on Azure

> **Also available for AWS:** See [`aws/self-managed/disconnected/`](../../../../aws/self-managed/disconnected/terraform/README.md)
> for the equivalent setup on Amazon Web Services (includes IPI, UPI, and ROSA).

Set up a disconnected (air-gapped) environment on Azure for deploying OpenShift
clusters. This creates the network infrastructure, a bastion host with a mirror
registry and mirrored OCP images, and leaves you ready to deploy a cluster using
**IPI** (Installer-Provisioned Infrastructure).

## Architecture

```
                        ┌──────────────────────────────────────────┐
                        │       Egress VNet (172.17.0.0/16)        │
                        │                                          │
                        │   ┌──────────────┐    ┌───────────┐      │
  Internet ◄── PIP ◄───┤   │ Bastion VM   │    │ Public    │      │
                        │   │  - mirror    │    │ Subnet    │      │
                        │   │  - squid     │    │           │      │
                        │   │  - terraform │    │           │      │
                        │   └──────────────┘    └───────────┘      │
                        └────────────┬─────────────────────────────┘
                                     │
                              VNet Peering
                                     │
                        ┌────────────┴─────────────────────────────┐
                        │   Disconnected VNet (172.16.0.0/16)      │
                        │                                          │
                        │  ┌───────────┐ ┌───────┐ ┌───────────┐   │
                        │  │ Subnet    │ │Subnet │ │ Subnet    │   │
                        │  │ AZ1       │ │ AZ2   │ │ AZ3       │   │
                        │  └───────────┘ └───────┘ └───────────┘   │
                        │                                          │
                        │  ┌───────────────────────────────────┐    │
                        │  │ Private Endpoint Subnet           │    │
                        │  │  - Storage (blob)                 │    │
                        │  └───────────────────────────────────┘    │
                        │                                          │
                        │  Private DNS Zone:                       │
                        │    <cluster>.<domain>                    │
                        └──────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.5
- Ansible (with `community.general` collection)
- Azure CLI (`az`) authenticated with permissions for VNets, VMs, DNS, Storage,
  Managed Identity, and role assignments
- A **service principal** for `openshift-install` (see below)
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

### Create the Service Principal

`openshift-install` on Azure requires a service principal with a client secret --
it does not support managed identities. Create one before running `deploy.sh`
(or let `deploy.sh` create it automatically):

```bash
# Replace <subscription-id> and <name> with your values
az ad sp create-for-rbac --name "<name>-installer" \
  --role Contributor \
  --scopes /subscriptions/<subscription-id>

# Note the appId and password from the output, then grant the additional role:
az role assignment create \
  --assignee <appId> \
  --role "User Access Administrator" \
  --scope /subscriptions/<subscription-id>
```

Add the `appId` and `password` to your `terraform.tfvars` as
`installer_sp_client_id` and `installer_sp_client_secret`.
Terraform passes these to the bastion where they are written to
`~/.azure/osServicePrincipal.json` for `openshift-install`.

## Directory Structure

```
disconnected/
├── terraform/
│   ├── main.tf                      # Provider configuration
│   ├── variables.tf                 # All input variables
│   ├── resource_group.tf            # Resource group
│   ├── vnet.tf                      # Disconnected + Egress VNets, subnets, peering, route tables
│   ├── nsg.tf                       # Network security groups
│   ├── private_endpoints.tf         # Storage account + private endpoint
│   ├── dns.tf                       # Private DNS zone + VNet links
│   ├── identity.tf                  # User-assigned managed identity + role assignments
│   ├── vm.tf                        # Public IP, NIC, bastion VM
│   ├── ansible.tf                   # Generated Ansible inventory + vars
│   ├── outputs.tf                   # All outputs
│   ├── deploy.sh                    # Environment setup script
│   └── README.md                    # This file
├── setup-bastion-vm.yaml            # Ansible: configure bastion, mirror registry, images
├── files/
│   └── squid.conf                   # Squid proxy configuration
└── templates/
    ├── install-config.yaml.j2       # IPI install-config template for Azure
    ├── imageset-config.yaml.j2      # oc-mirror imageset configuration
    └── squid-allow-list.txt.j2      # Squid allow-list (Azure endpoints)
```

---

## Environment Setup

### 1. Setup the control node (only applies to RHEL9/Fedora)

```bash
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install ansible-core terraform -y
ansible-galaxy collection install community.general
git clone https://github.com/sadiquepp/openshift.git
az login          # Authenticate with Azure
ssh-keygen        # Generate SSH key pair
```

### 2. Create `terraform.tfvars`

```hcl
# ── Required ──────────────────────────────────────────────────────
ssh_public_key        = "ssh-rsa AAAAB3Nza..."
azure_subscription_id = "00000000-0000-0000-0000-000000000000"

# ── Naming ────────────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xt1"

# ── Region ────────────────────────────────────────────────────────
azure_region = "southeastasia"

# ── Bastion VM ───────────────────────────────────────────────────
ssh_private_key_path = "~/.ssh/id_rsa"
installer_vm_size    = "Standard_D2s_v3"
installer_disk_size  = 100
```

### 3. Run the setup

```bash
cd openshift/azure/self-managed/disconnected/terraform
./deploy.sh \
  --pull-secret-file ~/pull-secret.json \
  --mirror-registry-password 'MyP@ss' \
  --openshift-version 4.20.0 \
  --operators 'cluster-logging,elasticsearch-operator'
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pull-secret-file` | Yes | Path to the OpenShift pull secret JSON file |
| `--mirror-registry-password` | No | Password for the Quay mirror registry (default: playbook value) |
| `--openshift-version` | No | Full version string, e.g. `4.20.0` (default: `4.20.0`) |
| `--operators` | No | Comma-separated list of operators to mirror (default: none) |

> **Disk sizing:** Each mirrored operator adds several GB of images to the bastion's
> mirror registry. If you include more than a handful of operators, increase
> `installer_disk_size` in `terraform.tfvars` (e.g. `200` or `300` GB) before
> running `deploy.sh`.

Any extra arguments are forwarded to the Ansible playbook (e.g. `-e "key=value"`).

This runs two steps:

| Step | Tool | What it does |
|------|------|--------------|
| 1 | Terraform | Creates resource group, VNets, VNet peering, NSGs, private endpoints, DNS zone, managed identity, bastion VM |
| 2 | Ansible (`setup-bastion-vm.yaml`) | Installs packages, sets up mirror registry, mirrors OCP images, extracts tools, creates CCO credentials, prepares IPI `install-dir` |

When complete, the bastion has:
- `openshift-install`, `oc`, `terraform`, `ccoctl`
- Mirror registry on port 8443 with mirrored OCP images
- Squid proxy on port 3128
- IPI `~/install-dir/` with manifests ready for `create cluster`
- CCO credentials in `~/cco/`

### 4. SSH into the bastion

```bash
BASTION_IP=$(terraform output -raw bastion_public_ip)
ssh -i ~/.ssh/id_rsa azureuser@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

The simplest method. The installer manages all infrastructure (VMs,
load balancers, DNS) automatically.

```bash
ssh azureuser@$BASTION_IP

# install-dir is already prepared with manifests and CCO credentials
./openshift-install create cluster \
  --dir ~/install-dir \
  --log-level=debug
```

To destroy:

```bash
./openshift-install destroy cluster \
  --dir ~/install-dir \
  --log-level=debug
```

---

## Variables Reference

### Required

| Variable | Description |
|----------|-------------|
| `ssh_public_key` | SSH public key material for the bastion VM |
| `azure_subscription_id` | Azure subscription ID |

### Naming and Region

| Variable | Default | Description |
|----------|---------|-------------|
| `prefix_for_name` | `project_name` | Prefix for all resource names |
| `azure_region` | `southeastasia` | Azure region |
| `openshift_base_domain` | `example.com` | Cluster base domain |
| `openshift_cluster_name_suffix` | `xt1` | Suffix for cluster name (`<prefix>-<suffix>`) |

### Network CIDRs

| Variable | Default | Description |
|----------|---------|-------------|
| `disconnected_vnet_cidr` | `172.16.0.0/16` | Disconnected VNet address space |
| `disconnected_subnet_cidrs` | `[172.16.1-3.0/24]` | Private subnet CIDRs (one per AZ) |
| `egress_vnet_cidr` | `172.17.0.0/16` | Egress VNet address space |
| `egress_public_subnet_cidr` | `172.17.1.0/24` | Egress public subnet CIDR |
| `private_endpoint_subnet_cidr` | `172.16.10.0/24` | Subnet for private endpoints |

### Bastion VM

| Variable | Default | Description |
|----------|---------|-------------|
| `installer_vm_size` | `Standard_D2s_v3` | Bastion VM size |
| `installer_disk_size` | `100` | OS disk size in GB |
| `installer_image` | RHEL 9.4 | Source image reference |
| `admin_username` | `azureuser` | Admin username for the VM |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key |

---

## Outputs

After `terraform apply`, these outputs are available:

| Output | Description |
|--------|-------------|
| `bastion_public_ip` | Bastion public IP for SSH |
| `bastion_private_ip` | Bastion private IP |
| `resource_group_name` | Resource group name |
| `disconnected_vnet_id` | Disconnected VNet ID |
| `disconnected_subnet_ids` | Disconnected subnet IDs |
| `egress_vnet_id` | Egress VNet ID |
| `private_dns_zone_id` | Private DNS zone ID |
| `managed_identity_client_id` | Managed identity client ID |
| `storage_account_name` | Storage account name |
| `azure_subscription_id` | Azure subscription ID |
| `azure_tenant_id` | Azure tenant ID |

These values are also automatically written to `ansible-vars.json` for use
by the Ansible playbook.

---

## Populate Operators from Mirror Registry

To populate operators from the mirror registry, run the following commands from the bastion node.

```bash
export KUBECONFIG=~/install-dir/auth/kubeconfig
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
oc apply -f oc-mirror-output/working-dir/cluster-resources
```

## Teardown

```bash
# 1. Destroy any cluster first:
#    openshift-install destroy cluster --dir ~/install-dir

# 2. Destroy the environment
cd azure/self-managed/disconnected/terraform
terraform destroy
```

---

## AWS ↔ Azure Resource Mapping

| AWS Resource | Azure Equivalent |
|-------------|-----------------|
| VPC | Virtual Network (VNet) |
| Subnet | Subnet |
| Transit Gateway | VNet Peering |
| Internet Gateway | Public IP (on bastion NIC) |
| VPC Endpoints (Interface) | Private Endpoints |
| VPC Endpoints (Gateway/S3) | Private Endpoint for Storage |
| Route53 Private Zone | Azure Private DNS Zone |
| IAM Role + Instance Profile | User-Assigned Managed Identity |
| EC2 Instance | Linux Virtual Machine |
| Security Group | Network Security Group (NSG) |
| Key Pair | SSH key on VM |
