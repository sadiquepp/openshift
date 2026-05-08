# Disconnected OpenShift Environment on Azure

> **Also available for AWS:** See `[aws/self-managed/disconnected/](../../../../aws/self-managed/disconnected/terraform/README.md)`
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
  Internet ◄── PIP ◄─── ┤   │ Bastion NIC  │    │ Public    │      │
                        │   │  - mirror    │    │ Subnet    │      │
                        │   │  - squid     │    │           │      │
                        │   │  - terraform │    │           │      │
                        │   └──────────────┘    └───────────┘      │
                        │                                          │
                        │   ┌──────────────────────────────────┐   │
                        │   │ Azure Firewall (Basic SKU)       │   │
                        │   │  AzureFirewallSubnet             │   │
                        │   │  AzureFirewallManagementSubnet   │   │
  Internet ◄── PIP ◄─── ┤   │  3 FQDN rules:                   │   │
                        │   │   - management.azure.com         │   │
                        │   │   - login.microsoftonline.com    │   │
                        │   │   - *.blob.core.windows.net      │   │
                        │   └──────────────────────────────────┘   │
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
                        │  UDR: 0.0.0.0/0 → Azure Firewall         │
                        │                                          │
                        │  ┌───────────────────────────────────┐   │
                        │  │ Private Endpoint Subnet           │   │
                        │  │  - Storage (blob)                 │   │
                        │  │  - Storage (table)                │   │
                        │  └───────────────────────────────────┘   │
                        │                                          │
                        │  Private DNS Zone:                       │
                        │    (created by the installer)            │
                        └──────────────────────────────────────────┘
```

### Egress Traffic Flow

OpenShift nodes in the disconnected VNet have **no proxy configuration**.
All egress is handled transparently:


| Destination                                | Path             | Notes                      |
| ------------------------------------------ | ---------------- | -------------------------- |
| `*.blob.core.windows.net` (our storage)    | Private Endpoint | Stays in-VNet              |
| `*.table.core.windows.net` (our storage)   | Private Endpoint | Boot diagnostics           |
| `management.azure.com`                     | Azure Firewall   | ARM API (no Private Link)  |
| `login.microsoftonline.com`                | Azure Firewall   | Entra ID (no Private Link) |
| `*.blob.core.windows.net` (other accounts) | Azure Firewall   | Ignition files             |
| Everything else                            | Blocked          | Dropped by firewall        |


> **Cost note:** Azure Firewall Basic costs ~~$0.395/hr (~~$288/month) plus
> data processing charges. Set `firewall_sku = "Standard"` if you need
> features like DNS proxy or threat intelligence (~$1.25/hr). See the
> [Azure Firewall pricing page](https://azure.microsoft.com/en-us/pricing/details/azure-firewall/).

## Prerequisites

- Terraform >= 1.5
- Ansible (with `community.general` collection)
- Azure CLI (`az`) authenticated with permissions for VNets, VMs, DNS, Storage,
Managed Identity, and role assignments
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

### Service Principal for openshift-install

`openshift-install` on Azure requires a service principal with a client secret. Create the SP before running
`deploy.sh`:

```bash
az ad sp create-for-rbac --name "<cluster>-installer" \
  --role Contributor \
  --scopes /subscriptions/<subscription-id> \
  --output json

# Note the appId and password, then grant the additional role:
az role assignment create \
  --assignee <appId> \
  --role "User Access Administrator" \
  --scope /subscriptions/<subscription-id>
```

Add the values to `terraform.tfvars`:

```hcl
installer_sp_client_id     = "<appId>"
installer_sp_client_secret = "<password>"
```

Terraform passes these to the bastion via Ansible, which writes
`~/.azure/osServicePrincipal.json` automatically.

> **Experimental:** Set `create_service_principal = true` and provide
> `azure_tenant_id` to let Terraform create the SP automatically via the
> `azuread` provider. This requires Entra ID Application Administrator
> permissions and may fail in some tenant configurations.

## Directory Structure

```
disconnected/
├── deploy.sh                        # Environment setup script
├── README.md                        # This file
├── terraform/
│   ├── main.tf                      # Provider configuration
│   ├── variables.tf                 # All input variables
│   ├── resource_group.tf            # Resource group
│   ├── vnet.tf                      # VNets, subnets, peering, route tables (UDR → firewall)
│   ├── firewall.tf                  # Azure Firewall, policy, FQDN rules
│   ├── nsg.tf                       # Network security groups
│   ├── private_endpoints.tf         # Storage private endpoints (blob + table)
│   ├── dns.tf                       # (DNS managed by installer, see notes)
│   ├── identity.tf                  # User-assigned managed identity + role assignments
│   ├── service_principal.tf         # Auto-created SP for openshift-install (optional)
│   ├── vm.tf                        # Public IP, NIC, bastion VM
│   ├── ansible.tf                   # Generated Ansible inventory + vars
│   └── outputs.tf                   # All outputs
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

