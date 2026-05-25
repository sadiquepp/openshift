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
│   ├── hcp-roles.tf                 # HCP: OIDC bucket, CloudFront, IAM roles, Route53 zones
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

### HCP Clusters

| Variable | Default | Description |
|----------|---------|-------------|
| `hcp_cluster_suffixes` | `[]` | List of HCP cluster suffixes (e.g. `["hcp1", "hcp2"]`). Empty disables HCP. |

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
| `hcp_public_zone_id` | Public Route53 zone ID (when HCP enabled) |
| `hcp_private_zone_ids` | Per-cluster private Route53 zone IDs |
| `hcp_operator_role_arns` | Per-cluster map of 7 operator role ARNs |

These values are also automatically written to `ansible-vars.json` for use
by the Ansible playbook.

---

## HCP Clusters (Hosted Control Planes)

This environment supports deploying one or more self-managed HCP clusters on
the same VPC used by the management IPI cluster. Terraform creates all the
required AWS resources (OIDC, IAM, DNS, worker profiles), and Ansible renders
per-cluster HostedCluster + NodePool manifests on the bastion.

### How It Works

When `hcp_cluster_suffixes` is set (e.g. `["hcp1", "hcp2"]`), Terraform
creates the following resources **per cluster suffix**:

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

The existing **public Route53 zone** for `openshift_base_domain` is looked up
(not created) and its zone ID is passed as `publicZoneID`.

### Architecture

```
                              CloudFront (HTTPS)
                                    │
                          ┌─────────▼─────────┐
                          │   S3 Bucket        │
                          │   (private, OAC)   │
                          │                    │
                          │  /<prefix>-hcp1/   │
                          │    .well-known/    │
                          │    openid/v1/jwks  │
                          │  /<prefix>-hcp2/   │
                          │    ...             │
                          └────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
             OIDC Provider    OIDC Provider    OIDC Provider
               (hcp1)           (hcp2)           (hcp3)
                    │               │               │
              7 IAM Roles     7 IAM Roles     7 IAM Roles
            + Worker Role   + Worker Role   + Worker Role
            + Route53 Zones + Route53 Zones + Route53 Zones
```

### Enable HCP

Add the cluster suffixes to `terraform.tfvars`:

```hcl
hcp_cluster_suffixes = ["hcp1"]
```

Then run `terraform apply` and `deploy.sh` as usual. Ansible will render a
`hosted-cluster-<suffix>.yaml` manifest for each suffix on the bastion.

### Adding More HCP Clusters Later

To add a new cluster (e.g. `hcp3`), simply append to the list and re-apply:

```hcl
hcp_cluster_suffixes = ["hcp1", "hcp2", "hcp3"]
```

```bash
cd terraform
terraform apply
```

Terraform will create only the new resources for `hcp3` without affecting
existing clusters. Re-run Ansible to render the new manifest on the bastion.

### Deploy an HCP Cluster

After the environment is set up, SSH into the bastion and apply the operator
secrets first, then the cluster manifest.

```bash
ssh ec2-user@$BASTION_IP

export KUBECONFIG=~/install-dir-public/auth/kubeconfig

# 1. Create the OIDC S3 credentials secret (required for all HCP clusters)
oc apply -f ~/hypershift-oidc-s3-secret.yaml

# 2. Create the PrivateLink credentials secret (required for private HCP clusters)
oc apply -f ~/hypershift-privatelink-secret.yaml

# 3a. Deploy a public HCP cluster
oc apply -f ~/hosted-cluster-hcp1.yaml

# 3b. Or deploy a private (PrivateLink) HCP cluster instead
oc apply -f ~/hosted-cluster-hcp1-pl.yaml

# Watch the cluster come up
oc get hostedcluster -n <prefix>-hcp1 -w
```

> **Note:** The OIDC S3 and PrivateLink secrets are created once in the
> `local-cluster` namespace. They are shared by all HCP clusters and do not
> need to be re-applied when adding more clusters.

### Destroy an HCP Cluster

```bash
# Delete the HostedCluster (this tears down the control plane + worker nodes)
oc delete hostedcluster <prefix>-hcp1 -n <prefix>-hcp1

# Delete the namespace
oc delete namespace <prefix>-hcp1
```

To remove the IAM roles, Route53 zones, and OIDC resources, remove the suffix
from `hcp_cluster_suffixes` in `terraform.tfvars` and run `terraform apply`.

### Per-Cluster Resources Created by Terraform

For each suffix (e.g. `hcp1` with prefix `ar1`):

| Resource | Name |
|----------|------|
| OIDC S3 path | `ar1-hcp1/.well-known/openid-configuration`, `ar1-hcp1/openid/v1/jwks` |
| OIDC issuer URL | `https://<cloudfront-domain>/ar1-hcp1` |
| Private Route53 zone | `ar1-hcp1.example.com` |
| Hypershift.local zone | `ar1-hcp1.hypershift.local` |
| IAM roles | `ar1-hcp1-control-plane-operator`, `ar1-hcp1-openshift-ingress`, etc. |
| Worker role + instance profile | `ar1-hcp1-ROSA-Worker-Role` |

### Rendered Manifests

Ansible renders the following files on the bastion:

| File | Description |
|------|-------------|
| `~/hypershift-oidc-s3-secret.yaml` | OIDC S3 bucket credentials secret (shared, apply once) |
| `~/hypershift-privatelink-secret.yaml` | PrivateLink IAM user credentials secret (shared, apply once) |
| `~/hosted-cluster-<suffix>.yaml` | HostedCluster + NodePools with `endpointAccess: Public` |
| `~/hosted-cluster-<suffix>-pl.yaml` | HostedCluster + NodePools with `endpointAccess: Private` (PrivateLink) |

Each cluster manifest contains:

- **Namespace** (`<prefix>-<suffix>`)
- **Secrets**: pull secret, SSH public key, etcd encryption key, SA signing key
- **HostedCluster**: with `issuerURL`, `rolesRef`, `privateZoneID`, `publicZoneID`,
  `serviceAccountSigningKey`, and `secretEncryption` all pre-populated
- **NodePools**: one per AZ (3 total), referencing the worker instance profile

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

- The cluster's **private** hosted zone (`<prefix>-<suffix>.<base_domain>`)
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
