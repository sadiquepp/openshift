# Connected OpenShift Environment on AWS

Set up a connected (internet-accessible) environment on AWS for deploying
OpenShift clusters. This creates the network infrastructure, an IAM role,
and a bastion EC2 instance pre-configured with the tools and STS credentials
needed to run `openshift-install`.

This environment also supports deploying **self-managed HCP (Hosted Control
Planes)** clusters on the same VPC. See [HCP Clusters](#hcp-clusters-hosted-control-planes)
for details.

## Architecture

```
                   ┌──────────────────────────────────────────────────┐
                   │        Connected VPC (172.16.0.0/16)             │
                   │                                                  │
                   │  ┌──────────────────────────────────────────┐    │
  Internet ◄─ IGW ◄┤  │  Public Subnets (AZ1, AZ2, AZ3)          │    │
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
                   │  │  Private Subnets (AZ1, AZ2, AZ3)         │    │
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
│   ├── main.tf                      # Provider configuration (default + aws.hcp alias)
│   ├── variables.tf                 # All input variables
│   ├── vpc.tf                       # VPC, subnets, IGW, NAT GW, route tables, S3 endpoint
│   ├── iam.tf                       # IAM role + instance profile for bastion EC2
│   ├── ec2.tf                       # SSH key pair, security group, bastion EC2 instance
│   ├── hcp-roles.tf                 # HCP: OIDC bucket, CloudFront, IAM roles, Route53 zones, DNS delegation
│   ├── hcp-vpc.tf                   # HCP: optional separate VPC (same-account or cross-account)
│   ├── ansible.tf                   # Generated Ansible inventory + vars
│   ├── outputs.tf                   # All outputs (VPC IDs, IPs, hosted zone, etc.)
│   └── scripts/
│       └── pem-to-jwk.py           # Converts RSA PEM to JWK (used by hcp-roles.tf)
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

### OpenShift Compute

| Variable | Default | Description |
|----------|---------|-------------|
| `compute_instance_type` | `m5.xlarge` | Instance type for OCP compute nodes |
| `compute_replicas` | `3` | Number of compute replicas |
| `control_plane_replicas` | `3` | Number of control plane replicas |

### Bastion EC2

| Variable | Default | Description |
|----------|---------|-------------|
| `installer_ami` | `ami-04698733964af06d5` | AMI for the bastion instance |
| `installer_instance_type` | `t2.medium` | Bastion instance type |
| `installer_disk_size` | `50` | Root volume size in GB |
| `ssh_private_key_path` | `~/.ssh/id_rsa` | Path to SSH private key |

### HCP Clusters (Same Account)

| Variable | Default | Description |
|----------|---------|-------------|
| `hcp_cluster_suffixes` | `[]` | List of HCP cluster suffixes for same-account deployment (e.g. `["hcp1", "hcp2"]`). |
| `hcp_separate_vpc` | `false` | When true, create a separate VPC for same-account HCP workers. |
| `hcp_vpc_cidr` | `172.17.0.0/16` | CIDR for the same-account HCP VPC. |
| `hcp_private_subnet_cidrs` | `[172.17.1-3.0/24]` | Private subnet CIDRs for same-account HCP VPC. |
| `hcp_public_subnet_cidrs` | `[172.17.4-6.0/24]` | Public subnet CIDRs for same-account HCP VPC. |

### HCP Clusters (Cross Account)

| Variable | Default | Description |
|----------|---------|-------------|
| `hcp_xacct_cluster_suffixes` | `[]` | List of HCP cluster suffixes for cross-account deployment. Must not overlap with `hcp_cluster_suffixes`. |
| `hcp_account_role_arn` | `""` | ARN of TerraformHCPRole in HCP account. Required when `hcp_xacct_cluster_suffixes` is non-empty. |
| `hcp_xacct_vpc_cidr` | `172.18.0.0/16` | CIDR for the cross-account HCP VPC. |
| `hcp_xacct_private_subnet_cidrs` | `[172.18.1-3.0/24]` | Private subnet CIDRs for cross-account HCP VPC. |
| `hcp_xacct_public_subnet_cidrs` | `[172.18.4-6.0/24]` | Public subnet CIDRs for cross-account HCP VPC. |

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
| `hcp_oidc_bucket_name` | OIDC S3 bucket name (when HCP enabled) |
| `hcp_cloudfront_domain` | CloudFront domain for OIDC endpoint (when HCP enabled) |
| `hcp_public_zone_ids` | Per-cluster public Route53 zone IDs |
| `hcp_account_numbers` | Per-cluster AWS account IDs where HCP resources live |
| `hcp_base_domains` | Per-cluster base domains (delegated subdomains for cross-account) |
| `hcp_private_zone_ids` | Per-cluster private Route53 zone IDs |
| `hcp_operator_role_arns` | Per-cluster map of 7 operator role ARNs (same-account) |
| `hcp_xacct_operator_role_arns` | Per-cluster map of 7 operator role ARNs (cross-account) |

These values are also automatically written to `ansible-vars.json` for use
by the Ansible playbook.

---

## HCP Clusters (Hosted Control Planes)

This environment supports deploying one or more self-managed HCP clusters.
HCP worker nodes can be placed in:

- The **main connected VPC** (same VPC as the management cluster), or
- A **separate HCP VPC** in the same account (`hcp_separate_vpc = true`), or
- A **separate HCP VPC in a different AWS account** (`hcp_xacct_cluster_suffixes`)

**All three modes coexist.** Use two separate suffix lists to assign clusters
to different deployment targets:

- `hcp_cluster_suffixes` → IAM roles, OIDC, and zones created in the **management account**
- `hcp_xacct_cluster_suffixes` → IAM roles, OIDC, and zones created in the **HCP account**

Suffixes must not overlap. S3, CloudFront, and SA keys are shared in the
management account (CloudFront is globally accessible). Terraform creates
all the required AWS resources, and Ansible renders per-cluster HostedCluster
+ NodePool manifests on the bastion. The management cluster (HyperShift
control plane) always runs in the connected VPC regardless of where workers
are placed. Communication between control plane and workers uses the
Konnectivity tunnel.

### How It Works

When `hcp_cluster_suffixes` or `hcp_xacct_cluster_suffixes` is set,
Terraform creates the following resources **per cluster suffix**:

| Resource | Purpose |
|----------|---------|
| OIDC S3 bucket (shared) | Stores OIDC discovery docs for all HCP clusters |
| CloudFront distribution + OAC | Serves OIDC documents over HTTPS (bucket is private) |
| OIDC provider | IAM OIDC provider pointing to the CloudFront issuer URL |
| 7 operator IAM roles | ROSA managed policy roles for HostedCluster `rolesRef` |
| Worker IAM role + instance profile | EC2 trust role with `ROSAWorkerInstancePolicy` |
| Private Route53 zone | `<prefix>-<suffix>.<base_domain>` (fed as `privateZoneID`) |
| Hypershift.local Route53 zone | `<prefix>-<suffix>.hypershift.local` (internal use) |
| Ingress Route53 policy | Allows ingress operator to manage records in private + public zones |
| RSA key pair (4096-bit) | Per-cluster service account signing key |
| OIDC discovery + JWKS | `.well-known/openid-configuration` and `openid/v1/jwks` in S3 |

For **same-account** deployments, the existing public Route53 zone for
`openshift_base_domain` is looked up and its zone ID is shared as
`publicZoneID`. For **cross-account** deployments, a delegated public
subdomain zone (`<suffix>.<base_domain>`) is created per cluster in the HCP
account, with NS delegation records in the management account.

### Architecture

```
                              CloudFront (HTTPS)
                                    │
                          ┌─────────▼─────────┐
                          │   S3 Bucket        │
                          │   (private, OAC)   │
                          │  /<prefix>-hcp1/   │
                          │    .well-known/    │
                          │    openid/v1/jwks  │
                          └────────────────────┘
                                    │
                             OIDC Provider(s)
                              + 7 IAM Roles
                              + Worker Role
                                    │
        ┌───────────────────────────┴───────────────────────────┐
        │                                                       │
  Connected VPC (172.16.0.0/16)              HCP VPC (same-acct / cross-acct)
  ┌─────────────────────────────┐         ┌─────────────────────────────┐
  │ Management cluster          │         │ (same or different account) │
  │  + HyperShift control plane │         │                             │
  │                             │         │  Private subnets (AZ1-3)    │
  │  Private subnets (AZ1-3)    │  Konnek │  Public subnets  (AZ1-3)    │
  │  Public subnets  (AZ1-3)    │◄───────►│  IGW + NAT + S3 endpoint    │
  │                             │  tivity │                             │
  │  HCP workers (default)      │         │  HCP workers (separate)     │
  └─────────────────────────────┘         └─────────────────────────────┘
  Management Account                      HCP Account (cross-account)
```

> For same-account separate VPC, Route53 private zones are associated with
> both VPCs. For cross-account, the Konnectivity tunnel handles all
> control-plane-to-worker communication; no Route53 zone associations are
> needed across accounts.

### Enable HCP

Add the cluster suffixes to `terraform.tfvars`:

```hcl
hcp_cluster_suffixes = ["hcp1"]
```

To deploy HCP workers into a **separate VPC** (same account), also set:

```hcl
hcp_separate_vpc = true

# Optional: customise CIDRs (defaults shown)
# hcp_vpc_cidr             = "172.17.0.0/16"
# hcp_private_subnet_cidrs = ["172.17.1.0/24", "172.17.2.0/24", "172.17.3.0/24"]
# hcp_public_subnet_cidrs  = ["172.17.4.0/24", "172.17.5.0/24", "172.17.6.0/24"]
```

Then run `terraform apply` and `deploy.sh` as usual. Ansible will render
manifests for each suffix on the bastion.

### Cross-Account HCP Deployment

To deploy HCP clusters into a **different AWS account**, list the suffixes
in `hcp_xacct_cluster_suffixes` (not `hcp_cluster_suffixes`). The VPC,
IAM roles, OIDC, Route53 zones, and DNS delegation are created in the HCP
account via `sts:AssumeRole`. Same-account and cross-account suffixes
coexist in a single `terraform apply`.

#### Prerequisites

**1. Create `TerraformHCPRole` in the HCP account** with a trust policy
allowing the management account's bastion instance role to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::<MANAGEMENT_ACCOUNT_ID>:role/<BASTION_INSTANCE_ROLE>"
    },
    "Action": "sts:AssumeRole"
  }]
}
```

Attach permissions for VPC, IAM, Route53, S3, CloudFront, and EC2 to this
role (or `AdministratorAccess` for testing).

```bash
# In the HCP account:
aws iam create-role \
  --role-name TerraformHCPRole \
  --assume-role-policy-document file://trust-policy.json

aws iam attach-role-policy \
  --role-name TerraformHCPRole \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

**2. Add `sts:AssumeRole` permission** to the bastion's instance role in the
management account:

```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::<HCP_ACCOUNT_ID>:role/TerraformHCPRole"
}
```

#### Configuration

```hcl
# Same-account clusters (connected VPC or separate VPC)
hcp_cluster_suffixes = ["hcp1", "hcp2"]

