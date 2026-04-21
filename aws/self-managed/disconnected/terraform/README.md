# Disconnected OpenShift Environment on AWS

Set up a disconnected (air-gapped) environment on AWS for deploying OpenShift
clusters. This creates the network infrastructure, a bastion host with a mirror
registry and mirrored OCP images, and leaves you ready to deploy a cluster using
the method of your choice: **IPI**, **UPI**, or **ROSA**.

## Architecture

```
                        ┌──────────────────────────────────────────┐
                        │          Egress VPC (172.17.0.0/16)      │
                        │                                          │
                        │   ┌──────────────┐    ┌───────────┐      │
  Internet ◄──── IGW ◄──┤   │ Bastion EC2  │    │ Public    │      │
                        │   │  - mirror    │    │ Subnet    │      │
                        │   │  - squid     │    │ (AZ1)     │      │
                        │   │  - terraform │    │           │      │
                        │   └──────────────┘    └───────────┘      │
                        └────────────┬─────────────────────────────┘
                                     │
                              Transit Gateway
                                     │
                        ┌────────────┴─────────────────────────────┐
                        │     Disconnected VPC (172.16.0.0/16)     │
                        │                                          │
                        │  ┌───────────┐ ┌───────┐ ┌───────────┐   │
                        │  │ Subnet    │ │Subnet │ │ Subnet    │   │
                        │  │ AZ1       │ │ AZ2   │ │ AZ3       │   │
                        │  └───────────┘ └───────┘ └───────────┘   │
                        │                                          │
                        │  VPC Endpoints: S3, EC2, STS, ELB,       │
                        │                 ECR API, ECR DKR         │
                        │                                          │
                        │  Route53 Private Zone:                   │
                        │    <cluster>.<domain>                    │
                        └──────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.5
- Ansible (with `amazon.aws` and `community.aws` collections)
- AWS credentials with permissions for VPC, EC2, IAM, Route53, S3, Transit Gateway
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

## Directory Structure

```
disconnected/
├── terraform/
│   ├── main.tf                      # Provider configuration
│   ├── variables.tf                 # All input variables
│   ├── vpc.tf                       # Disconnected + Egress VPCs and subnets
│   ├── transit_gateway.tf           # IGW, Transit Gateway, route tables
│   ├── iam.tf                       # IAM role + instance profile for bastion EC2
│   ├── endpoints.tf                 # Security group + VPC endpoints
│   ├── route53.tf                   # Private hosted zone + egress VPC association
│   ├── ec2.tf                       # SSH key pair, security group, bastion EC2 instance
│   ├── ansible.tf                   # Generated Ansible inventory + vars
│   ├── outputs.tf                   # All outputs (VPC IDs, IPs, hosted zone, etc.)
│   ├── deploy.sh                    # Environment setup script
│   └── README.md                    # This file
├── setup-bastion-ec2.yaml           # Ansible: configure bastion, mirror registry, images
├── prepare-upi-install-dir.yaml     # Ansible: create install-dir-upi for UPI deployments
├── files/
│   ├── policy.json                  # EC2 assume-role policy
│   └── squid.conf                   # Squid proxy configuration
└── templates/
    ├── install-config.yaml.j2       # IPI install-config template
    ├── install-config-upi.yaml.j2   # UPI install-config template
    ├── imageset-config.yaml.j2      # oc-mirror imageset configuration
    ├── squid-allow-list.txt.j2      # Squid allow-list
    └── rosa-*.sh.j2                 # ROSA create/delete cluster scripts
```

---

## Environment Setup

### 1. Create `terraform.tfvars`

```hcl
# ── Required ──────────────────────────────────────────────────────
ssh_public_key = "ssh-rsa AAAAB3Nza..."

# ── Naming ────────────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xt1"

# ── Region ────────────────────────────────────────────────────────
aws_region = "ap-southeast-1"

