# Connected OpenShift Environment on IBM Cloud

Set up a connected (internet-accessible) environment on IBM Cloud for deploying
OpenShift clusters. This creates a VPC with public gateways, security groups, and
a bastion VSI pre-configured with the tools and CCO credentials needed to run
`openshift-install`.

## Architecture

```
           ┌──────────────────────────────────────────────────────────────┐
           │                Connected VPC (172.16.0.0/16)                │
           │                                                              │
           │  ┌────────────────────────────────────────────────────────┐  │
           │  │  Bastion Subnet (172.16.10.0/24) — zone 1              │  │
           │  │                                                        │  │
           │  │  ┌──────────────────┐                                  │  │
  Internet │  │  │  Bastion VSI     │ ◄── Floating IP                  │  │
     ◄─────┤  │  │  - oc            │                                  │  │
           │  │  │  - installer     │                                  │  │
           │  │  │  - ccoctl        │                                  │  │
           │  │  │  - ibmcloud CLI  │                                  │  │
           │  │  └──────────────────┘                                  │  │
           │  └────────────────────────────────────────────────────────┘  │
           │                                                              │
           │  ┌────────────────────────────────────────────────────────┐  │
           │  │  Control-Plane Subnets          Compute Subnets        │  │
           │  │  172.16.1.0/24 (zone 1)         172.16.4.0/24 (zone 1) │  │
           │  │  172.16.2.0/24 (zone 2)         172.16.5.0/24 (zone 2) │  │
           │  │  172.16.3.0/24 (zone 3)         172.16.6.0/24 (zone 3) │  │
           │  │                                                        │  │
           │  │  All subnets ──► Public Gateway ──► Internet           │  │
           │  └────────────────────────────────────────────────────────┘  │
           │                                                              │
           │  Security Group (SSH 22, VNC 5999, internal, all outbound)  │
           └──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.5
- Ansible
- IBM Cloud CLI (`ibmcloud`) authenticated
- An IBM Cloud API key with sufficient IAM permissions
- An existing resource group (or let Terraform create one)
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

## Directory Structure

```
connected/
├── terraform/
│   ├── main.tf                          # Provider + resource group data source
│   ├── variables.tf                     # All input variables
│   ├── vpc.tf                           # VPC, address prefixes, subnets, public gateways
│   ├── security_groups.tf               # Security group + rules for bastion
│   ├── vm.tf                            # SSH key, image, floating IP, bastion VSI
│   ├── ansible.tf                       # Generated Ansible inventory + vars
│   ├── outputs.tf                       # All outputs (VPC, IPs, etc.)
│   ├── deploy.sh                        # Environment setup script
│   ├── terraform.tfvars.example         # Example tfvars
│   └── README.md                        # This file
├── templates/
│   └── install-config.yaml.j2           # OpenShift install-config template
└── setup-bastion-vm-connected.yaml      # Ansible: install tools, CCO, install-dir
```

---

## Environment Setup

### 1. Setup the control node

```bash
# Install Terraform
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install ansible-core terraform -y

# Install IBM Cloud CLI
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
ibmcloud plugin install vpc-infrastructure

# Login
export IBM_CLOUD_API_KEY="<your-api-key-here>"
ibmcloud login -r us-east

# Generate SSH key
ssh-keygen

# Clone the repo
git clone https://github.com/sadiquepp/openshift.git
```

### 2. Find the latest RHEL 9 image

```bash
ibmcloud is images --visibility public --status available | grep redhat-9
```

Use the image name in `bastion_image_name` if the default is outdated.

### 3. Create `terraform.tfvars`

```hcl
# ── Required ──────────────────────────────────────────────
ibmcloud_region     = "us-east"
ibmcloud_api_key    = "your-api-key-here"
create_resource_group = true
resource_group_name   = "my-ocp-rg"

ssh_public_key = "ssh-rsa AAAA..."

# ── Naming ────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xt1"
```

### 4. Run the setup

```bash
cd openshift/ibmcloud/self-managed/connected/terraform
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
| 1 | Terraform | Creates VPC, subnets, public gateways, security group, SSH key, bastion VSI |
| 2 | Ansible (`setup-bastion-vm-connected.yaml`) | Installs packages, IBM Cloud CLI, downloads OCP tools, creates CCO service IDs, prepares `install-dir` |

When complete, the bastion has:
- `openshift-install`, `oc`, `ccoctl`, `ibmcloud`
- `IC_API_KEY` exported in `~/.bashrc`
- CCO credentials in `~/cco/`
- IPI `~/install-dir/` with manifests ready for `create cluster`

### 5. SSH into the bastion