### 2. Create `terraform.tfvars`. Use the provided `terraform.tfvars.example` as a template.

```hcl
# ── Required ──────────────────────────────────────────────────────
ssh_public_key        = "ssh-rsa AAAAB3Nza..."
azure_subscription_id = "00000000-0000-0000-0000-000000000000"
azure_tenant_id       = "00000000-0000-0000-0000-000000000000"

# ── Service Principal (Required) ─────────────────────────────────
# Leave empty to auto-create via Terraform (requires Entra ID
# app registration permissions). Or provide a pre-created SP:
installer_sp_client_id     = "00000000-0000-0000-0000-000000000000"
installer_sp_client_secret = "xxxxxxxxxxxxxxxxxxxx"

# ── Naming ────────────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xt1"

# ── Region ────────────────────────────────────────────────────────
azure_region = "southeastasia"

# ── Disconnected VNet ─────────────────────────────────────────────
disconnected_vnet_cidr    = "172.16.0.0/16"
disconnected_subnet_cidrs = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]

# ── Egress VNet ──────────────────────────────────────────────────
egress_vnet_cidr          = "172.17.0.0/16"
egress_public_subnet_cidr = "172.17.1.0/24"

# ── Private Endpoints ────────────────────────────────────────────
private_endpoint_subnet_cidr = "172.16.10.0/24"

# ── Azure Firewall ──────────────────────────────────────────────
firewall_sku = "Basic"
firewall_subnet_cidr = "172.17.100.0/26"
firewall_management_subnet_cidr = "172.17.100.64/26"

# ── Bastion VM ───────────────────────────────────────────────────
ssh_private_key_path    = "~/.ssh/id_rsa"
installer_vm_size       = "Standard_D2s_v3"
installer_disk_size     = 100
installer_image         = {
  publisher = "RedHat"
  offer     = "RHEL"
  sku       = "9_4"
  version   = "latest"
}
admin_username          = "azureuser"
```

### 3. Run the setup

```bash
cd openshift/azure/self-managed/disconnected
./deploy.sh \
  --pull-secret-file ~/pull-secret.json \
  --mirror-registry-password 'MyP@ss' \
  --openshift-version 4.20.0 \
  --operators 'cluster-logging,elasticsearch-operator'
```


| Flag                         | Required | Description                                                     |
| ---------------------------- | -------- | --------------------------------------------------------------- |
| `--pull-secret-file`         | Yes      | Path to the OpenShift pull secret JSON file                     |
| `--mirror-registry-password` | No       | Password for the Quay mirror registry (default: playbook value) |
| `--openshift-version`        | No       | Full version string, e.g. `4.20.0` (default: `4.20.0`)          |
| `--operators`                | No       | Comma-separated list of operators to mirror (default: none)     |


> **Disk sizing:** Each mirrored operator adds several GB of images to the bastion's
> mirror registry. If you include more than a handful of operators, increase
> `installer_disk_size` in `terraform.tfvars` (e.g. `200` or `300` GB) before
> running `deploy.sh`.

Any extra arguments are forwarded to the Ansible playbook (e.g. `-e "key=value"`).

This runs two steps:


| Step | Tool                              | What it does                                                                                                                        |
| ---- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Terraform                         | Creates resource group, VNets, VNet peering, NSGs, private endpoints, DNS zone, managed identity, bastion VM                        |
| 2    | Ansible (`setup-bastion-vm.yaml`) | Installs packages, sets up mirror registry, mirrors OCP images, extracts tools, creates CCO credentials, prepares IPI `install-dir` |


When complete, the bastion has:

- `openshift-install`, `oc`, `terraform`, `ccoctl`
- Mirror registry on port 8444 with mirrored OCP images
- Squid proxy on port 3128
- IPI `~/install-dir/` with manifests ready for `create cluster`
- CCO credentials in `~/cco/`