# ── Bastion EC2 ──────────────────────────────────────────────────
ssh_private_key_path    = "~/.ssh/id_rsa"
installer_ami           = "ami-04698733964af06d5"
installer_instance_type = "t2.large"
installer_disk_size     = 100
```

### 2. Run the setup

```bash
cd aws/self-managed/disconnected/terraform
./deploy.sh -e "pull_secret=$(cat ~/pull-secret.json)"
```

This runs three steps:

| Step | Tool | What it does |
|------|------|--------------|
| 1 | Terraform | Creates VPCs, transit gateway, VPC endpoints, Route53 zone, IAM role, bastion EC2 |
| 2 | Ansible (`setup-bastion-ec2.yaml`) | Installs packages, sets up mirror registry, mirrors OCP images, extracts tools, creates STS resources, prepares IPI `install-dir` |
| 3 | Ansible (`prepare-upi-install-dir.yaml`) | Creates UPI `install-dir-upi` with ignition configs, stages UPI terraform with pre-filled `terraform.tfvars`, uploads `bootstrap.ign` to S3 |

When complete, the bastion has:
- `openshift-install`, `oc`, `rosa`, `terraform`, `ccoctl`
- Mirror registry on port 8443 with mirrored OCP images
- Squid proxy on port 3128
- IPI `~/install-dir/` with manifests ready for `create cluster`
- UPI `~/install-dir-upi/` with ignition configs
- UPI `~/upi-terraform/` with terraform files and pre-filled `terraform.tfvars`
- STS credentials in `~/sts/`
- ROSA scripts pre-templated

### 3. SSH into the bastion

```bash
BASTION_IP=$(terraform output -raw installer_public_ip)
ssh -i ~/.ssh/id_rsa ec2-user@$BASTION_IP
```

---

## Deploy a Cluster

Choose one of the three methods below.

### Option A: IPI (Installer-Provisioned Infrastructure)

The simplest method. The installer manages all infrastructure (EC2 instances,
load balancers, DNS) automatically.

```bash
ssh ec2-user@$BASTION_IP

# install-dir is already prepared with manifests and STS credentials
openshift-install create cluster \
  --dir ~/install-dir \
  --log-level=debug
```

To destroy:

```bash
openshift-install destroy cluster \
  --dir ~/install-dir \
  --log-level=debug
```

### Option B: UPI (User-Provisioned Infrastructure)

You manage the infrastructure (EC2 nodes, LB, DNS). Use this when you need
full control over node placement, load balancers, or custom networking.

UPI clusters use a separate DNS namespace (`upi.<base_domain>`) so they can
coexist alongside IPI clusters in the same environment. The UPI terraform always
creates a dedicated Route53 private hosted zone for the cluster.

Everything is already prepared on the bastion (created in step 3 of the
environment setup):

- `~/install-dir-upi/` -- Ignition configs (baseDomain = `upi.<base_domain>`)
- `~/upi-terraform/` -- Terraform files with a pre-filled `terraform.tfvars`
- `bootstrap.ign` uploaded to S3

The `terraform.tfvars` has all known values populated automatically
(infrastructure_name, certificate_authority, VPC, subnets, cluster identity).
You only need to fill in the values marked `REPLACE_ME`:

| Variable | What to set |
|----------|-------------|
| `rhcos_ami_id` | RHCOS AMI for your OCP version and region ([lookup](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/installing_on_aws/user-provisioned-infrastructure#installation-aws-user-infra-rhcos-ami_installing-restricted-networks-aws)) |
| `*_private_ip` (10 IPs) | Pre-reserved IPs for bootstrap, masters, workers, infra nodes |

**Load Balancer:**

The UPI terraform can optionally create an internal NLB and Route53 A records,
controlled by the `create_nlb_and_dns` variable in `terraform.tfvars`:

| `create_nlb_and_dns` | Behaviour |
|----------------------|-----------|
| `true` (pre-set when deployed via `deploy.sh`) | Terraform creates an internal NLB with 4 listeners (6443, 22623, 443, 80), target groups attached to the node IPs, and Route53 A records (`api`, `api-int`, `*.apps`) in the hosted zone it creates. |
| `false` (default) | You provide your own load balancer and create A records in the Terraform-created hosted zone **after** running `terraform apply`. See the table below. |

If you bring your own load balancer:

| Listener | Port(s) | Backends | Health check |
|----------|---------|----------|--------------|
| API | 6443 | bootstrap + 3 masters | TCP 6443 |
| Machine Config Server | 22623 | bootstrap + 3 masters | TCP 22623 |
| HTTPS ingress | 443 | infra nodes (or workers) | HTTP 1936 `/healthz` |
| HTTP ingress | 80 | infra nodes (or workers) | HTTP 1936 `/healthz` |

Create A records in the hosted zone output by terraform (`terraform output hosted_zone_id`):

```
api.<cluster>.upi.<domain>       → LB
api-int.<cluster>.upi.<domain>   → LB
*.apps.<cluster>.upi.<domain>    → LB
```

**Step 1 -- Provision cluster nodes:**

```bash
ssh ec2-user@$BASTION_IP