# Cross-account clusters (VPC created automatically in HCP account)
hcp_xacct_cluster_suffixes = ["hcp3"]
hcp_account_role_arn       = "arn:aws:iam::123456789012:role/TerraformHCPRole"

# Optional: customise cross-account VPC CIDRs
# hcp_xacct_vpc_cidr             = "172.18.0.0/16"
# hcp_xacct_private_subnet_cidrs = ["172.18.1.0/24", "172.18.2.0/24", "172.18.3.0/24"]
# hcp_xacct_public_subnet_cidrs  = ["172.18.4.0/24", "172.18.5.0/24", "172.18.6.0/24"]
```

#### How DNS Delegation Works

For each cross-account cluster suffix, Terraform:

1. Creates a **public hosted zone** `<suffix>.<base_domain>` in the HCP
   account (e.g. `hcp3.aws.example.com`)
2. Creates **NS records** in the management account's parent zone
   (`aws.example.com`) pointing to the delegated zone's name servers
3. Sets `baseDomain` in the HostedCluster manifests to the delegated subdomain

This allows the HCP account's ingress operator to freely manage DNS records
within the delegated zone without cross-account Route53 permissions.

```
Management Account                    HCP Account
┌──────────────────────┐     NS      ┌────────────────────────────┐
│ aws.example.com      │─delegation─►│ hcp3.aws.example.com       │
│ (public zone)        │             │ (public zone)              │
│                      │             │                            │
│ hcp3.aws.example.com │             │ *.apps.ar1-hcp3.hcp3....   │
│   NS → HCP account   │             │ api.ar1-hcp3.hcp3....      │
└──────────────────────┘             └────────────────────────────┘
```

#### Deployment

Cross-account clusters use the `-vpc` manifests:

```bash
oc apply -f ~/hosted-cluster-hcp3-vpc.yaml       # Public
oc apply -f ~/hosted-cluster-hcp3-vpc-pvt.yaml   # Private
oc apply -f ~/hosted-cluster-hcp3-vpc-pvtpl.yaml # PublicAndPrivate
```

### Coexistence Example

All three deployment modes can be active simultaneously:

```hcl
# hcp1, hcp2 → same account, connected or separate VPC
hcp_cluster_suffixes = ["hcp1", "hcp2"]
hcp_separate_vpc     = true