### 4. SSH into the bastion

```bash
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)
ssh -i ~/.ssh/id_rsa azureuser@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

The simplest method. The installer manages all infrastructure (VMs,
load balancers, DNS) automatically.

The installer creates a private DNS zone for the cluster and links it only
to the disconnected VNet. The bastion (egress VNet) must also be linked so
that the installer can verify the API is reachable. The commands below start
a background watcher that creates the VNet link as soon as the DNS zone
appears, then run the installer in the foreground.

```bash
ssh azureuser@$BASTION_IP
```
```bash
# ── Set variables ────────────────────────────────────────────────
CLUSTER_DOMAIN="<cluster>.<domain>"
CLUSTER_RG="<cluster>-rg"
EGRESS_VNET_ID="<egress-vnet-id>"
```
```bash
# ── Background: link cluster DNS to egress VNet mid-install ──────
(
  echo "[dns-linker] Logging in to Azure with managed identity ..."
  az login --identity
  echo "[dns-linker] Waiting for DNS zone ${CLUSTER_DOMAIN} in ${CLUSTER_RG} ..."
  while ! az network private-dns zone show \
    -g "$CLUSTER_RG" -n "$CLUSTER_DOMAIN" &>/dev/null; do sleep 10; done

  echo "[dns-linker] Creating egress VNet link ..."
  az network private-dns link vnet create \
    --resource-group "$CLUSTER_RG" \
    --zone-name "$CLUSTER_DOMAIN" \
    --name egress-vnet-link \
    --virtual-network "$EGRESS_VNET_ID" \
    --registration-enabled false

  echo "[dns-linker] Done. api.${CLUSTER_DOMAIN} is now resolvable from the bastion."
) &

# ── Foreground: run the installer ────────────────────────────────
./openshift-install create cluster \
  --dir ~/install-dir \
  --log-level=debug
```

> The cluster resource group (`<cluster>-rg`) is pre-created by Terraform
> so that `ccoctl` can scope role assignments to it. The installer uses it
> via `platform.azure.resourceGroupName` in `install-config.yaml`.
> `openshift-install destroy cluster` deletes the cluster RG and its
> contents. You must recreate it before re-running the installer.

### Destroy and re-run

The installer deletes the cluster resource group on destroy. Since `ccoctl`
role assignments are scoped to that RG, they become invalid when the RG is
recreated. A re-run requires `ccoctl delete` then `ccoctl create-all`.

```bash
# 1. Destroy the cluster
./openshift-install destroy cluster \
  --dir ~/install-dir \
  --log-level=debug

# 2. Recreate the cluster RG
az group create --name <cluster>-cluster-rg --location <region>

# 3. Delete and recreate CCO resources
cd ~/cco
/home/azureuser/cco/ccoctl azure delete \
  --name <cco_suffix> \
  --region <region> \
  --subscription-id <subscription-id> \
  --tenant-id <tenant-id>

# 4. Delete the manifests, tls, jwk, openid-configuration files and directories
rm -rf ~/cco/manifests ~/cco/tls ~/cco/jwks ~/cco/openid-configuration ~/cco/serviceaccount-signer.private ~/cco/serviceaccount-signer.public

/home/azureuser/cco/ccoctl azure create-all \
  --credentials-requests-dir ~/cco/credrequests \
  --name <cco_suffix> \
  --region <region> \
  --subscription-id <subscription-id> \
  --tenant-id <tenant-id> \
  --storage-account-name <cco_storage_account> \
  --installation-resource-group-name <cluster>-cluster-rg \
  --network-resource-group-name <cluster>-network-rg \
  --output-dir ~/cco