# Edit terraform.tfvars to set rhcos_ami_id and private IPs
vi ~/upi-terraform/terraform.tfvars

# Deploy
cd ~/upi-terraform
terraform init
terraform apply
```

See [`upi/terraform-three-az/README.md`](../../upi/terraform-three-az/README.md)
for the full variable reference.

**Step 2 -- Complete the install:**

```bash
openshift-install wait-for bootstrap-complete \
  --dir ~/install-dir-upi --log-level=debug

# Destroy bootstrap resources (use the command from terraform output)
cd ~/upi-terraform
terraform output bootstrap_terminate_command
# Run the printed command — it includes NLB target group detachments
# when create_nlb_and_dns = true

# Approve CSRs as workers join
export KUBECONFIG=~/install-dir-upi/auth/kubeconfig
for csr in $(oc get csr | grep Pending | awk '{print $1}'); do
  oc adm certificate approve "$csr"
done
sleep 30
for csr in $(oc get csr | grep Pending | awk '{print $1}'); do
  oc adm certificate approve "$csr"
done

openshift-install wait-for install-complete \
  --dir ~/install-dir-upi --log-level=debug
```

### Option C: ROSA (Red Hat OpenShift Service on AWS)

Several ROSA scripts are pre-templated on the bastion:

```bash
ssh ec2-user@$BASTION_IP

rosa login --token=<your-token>

# Classic ROSA
./rosa-create-cluster.sh

# Hosted Control Plane (HCP)
./rosa-create-cluster-hcp.sh

# HCP with zero egress
./rosa-create-cluster-hcp-zero-egress.sh

# HCP with shared VPC
./rosa-create-cluster-hcp-shared-vpc.sh

# HCP with zero egress + proxy
./rosa-create-cluster-hcp-zero-egress-proxy.sh
```

To delete:

```bash
./rosa-delete-cluster.sh          # Classic
./rosa-delete-cluster-hcp.sh      # HCP
./rosa-delete-cluster-hcp-zero-egress.sh  # HCP zero egress
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
| `openshift_cluster_name_suffix` | `xt1` | Suffix for cluster name (`<prefix>-<suffix>`) |

### Network CIDRs

| Variable | Default | Description |
|----------|---------|-------------|
| `disconnected_vpc_cidr` | `172.16.0.0/16` | Disconnected VPC CIDR |
| `disconnected_subnet_cidrs` | `[172.16.1-3.0/24]` | Private subnet CIDRs (one per AZ) |
| `egress_vpc_cidr` | `172.17.0.0/16` | Egress VPC CIDR |
| `egress_public_subnet_cidrs` | `[172.17.1-3.0/24]` | Egress public subnet CIDRs |

### Bastion EC2

| Variable | Default | Description |
|----------|---------|-------------|
| `installer_ami` | `ami-04698733964af06d5` | AMI for the bastion instance |
| `installer_instance_type` | `t2.large` | Bastion instance type |
| `installer_disk_size` | `100` | Root volume size in GB |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key |

---

## Outputs

After `terraform apply`, these outputs are available:

| Output | Description |
|--------|-------------|
| `installer_public_ip` | Bastion public IP for SSH |
| `installer_private_ip` | Bastion private IP |
| `disconnected_vpc_id` | Disconnected VPC ID |
| `disconnected_subnet_ids` | Disconnected subnet IDs (use for UPI/IPI) |
| `egress_vpc_id` | Egress VPC ID |
| `hosted_zone_id` | Route53 private hosted zone ID |
| `transit_gateway_id` | Transit gateway ID |
| `iam_role_arn` | IAM role ARN for the bastion |
| `vpc_owner_aws_account_number` | AWS account number |

These values are also automatically written to `ansible-vars.json` for use
by Ansible playbooks.

---

## Teardown

```bash
# 1. Destroy any cluster first (method-dependent):
#    IPI:  openshift-install destroy cluster --dir ~/install-dir
#    UPI:  terraform destroy  (in ~/upi-terraform)
#    ROSA: ./rosa-delete-cluster-*.sh

# 2. Destroy the environment
cd aws/self-managed/disconnected/terraform
terraform destroy
```