```bash
BASTION_IP=$(terraform output -raw bastion_floating_ip)
ssh -i ~/.ssh/id_rsa root@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

```bash
ssh root@$BASTION_IP

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

```bash
# 1. Delete old CCO resources
cd ~/cco
ccoctl ibmcloud delete-service-id \
  --credentials-requests-dir ~/cco/credrequests \
  --name <cluster>-cco

# 2. Recreate CCO resources
rm -rf ~/cco/manifests ~/cco/tls
ccoctl ibmcloud create-service-id \
  --credentials-requests-dir ~/cco/credrequests \
  --name <cluster>-cco \
  --output-dir ~/cco

# 3. Recreate install-dir
rm -rf ~/install-dir && mkdir ~/install-dir
cp ~/install-config.yaml ~/install-dir/
./openshift-install create manifests --dir ~/install-dir
cp ~/cco/manifests/* ~/install-dir/manifests/
cp -r ~/cco/tls ~/install-dir/

# 4. Re-run the installer
./openshift-install create cluster --dir ~/install-dir --log-level=debug
```

The exact commands with your cluster-specific values are printed at the end of
`deploy.sh`.

---

## Variables Reference

### Required

| Variable | Description |
|----------|-------------|
| `ibmcloud_api_key` | IBM Cloud API key (or set `IC_API_KEY` env var) |
| `ssh_public_key` | SSH public key material for the bastion VM |

### Naming and Region

| Variable | Default | Description |
|----------|---------|-------------|
| `prefix_for_name` | `project_name` | Prefix for all resource names |
| `ibmcloud_region` | `us-east` | IBM Cloud region |
| `create_resource_group` | `true` | Create a new resource group (set `false` to use existing) |
| `resource_group_name` | `Default` | Resource group name (created or existing) |
| `openshift_base_domain` | `example.com` | Cluster base domain |
| `openshift_cluster_name_suffix` | `xt1` | Suffix for cluster name (`<prefix>-<suffix>`) |

### Zones

| Variable | Default | Description |
|----------|---------|-------------|
| `zones` | `["us-east-1", "us-east-2", "us-east-3"]` | VPC zones (one subnet per zone) |

### Network CIDRs

| Variable | Default | Description |
|----------|---------|-------------|
| `connected_vpc_cidr` | `172.16.0.0/16` | Supernet CIDR (machineNetwork) |
| `control_plane_subnet_cidrs` | `["172.16.1.0/24", ...]` | CP subnet per zone |
| `compute_subnet_cidrs` | `["172.16.4.0/24", ...]` | Compute subnet per zone |
| `bastion_subnet_cidr` | `172.16.10.0/24` | Bastion subnet (zone 1) |

### Bastion VM

| Variable | Default | Description |
|----------|---------|-------------|
| `bastion_profile` | `bx2-4x16` | VPC instance profile |
| `bastion_image_name` | `ibm-redhat-9-4-minimal-amd64-3` | Stock RHEL 9 image name |
| `bastion_boot_volume_size` | `100` | Boot volume in GB |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | SSH private key (for Ansible) |

---

## Outputs

| Output | Description |
|--------|-------------|
| `bastion_floating_ip` | Bastion external IP for SSH |
| `bastion_private_ip` | Bastion internal IP |
| `bastion_name` | Bastion VSI name |
| `connected_vpc_name` | VPC name |
| `connected_vpc_id` | VPC ID |
| `control_plane_subnet_names` | CP subnet names |
| `compute_subnet_names` | Compute subnet names |
| `cluster_domain` | Fully qualified cluster domain |
| `resource_group_name` | Resource group |

---

## IBM Cloud vs Other Providers

| Concept | AWS | Azure | GCP | IBM Cloud |
|---------|-----|-------|-----|-----------|
| Network | VPC + IGW + NAT GW | VNet + NAT Gateway | VPC + Cloud NAT | VPC + Public Gateway |
| Subnets | Per-AZ | Per-AZ | Per-region | Per-zone |
| Identity | IAM Role / Instance Profile | Managed Identity + SP | Service Account | API Key (`IC_API_KEY`) |
| CCO tool | `ccoctl aws create-all` | `ccoctl azure create-all` | `ccoctl gcp create-all` | `ccoctl ibmcloud create-service-id` |
| Bastion IP | Elastic IP | Public IP | Static External IP | Floating IP |
| Bastion user | `ec2-user` | `azureuser` | `ocpuser` | `root` |

---

## Teardown

```bash
# 1. Destroy any cluster first:
#    openshift-install destroy cluster --dir ~/install-dir

# 2. Destroy the environment
cd ibmcloud/self-managed/connected/terraform
terraform destroy
```