# hcp3 → different account
hcp_xacct_cluster_suffixes = ["hcp3"]
hcp_account_role_arn       = "arn:aws:iam::123456789012:role/TerraformHCPRole"
```

This produces manifests for:
- `hcp1`/`hcp2`: connected VPC manifests + same-account `-vpc` manifests (roles in management account)
- `hcp3`: `-vpc` manifests only (roles in HCP account, VPC in HCP account)

### Adding More HCP Clusters Later

To add a new cluster, append to the appropriate list and re-apply:

```hcl
# Same account
hcp_cluster_suffixes = ["hcp1", "hcp2", "hcp3"]

# Cross account
hcp_xacct_cluster_suffixes = ["hcp4", "hcp5"]
```

```bash
cd terraform
terraform apply
```

Terraform will create only the new resources without affecting existing
clusters. Re-run Ansible to render the new manifests on the bastion.

### Deploy an HCP Cluster

After the environment is set up, SSH into the bastion and apply the operator
secrets first, then the cluster manifest.

```bash
ssh ec2-user@$BASTION_IP

export KUBECONFIG=~/install-dir-public/auth/kubeconfig

# 1. Create the OIDC S3 credentials secret (required for all HCP clusters)
oc apply -f ~/hypershift-oidc-s3-secret.yaml

