# Connected OpenShift Environment on Azure

Set up a connected (internet-accessible) environment on Azure for deploying
OpenShift clusters. This creates the network infrastructure, a managed identity,
a service principal, and a bastion VM pre-configured with the tools and CCO
credentials needed to run `openshift-install`.

## Architecture

```
              ┌──────────────────────────────────────────────────────┐
              │          Connected VNet (172.16.0.0/16)              │
              │                                                      │
              │  ┌──────────────────────────────────────────────┐    │
              │  │  Bastion Subnet (172.16.4.0/24)              │    │
              │  │                                              │    │
              │  │  ┌──────────────┐                            │    │
  Internet ◄──┤  │  │ Bastion VM   │ ◄── Public IP              │    │
              │  │  │  - oc        │                            │    │
              │  │  │  - installer │                            │    │
              │  │  │  - ccoctl    │                            │    │
              │  │  │  - az CLI    │                            │    │
              │  │  └──────────────┘                            │    │
              │  └──────────────────────────────────────────────┘    │
              │                                                      │
              │  ┌──────────────────────────────────────────────┐    │
              │  │  OpenShift Subnets (AZ1, AZ2, AZ3)          │    │
              │  │  172.16.1-3.0/24                             │    │
              │  │                                              │    │
              │  │  OCP cluster nodes route to internet         │    │
              │  │  via NAT Gateway ──► NAT Public IP           │    │
              │  └──────────────────────────────────────────────┘    │
              │                                                      │
              │  Managed Identity (Contributor + UAA)                 │
              │  Service Principal for openshift-install              │
              │  Cluster RG: <cluster>-cluster-rg                    │
              └──────────────────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.5
- Ansible
- Azure CLI with an authenticated session (`az login`)
- An Azure service principal with Contributor + User Access Administrator
  on the subscription (for `openshift-install`)
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

## Directory Structure

```
connected/
├── terraform/
│   ├── main.tf                          # Provider configuration
│   ├── variables.tf                     # All input variables
│   ├── resource_group.tf                # Network RG + Cluster RG
│   ├── vnet.tf                          # VNet, subnets, NAT Gateway
│   ├── nsg.tf                           # NSGs for bastion + OpenShift subnets
│   ├── identity.tf                      # Managed identity for bastion VM
│   ├── service_principal.tf             # SP for openshift-install (optional auto-create)
│   ├── vm.tf                            # Bastion VM with public IP
│   ├── ansible.tf                       # Generated Ansible inventory + vars
│   ├── outputs.tf                       # All outputs (VNet IDs, IPs, RG names, etc.)
│   ├── deploy.sh                        # Environment setup script
│   ├── terraform.tfvars.example         # Example tfvars
│   └── README.md                        # This file
├── templates/
│   └── install-config.yaml.j2           # OpenShift install-config template
└── setup-bastion-vm-connected.yaml      # Ansible: install tools, CCO, install-dir
```

---

## Environment Setup

### 1. Setup the control node (only applies to RHEL9/Fedora)

```bash
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install ansible-core terraform -y
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo yum install azure-cli -y
git clone https://github.com/sadiquepp/openshift.git
az login
ssh-keygen
```

### 2. Create a Service Principal - Optional

The OpenShift installer requires a service principal with Contributor and
User Access Administrator roles:

```bash
SP=$(az ad sp create-for-rbac --name "myproject-ocp-installer" \
  --role Contributor \
  --scopes /subscriptions/<subscription-id>)

az role assignment create \
  --assignee $(echo $SP | jq -r '.appId') \
  --role "User Access Administrator" \
  --scope /subscriptions/<subscription-id>

echo $SP | jq '{clientId: .appId, clientSecret: .password, tenantId: .tenant}'
```

### 3. Create `terraform.tfvars`

```hcl
# ── Required ──────────────────────────────────────────────────────
ssh_public_key             = "ssh-rsa AAAAB3Nza..."
azure_subscription_id      = "00000000-0000-0000-0000-000000000000"
installer_sp_client_id     = "00000000-0000-0000-0000-000000000000"
installer_sp_client_secret = "xxxxxxxxxxxxxxxxxxxx"

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

### 4. Run the setup

```bash
cd openshift/azure/self-managed/connected/terraform
./deploy.sh \
  --pull-secret-file ~/pull-secret.json \
  --openshift-version 4.18.20
```

| Flag | Required | Description |
|------|----------|-------------|
| `--pull-secret-file` | Yes | Path to the OpenShift pull secret JSON file |
| `--openshift-version` | No | Full version string, e.g. `4.18.20` (default: playbook value) |

Any extra arguments are forwarded to the Ansible playbook (e.g. `-e "key=value"`).

This runs two steps:

| Step | Tool | What it does |
|------|------|--------------|
| 1 | Terraform | Creates VNet, subnets, NAT Gateway, NSGs, managed identity, service principal, bastion VM |
| 2 | Ansible (`setup-bastion-vm-connected.yaml`) | Installs packages, downloads OCP tools (oc, openshift-install, ccoctl), creates CCO resources, prepares `install-dir` |

When complete, the bastion has:
- `openshift-install`, `oc`, `ccoctl`, `az CLI`
- `osServicePrincipal.json` in `~/.azure/`
- CCO credentials in `~/cco/`
- IPI `~/install-dir/` with manifests ready for `create cluster`

### 5. SSH into the bastion

```bash
BASTION_IP=$(terraform output -raw bastion_public_ip)
ssh -i ~/.ssh/id_rsa azureuser@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

The simplest method. The installer manages all infrastructure (VMs, load
balancers, DNS) automatically.

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

### Re-deploying after destroy

After destroying a cluster, the CCO resources (storage account, federated
credentials) need to be recreated before a fresh install:

```bash
# 1. Recreate the cluster resource group
az group create --name <cluster>-cluster-rg --location southeastasia

# 2. Delete old CCO resources
cd ~/cco
ccoctl azure delete \
  --name <cluster>-cco \
  --region southeastasia \
  --subscription-id <subscription-id> \
  --storage-account-name <storage-account>

# 3. Clean CCO output files
rm -rf ~/cco/manifests ~/cco/tls ~/cco/jwks \
  ~/cco/openid-configuration \
  ~/cco/serviceaccount-signer.private \
  ~/cco/serviceaccount-signer.public

# 4. Recreate CCO resources
ccoctl azure create-all \
  --credentials-requests-dir ~/cco/credrequests \
  --name <cluster>-cco \
  --region southeastasia \
  --subscription-id <subscription-id> \
  --tenant-id <tenant-id> \
  --storage-account-name <storage-account> \
  --installation-resource-group-name <cluster>-cluster-rg \
  --network-resource-group-name <cluster>-network-rg \
  --output-dir ~/cco

# 5. Recreate install-dir
rm -rf ~/install-dir && mkdir ~/install-dir
cp ~/install-config.yaml ~/install-dir/
./openshift-install create manifests --dir ~/install-dir
cp ~/cco/manifests/* ~/install-dir/manifests/
cp -r ~/cco/tls ~/install-dir/

# 6. Re-run the installer
./openshift-install create cluster --dir ~/install-dir --log-level=debug
```

The exact commands with your cluster-specific values are printed at the end of
`deploy.sh`.

---

## Variables Reference

### Required

| Variable | Description |
|----------|-------------|
| `ssh_public_key` | SSH public key material for the bastion VM |
| `azure_subscription_id` | Azure subscription ID |
| `installer_sp_client_id` | Service principal client (app) ID |
| `installer_sp_client_secret` | Service principal client secret |

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
| `connected_vnet_cidr` | `172.16.0.0/16` | Connected VNet address space |
| `connected_subnet_cidrs` | `[172.16.1-3.0/24]` | OpenShift subnet CIDRs (one per AZ) |
| `bastion_subnet_cidr` | `172.16.4.0/24` | Bastion subnet CIDR |

### Bastion VM

| Variable | Default | Description |
|----------|---------|-------------|
| `installer_vm_size` | `Standard_D2s_v3` | Azure VM size |
| `installer_disk_size` | `100` | OS disk size in GB |
| `installer_image` | RHEL 9.4 | Source image reference (publisher, offer, sku, version) |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key (for Ansible) |
| `admin_username` | `azureuser` | Admin username for the bastion VM |

### Service Principal

| Variable | Default | Description |
|----------|---------|-------------|
| `create_service_principal` | `false` | Auto-create the SP via Terraform (experimental) |
| `azure_tenant_id` | `""` | Tenant ID (required when `create_service_principal = true`) |

---

## Outputs

After `terraform apply`, these outputs are available:

| Output | Description |
|--------|-------------|
| `bastion_public_ip` | Bastion public IP for SSH |
| `bastion_private_ip` | Bastion private IP |
| `connected_vnet_id` | Connected VNet ID |
| `connected_vnet_name` | Connected VNet name |
| `connected_subnet_ids` | OpenShift subnet IDs |
| `connected_subnet_names` | OpenShift subnet names |
| `nat_gateway_public_ip` | NAT Gateway outbound IP |
| `cluster_domain` | Fully qualified cluster domain |
| `resource_group_name` | Network resource group name |
| `cluster_resource_group_name` | Cluster resource group name |
| `installer_sp_client_id` | Service principal client ID |
| `managed_identity_client_id` | Managed identity client ID |

These values are also automatically written to `ansible-vars.json` for use
by the Ansible playbook.

---

## Teardown

```bash
# 1. Destroy any cluster first:
#    openshift-install destroy cluster --dir ~/install-dir

# 2. Destroy the environment
cd azure/self-managed/connected/terraform
terraform destroy
```
