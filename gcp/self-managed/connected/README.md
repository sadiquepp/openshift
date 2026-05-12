# Connected OpenShift Environment on GCP

Set up a connected (internet-accessible) environment on GCP for deploying
OpenShift clusters. This creates a VPC with Cloud NAT, firewall rules, a
bastion VM service account, and a bastion VM pre-configured with the tools
and CCO credentials needed to run `openshift-install`.

## Architecture

```
              ┌──────────────────────────────────────────────────────┐
              │          Connected VPC (172.16.0.0/16)               │
              │                                                      │
              │  ┌──────────────────────────────────────────────┐    │
              │  │  Bastion Subnet (172.16.3.0/24)              │    │
              │  │                                              │    │
              │  │  ┌──────────────┐                            │    │
  Internet ◄──┤  │  │ Bastion VM   │ ◄── External IP            │    │
              │  │  │  - oc        │                            │    │
              │  │  │  - installer │                            │    │
              │  │  │  - ccoctl    │                            │    │
              │  │  │  - gcloud    │                            │    │
              │  │  └──────────────┘                            │    │
              │  └──────────────────────────────────────────────┘    │
              │                                                      │
              │  ┌──────────────────────────────────────────────┐    │
              │  │  Control-Plane Subnet (172.16.1.0/24)        │    │
              │  │  Compute Subnet (172.16.2.0/24)              │    │
              │  │                                              │    │
              │  │  OCP cluster nodes route to internet         │    │
              │  │  via Cloud NAT ──► auto-allocated IPs        │    │
              │  └──────────────────────────────────────────────┘    │
              │                                                      │
              │  Service Account (compute, DNS, IAM, storage admin)  │
              │  Cloud Router + Cloud NAT                            │
              └──────────────────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.5
- Ansible (with `community.general` and `ansible.posix` collections)
- `gcloud` CLI authenticated (`gcloud auth login`)
- A GCP project with Compute Engine API enabled
- A service account JSON key for `openshift-install` (see below)
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

## Directory Structure

```
connected/
├── deploy.sh                              # Environment setup script
├── README.md                              # This file
├── setup-bastion-vm-connected.yaml        # Ansible: install tools, CCO, install-dir
├── templates/
│   └── install-config.yaml.j2             # OpenShift install-config template
└── terraform/
    ├── main.tf                            # Provider configuration
    ├── variables.tf                       # All input variables
    ├── vpc.tf                             # VPC, subnets, Cloud Router + NAT
    ├── firewall.tf                        # Firewall rules (SSH, VNC, internal, health checks)
    ├── iam.tf                             # Service account + IAM role bindings
    ├── vm.tf                              # Bastion VM with external IP
    ├── ansible.tf                         # Generated Ansible inventory + vars
    ├── outputs.tf                         # All outputs (VPC, IPs, SA, etc.)
    └── terraform.tfvars.example           # Example tfvars
```

---

## Environment Setup

### 1. Setup the control node (only applies to RHEL9/Fedora)

```bash
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install ansible-core terraform -y
ansible-galaxy collection install community.general ansible.posix
sudo tee /etc/yum.repos.d/google-cloud-sdk.repo << 'EOF'
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el9-x86_64
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
sudo yum install google-cloud-cli -y
git clone https://github.com/sadiquepp/openshift.git
gcloud auth login
gcloud config set project <your-project-id>
ssh-keygen
```

### 2. Optional: Create a Service Account key for openshift-install. 
(This step is not required in most cases and vm identity works as of this testing. Use `use_service_account_key = false` in `terraform.tfvars` to use the VM identity instead of a service account JSON key.)

```bash
PROJECT_ID=$(gcloud config get-value project)

# Create the SA
gcloud iam service-accounts create ocp-installer \
  --display-name "OpenShift Installer"

SA_EMAIL="ocp-installer@${PROJECT_ID}.iam.gserviceaccount.com"

# Grant required roles
for ROLE in \
  roles/compute.admin \
  roles/dns.admin \
  roles/iam.roleAdmin \
  roles/iam.securityAdmin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountKeyAdmin \
  roles/iam.serviceAccountUser \
  roles/storage.admin \
  roles/iam.serviceAccountTokenCreator; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$ROLE"
done

# Create a JSON key
gcloud iam service-accounts keys create ~/ocp-installer-sa-key.json \
  --iam-account=$SA_EMAIL
