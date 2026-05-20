# Connected OpenShift Environment on AWS

Set up a connected (internet-accessible) environment on AWS for deploying
OpenShift clusters. This creates the network infrastructure, an IAM role,
and a bastion EC2 instance pre-configured with the tools and STS credentials
needed to run `openshift-install`.

## Architecture

```
                   ┌──────────────────────────────────────────────────┐
                   │        Connected VPC (172.16.0.0/16)            │
                   │                                                  │
                   │  ┌──────────────────────────────────────────┐    │
  Internet ◄─ IGW ◄┤  │  Public Subnets (AZ1, AZ2, AZ3)         │    │
                   │  │  172.16.4-6.0/24                         │    │
                   │  │                                          │    │
                   │  │  ┌──────────────┐    ┌───────────┐       │    │
                   │  │  │ Bastion EC2  │    │ NAT       │       │    │
                   │  │  │  - oc        │    │ Gateway   │       │    │
                   │  │  │  - installer │    │           │       │    │
                   │  │  │  - ccoctl    │    └─────┬─────┘       │    │
                   │  │  └──────────────┘          │             │    │
                   │  └────────────────────────────┼─────────────┘    │
                   │                               │                  │
                   │  ┌────────────────────────────┼─────────────┐    │
                   │  │  Private Subnets (AZ1, AZ2, AZ3)        │    │
                   │  │  172.16.1-3.0/24                         │    │
                   │  │                                          │    │
                   │  │  OCP cluster nodes route to internet     │    │
                   │  │  via NAT Gateway                         │    │
                   │  └──────────────────────────────────────────┘    │
                   │                                                  │
                   │  S3 Gateway Endpoint                             │
                   └──────────────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.5
- Ansible (with `amazon.aws`, `ansible.posix` and `community.general` collections)
- AWS credentials with permissions for VPC, EC2, IAM, Route53, S3
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

### Public Route53 Hosted Zone (required for public clusters)

You must have a public Route53 hosted zone for your base domain before deploying a public cluster using `openshift-install` against install-dir-public. The installer looks up this zone to create DNS records for the cluster's API and ingress endpoints. This is a one-time setup. The same hosted zone can be reused across multiple cluster deployments. Private clusters (`install-dir`) do not require this — the installer creates and manages its own private hosted zone.

```bash
# Create the public hosted zone
aws route53 create-hosted-zone \
  --name example.com \
  --caller-reference "$(date +%s)"
```

The command returns a set of NS records. Update your domain registrar to use
these name servers so that DNS queries for your domain are resolved by Route53.

> **Note:** This is a one-time setup. The same hosted zone can be reused across
> multiple cluster deployments. Private clusters (`install-dir`) do not require
> this — the installer creates and manages its own private hosted zone.

## Directory Structure

```
connected/
├── deploy.sh                    # Environment setup script
├── README.md                    # This file
├── terraform/
│   ├── main.tf                      # Provider configuration
│   ├── variables.tf                 # All input variables
│   ├── vpc.tf                       # VPC, subnets, IGW, NAT GW, route tables, S3 endpoint
│   ├── iam.tf                       # IAM role + instance profile for bastion EC2
│   ├── ec2.tf                       # SSH key pair, security group, bastion EC2 instance
│   ├── ansible.tf                   # Generated Ansible inventory + vars
│   └── outputs.tf                   # All outputs (VPC IDs, IPs, hosted zone, etc.)
└── setup-bastion-ec2-connected.yaml # Ansible: install tools, STS, install-dir
```

---

## Environment Setup

### 1. Setup the control node (only applies to RHEL9/Fedora)

```bash
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install ansible-core terraform awscli -y
ansible-galaxy collection install amazon.aws ansible.posix community.general
git clone https://github.com/sadiquepp/openshift.git
aws configure
ssh-keygen
```

### 2. Create `terraform.tfvars`

```hcl
# ── Required ──────────────────────────────────────────────────────
ssh_public_key = "ssh-rsa AAAAB3Nza..."

# ── Naming ────────────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xx1"

# ── Region ────────────────────────────────────────────────────────
aws_region = "ap-southeast-1"

# ── Bastion EC2 ──────────────────────────────────────────────────
ssh_private_key_path    = "~/.ssh/id_rsa"
installer_ami           = "ami-04698733964af06d5"
installer_instance_type = "t2.medium"
installer_disk_size     = 50
```

### 3. Run the setup

```bash
cd openshift/aws/self-managed/connected
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
| 1 | Terraform | Creates VPC, subnets, IGW, NAT gateway, S3 endpoint, IAM role, bastion EC2 |
| 2 | Ansible (`setup-bastion-ec2-connected.yaml`) | Installs packages, downloads OCP tools (oc, openshift-install, rosa, ccoctl), creates STS resources, prepares `install-dir` |

When complete, the bastion has:
- `openshift-install`, `oc`, `rosa`, `ccoctl`, `terraform`
- STS credentials in `~/sts/`
- IPI `~/install-dir/` with manifests ready for `create cluster`

### 4. SSH into the bastion

```bash
BASTION_IP=$(cd terraform && terraform output -raw installer_public_ip)
ssh -i ~/.ssh/id_rsa ec2-user@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

The simplest method. The installer manages all infrastructure (EC2 instances,
load balancers, DNS) automatically.

```bash
ssh ec2-user@$BASTION_IP

# install-dir is already prepared with manifests and STS credentials
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
| `ssh_public_key` | SSH public key material for the EC2 key pair |

### Naming and Region

| Variable | Default | Description |
|----------|---------|-------------|
| `prefix_for_name` | `project_name` | Prefix for all resource names |
| `aws_region` | `ap-southeast-1` | AWS region |
| `openshift_base_domain` | `example.com` | Cluster base domain |
| `openshift_cluster_name_suffix` | `xx1` | Suffix for cluster name (`<prefix>-<suffix>`) |

### Network CIDRs

| Variable | Default | Description |
|----------|---------|-------------|
| `connected_vpc_cidr` | `172.16.0.0/16` | Connected VPC CIDR |
| `connected_private_subnet_cidrs` | `[172.16.1-3.0/24]` | Private subnet CIDRs (one per AZ) |
| `connected_public_subnet_cidrs` | `[172.16.4-6.0/24]` | Public subnet CIDRs (one per AZ) |

### Bastion EC2

| Variable | Default | Description |
|----------|---------|-------------|
| `installer_ami` | `ami-04698733964af06d5` | AMI for the bastion instance |
| `installer_instance_type` | `t2.medium` | Bastion instance type |
| `installer_disk_size` | `50` | Root volume size in GB |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key |

---

## Outputs

After `terraform apply`, these outputs are available:

| Output | Description |
|--------|-------------|
| `installer_public_ip` | Bastion public IP for SSH |
| `installer_private_ip` | Bastion private IP |
| `connected_vpc_id` | Connected VPC ID |
| `connected_private_subnet_ids` | Private subnet IDs (for OCP cluster) |
| `connected_public_subnet_ids` | Public subnet IDs |
| `iam_role_arn` | IAM role ARN for the bastion |
| `vpc_owner_aws_account_number` | AWS account number |

These values are also automatically written to `ansible-vars.json` for use
by the Ansible playbook.

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
cd aws/self-managed/connected/terraform
terraform destroy
```