# 4. Recreate install-dir with fresh manifests
rm -rf ~/install-dir
mkdir ~/install-dir
cp ~/install-config.yaml ~/install-dir/
./openshift-install create manifests --dir ~/install-dir
cp ~/cco/manifests/* ~/install-dir/manifests/
cp -r ~/cco/tls ~/install-dir/

# 5. Re-run the installer
./openshift-install create cluster --dir ~/install-dir --log-level=debug
```

---

## Variables Reference

### Required


| Variable                     | Description                                |
| ---------------------------- | ------------------------------------------ |
| `ssh_public_key`             | SSH public key material for the bastion VM |
| `azure_subscription_id`      | Azure subscription ID                      |
| `installer_sp_client_id`     | Service principal application (client) ID  |
| `installer_sp_client_secret` | Service principal client secret             |

### Auto-create SP (experimental)

| Variable                     | Default | Description                                                           |
| ---------------------------- | ------- | --------------------------------------------------------------------- |
| `create_service_principal`   | `false` | Set `true` to auto-create SP (not recommended, may fail in some tenants) |
| `azure_tenant_id`            | `""`    | Required when `create_service_principal = true`                       |


### Naming and Region


| Variable                        | Default         | Description                                   |
| ------------------------------- | --------------- | --------------------------------------------- |
| `prefix_for_name`               | `project_name`  | Prefix for all resource names                 |
| `azure_region`                  | `southeastasia` | Azure region                                  |
| `openshift_base_domain`         | `example.com`   | Cluster base domain                           |
| `openshift_cluster_name_suffix` | `xt1`           | Suffix for cluster name (`<prefix>-<suffix>`) |


### Network CIDRs


| Variable                          | Default             | Description                                  |
| --------------------------------- | ------------------- | -------------------------------------------- |
| `disconnected_vnet_cidr`          | `172.16.0.0/16`     | Disconnected VNet address space              |
| `disconnected_subnet_cidrs`       | `[172.16.1-3.0/24]` | Private subnet CIDRs (one per AZ)            |
| `egress_vnet_cidr`                | `172.17.0.0/16`     | Egress VNet address space                    |
| `egress_public_subnet_cidr`       | `172.17.1.0/24`     | Egress public subnet CIDR                    |
| `private_endpoint_subnet_cidr`    | `172.16.10.0/24`    | Subnet for private endpoints                 |
| `firewall_subnet_cidr`            | `172.17.100.0/26`   | AzureFirewallSubnet CIDR (min /26)           |
| `firewall_management_subnet_cidr` | `172.17.100.64/26`  | AzureFirewallManagementSubnet CIDR (min /26) |


### Azure Firewall


| Variable       | Default | Description                                           |
| -------------- | ------- | ----------------------------------------------------- |
| `firewall_sku` | `Basic` | Firewall SKU tier (`Basic`, `Standard`, or `Premium`) |


### Bastion VM


| Variable               | Default           | Description               |
| ---------------------- | ----------------- | ------------------------- |
| `installer_vm_size`    | `Standard_D2s_v3` | Bastion VM size           |
| `installer_disk_size`  | `100`             | OS disk size in GB        |
| `installer_image`      | RHEL 9.4          | Source image reference    |
| `admin_username`       | `azureuser`       | Admin username for the VM |
| `ssh_private_key_path` | `~/.ssh/id_rsa`   | Path to SSH private key   |


---

## Outputs

After `terraform apply`, these outputs are available:


| Output                       | Description                              |
| ---------------------------- | ---------------------------------------- |
| `bastion_public_ip`          | Bastion public IP for SSH                |
| `bastion_private_ip`         | Bastion private IP                       |
| `firewall_private_ip`        | Azure Firewall private IP (UDR next hop) |
| `firewall_public_ip`         | Azure Firewall public IP                 |
| `installer_sp_client_id`     | SP client ID (auto-created or provided)  |
| `resource_group_name`        | Resource group name                      |
| `disconnected_vnet_id`       | Disconnected VNet ID                     |
| `disconnected_subnet_ids`    | Disconnected subnet IDs                  |
| `egress_vnet_id`             | Egress VNet ID                           |
| `managed_identity_client_id` | Managed identity client ID               |
| `storage_account_name`       | Storage account name                     |
| `azure_subscription_id`      | Azure subscription ID                    |
| `azure_tenant_id`            | Azure tenant ID                          |


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


| AWS Resource                | Azure Equivalent               |
| --------------------------- | ------------------------------ |
| VPC                         | Virtual Network (VNet)         |
| Subnet                      | Subnet                         |
| Transit Gateway             | VNet Peering                   |
| Internet Gateway            | Public IP (on bastion NIC)     |
| VPC Endpoints (Interface)   | Private Endpoints              |
| VPC Endpoints (Gateway/S3)  | Private Endpoint for Storage   |
| Route53 Private Zone        | Azure Private DNS Zone         |
| IAM Role + Instance Profile | User-Assigned Managed Identity |
| EC2 Instance                | Linux Virtual Machine          |
| Security Group              | Network Security Group (NSG)   |
| Key Pair                    | SSH key on VM                  |