```

### 3. Create `terraform.tfvars`
```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vi terraform/terraform.tfvars
```

```hcl
# ── Required ──────────────────────────────────────────────────────
gcp_project_id = "my-gcp-project"
gcp_region     = "asia-southeast1"

ssh_public_key = "ssh-rsa AAAA..."

use_service_account_key = true
installer_sa_key_file   = "~/ocp-installer-sa-key.json"

# ── Naming ────────────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xt1"
```

### 4. Run the setup

```bash
cd openshift/gcp/self-managed/connected
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
| 1 | Terraform | Creates VPC, subnets, Cloud Router + NAT, firewall rules, service account, bastion VM |
| 2 | Ansible (`setup-bastion-vm-connected.yaml`) | Installs packages, downloads OCP tools (oc, openshift-install, ccoctl), configures gcloud, creates CCO resources, prepares `install-dir` |

When complete, the bastion has:
- `openshift-install`, `oc`, `ccoctl`, `gcloud`
- Service account key in `~/.gcp/osServiceAccount.json`
- CCO credentials in `~/cco/`
- IPI `~/install-dir/` with manifests ready for `create cluster`

### 5. SSH into the bastion

```bash
BASTION_IP=$(cd terraform && terraform output -raw bastion_public_ip)
ssh -i ~/.ssh/id_rsa ocpuser@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

```bash
ssh ocpuser@$BASTION_IP

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
1. Unarchive the install-dir.
```bash
tar xjf ~/install-dir-backup.bz2
```
2. Re-run the installer
```bash
./openshift-install create cluster --dir ~/install-dir --log-level=debug
```

---

## Variables Reference

### Required

| Variable | Description |
|----------|-------------|
| `gcp_project_id` | GCP project ID |
| `ssh_public_key` | SSH public key material for the bastion VM |
| `installer_sa_key_file` | Path to SA JSON key (required when `use_service_account_key = true`) |

### Naming and Region

| Variable | Default | Description |
|----------|---------|-------------|
| `prefix_for_name` | `project_name` | Prefix for all resource names |
| `gcp_region` | `asia-southeast1` | GCP region |
| `openshift_base_domain` | `example.com` | Cluster base domain |
| `openshift_cluster_name_suffix` | `xt1` | Suffix for cluster name (`<prefix>-<suffix>`) |

### Network CIDRs

| Variable | Default | Description |
|----------|---------|-------------|
| `connected_vpc_cidr` | `172.16.0.0/16` | Connected VPC CIDR (for machineNetwork) |
| `control_plane_subnet_cidr` | `172.16.1.0/24` | Control-plane subnet CIDR |
| `compute_subnet_cidr` | `172.16.2.0/24` | Compute (worker) subnet CIDR |
| `bastion_subnet_cidr` | `172.16.3.0/24` | Bastion subnet CIDR |

### Bastion VM

| Variable | Default | Description |
|----------|---------|-------------|
| `bastion_machine_type` | `e2-standard-4` | GCE machine type |
| `bastion_disk_size_gb` | `100` | Boot disk size in GB |
| `bastion_image_family` | `rhel-9` | Image family |
| `bastion_image_project` | `rhel-cloud` | Image project |
| `admin_username` | `ocpuser` | Admin username for the bastion VM |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key (for Ansible) |

### Service Account

| Variable | Default | Description |
|----------|---------|-------------|
| `use_service_account_key` | `true` | Copy SA key to bastion (set false for VM identity) |

---

## Outputs

| Output | Description |
|--------|-------------|
| `bastion_public_ip` | Bastion external IP for SSH |
| `bastion_private_ip` | Bastion internal IP |
| `bastion_name` | Bastion VM name |
| `connected_vpc_name` | Connected VPC name |
| `connected_vpc_id` | Connected VPC self-link |
| `control_plane_subnet_name` | Control-plane subnet name |
| `compute_subnet_name` | Compute subnet name |
| `bastion_service_account_email` | Bastion SA email |
| `cluster_domain` | Fully qualified cluster domain |
| `admin_username` | SSH username |

---

## Access Bastion VNC Console for GUI Access
```bash
sudo su - vncuser
vncpasswd   # Set a strong password and select N for readonly access
exit
sudo systemctl enable vncserver@:99 --now
```
VNC server will be available on port 5999. You can access it by connecting to the bastion node's public IP on port 5999.

## Teardown

```bash
# 1. Destroy any cluster first:
#    openshift-install destroy cluster --dir ~/install-dir

# 2. Destroy the environment
cd gcp/self-managed/connected/terraform
terraform destroy
```