# 2. Create the PrivateLink credentials secret (required for pvt and pvtpl HCP clusters)
oc apply -f ~/hypershift-privatelink-secret.yaml

# 3. Deploy an HCP cluster (pick ONE manifest per cluster suffix):
#
#    ── Connected VPC (172.16.0.0/16) ──────────────────────────────
oc apply -f ~/hosted-cluster-hcp1.yaml           # Public
oc apply -f ~/hosted-cluster-hcp1-pvt.yaml       # Private
oc apply -f ~/hosted-cluster-hcp1-pvtpl.yaml     # PublicAndPrivate
#
#    ── Separate HCP VPC (172.17.0.0/16, requires hcp_separate_vpc = true) ──
oc apply -f ~/hosted-cluster-hcp1-vpc.yaml       # Public
oc apply -f ~/hosted-cluster-hcp1-vpc-pvt.yaml   # Private
oc apply -f ~/hosted-cluster-hcp1-vpc-pvtpl.yaml # PublicAndPrivate

# Watch the cluster come up (namespace matches the variant deployed)
oc get hostedcluster -n <prefix>-hcp1 -w       # public
oc get hostedcluster -n <prefix>-hcp1-pvt -w    # private
oc get hostedcluster -n <prefix>-hcp1-pvtpl -w  # public+private
```

> **Note:** The OIDC S3 and PrivateLink secrets are created once in the
> `local-cluster` namespace. They are shared by all HCP clusters and do not
> need to be re-applied when adding more clusters.
>
> All three variants can coexist simultaneously -- each has its own namespace,
> infraID, and Route53 zones while reusing the same IAM roles, OIDC provider,
> SA signing key, and worker instance profile.

### Destroy an HCP Cluster

```bash
# Delete the HostedCluster (this tears down the control plane + worker nodes)
# Use the namespace matching the variant you deployed:
oc delete hostedcluster <prefix>-hcp1 -n <prefix>-hcp1             # public
oc delete hostedcluster <prefix>-hcp1-pvt -n <prefix>-hcp1-pvt     # private
oc delete hostedcluster <prefix>-hcp1-pvtpl -n <prefix>-hcp1-pvtpl # public+private

# Delete the namespace
oc delete namespace <prefix>-hcp1         # public
oc delete namespace <prefix>-hcp1-pvt     # private
oc delete namespace <prefix>-hcp1-pvtpl   # public+private
```

To remove the IAM roles, Route53 zones, and OIDC resources, remove the suffix
from `hcp_cluster_suffixes` or `hcp_xacct_cluster_suffixes` in
`terraform.tfvars` and run `terraform apply`.

### Per-Cluster Resources Created by Terraform

For each suffix (e.g. `hcp1` with prefix `ar1`):

| Resource | Name |
|----------|------|
| OIDC S3 path | `ar1-hcp1/.well-known/openid-configuration`, `ar1-hcp1/openid/v1/jwks` |
| OIDC issuer URL | `https://<cloudfront-domain>/ar1-hcp1` |
| Private Route53 zone (public) | `ar1-hcp1.example.com` |
| Private Route53 zone (pvt) | `ar1-hcp1-pvt.example.com` |
| Private Route53 zone (pvtpl) | `ar1-hcp1-pvtpl.example.com` |
| Hypershift.local zones | `ar1-hcp1.hypershift.local`, `ar1-hcp1-pvt.hypershift.local`, `ar1-hcp1-pvtpl.hypershift.local` |
| IAM roles (shared) | `ar1-hcp1-control-plane-operator`, `ar1-hcp1-openshift-ingress`, etc. |
| Worker role + instance profile (shared) | `ar1-hcp1-ROSA-Worker-Role` |
| PrivateLink IAM user (shared) | `hypershift-operator-pl` |

### Rendered Manifests

Ansible renders the following files on the bastion:

| File | VPC | endpointAccess |
|------|-----|----------------|
| `~/hypershift-oidc-s3-secret.yaml` | -- | OIDC S3 bucket credentials (shared, apply once) |
| `~/hypershift-privatelink-secret.yaml` | -- | PrivateLink IAM credentials (shared, apply once) |
| `~/hosted-cluster-<suffix>.yaml` | Connected | Public |
| `~/hosted-cluster-<suffix>-pvt.yaml` | Connected | Private |
| `~/hosted-cluster-<suffix>-pvtpl.yaml` | Connected | PublicAndPrivate |
| `~/hosted-cluster-<suffix>-vpc.yaml` | HCP VPC | Public |
| `~/hosted-cluster-<suffix>-vpc-pvt.yaml` | HCP VPC | Private |
| `~/hosted-cluster-<suffix>-vpc-pvtpl.yaml` | HCP VPC | PublicAndPrivate |

> The `-vpc` manifests are rendered for suffixes in `hcp_vpc_suffixes` --
> which combines `hcp_cluster_suffixes` (when `hcp_separate_vpc = true`)
> and all `hcp_xacct_cluster_suffixes` (always, since cross-account clusters
> always deploy into a separate VPC in the HCP account).

Each cluster manifest contains:

- **Namespace** (`<prefix>-<suffix>` for public, `<prefix>-<suffix>-pvt` for private, `<prefix>-<suffix>-pvtpl` for public+private)
- **Secrets**: pull secret, SSH public key, etcd encryption key, SA signing key
- **HostedCluster**: with `issuerURL`, `rolesRef`, `privateZoneID`, `publicZoneID`,
  `serviceAccountSigningKey`, and `secretEncryption` all pre-populated
- **NodePools**: one per AZ (3 total), referencing the shared worker instance profile

The `-pvt` and `-pvtpl` variants reuse the same IAM roles, OIDC provider,
SA signing key, and worker instance profile as the base public variant.

### ROSA Managed Policy Compatibility

The self-managed HCP setup uses AWS ROSA managed policies
(`arn:aws:iam::aws:policy/service-role/ROSA*`) instead of custom inline
policies. These managed policies contain specific conditions that require
matching resource names, tags, and supplementary policies. Below are the
adaptations made to satisfy them.

#### 1. Ingress Operator -- additional inline Route53 policy

`ROSAIngressOperatorPolicy` only grants `route53:ChangeResourceRecordSets`
for `*.openshiftapps.com` hosted zones. Since self-managed clusters use
custom domains, Terraform attaches an additional inline policy
(`self-managed-ingress-route53`) to the ingress operator role granting
`route53:ChangeResourceRecordSets` on:

- The cluster's **private** hosted zones (`<prefix>-<suffix>.<base_domain>`,
  `<prefix>-<suffix>-pvt.<base_domain>`, `<prefix>-<suffix>-pvtpl.<base_domain>`)
- The **public** hosted zone for `<base_domain>`

The `hypershift.local` zone is intentionally excluded -- it is already
covered by `ROSAControlPlaneOperatorPolicy`.

#### 2. Worker role naming -- `*-ROSA-Worker-Role` suffix

`ROSANodePoolManagementPolicy` contains a `PassWorkerRole` statement that
restricts `iam:PassRole` to roles matching `arn:*:iam::*:role/*-ROSA-Worker-Role`.
The worker IAM role and instance profile are therefore named
`<prefix>-<suffix>-ROSA-Worker-Role` (not `*-worker`). The NodePool
`instanceProfile` field in the manifest references this name.

#### 3. `red-hat-managed` resource tag

Several ROSA managed policies scope EC2, ELB, and other actions with
`aws:ResourceTag/red-hat-managed: "true"` conditions. To satisfy these:

- The **HostedCluster** `spec.platform.aws.resourceTags` includes
  `red-hat-managed: "true"` -- this causes the control plane operator to
  tag all AWS resources it creates.
- Each **NodePool** `spec.platform.aws.resourceTags` includes the same tag
  so that worker EC2 instances and volumes are tagged at launch.
- All Terraform-managed IAM roles, S3 buckets, CloudFront distributions,
  and Route53 zones also carry this tag.

> **Note:** The HyperShift API expects `resourceTags` as a **list** of
> `{key, value}` objects, not a map:
>
> ```yaml
> resourceTags:
> - key: red-hat-managed
>   value: "true"
> ```

#### 4. OIDC issuer served via CloudFront (not public S3)

The OIDC discovery documents (`.well-known/openid-configuration` and
`openid/v1/jwks`) are stored in a **private** S3 bucket and served over
HTTPS through a CloudFront distribution with Origin Access Control (OAC).
The IAM OIDC provider and operator role trust policies reference the
CloudFront domain as the issuer, not the S3 URL directly.

#### 5. Per-cluster service account signing key

Each HCP cluster gets its own RSA 4096-bit key pair generated by Terraform
(`tls_private_key`). The public key is converted to JWK format and uploaded
to the OIDC JWKS endpoint in S3. The private key is injected into a
Kubernetes Secret and referenced by the HostedCluster's
`spec.serviceAccountSigningKey`.

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
