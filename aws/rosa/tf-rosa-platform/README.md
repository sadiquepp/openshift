# tf-rosa-platform

Terraform root module for deploying a **ROSA HCP (Hosted Control Plane) cluster in a disconnected, shared-VPC architecture** on AWS. It orchestrates four child modules across two AWS accounts in the correct dependency order — replacing an Ansible Automation Platform workflow that previously ran four job templates in sequence.

---

## Overview

This deployment targets a scenario where:

- **Network isolation is required.** The OCP worker nodes run in a private VPC with no direct internet access (the "disconnected VPC"). All outbound traffic is routed through a separate egress VPC via a Transit Gateway.
- **Two AWS accounts are involved.** Network infrastructure lives in a *VPC owner account*. The ROSA cluster, IAM roles, and the installer EC2 run in a separate *ROSA account*. Subnets are shared cross-account via AWS RAM.
- **The bastion EC2 serves two distinct purposes.** First, it is the ROSA installer node — it runs the ROSA CLI, cluster create/delete scripts, and STS credential tooling. ROSA itself does not require a mirror registry; it pulls images via the Squid proxy on the bastion, which provides controlled internet egress. Second, the bastion hosts a Quay mirror registry to support self-managed OpenShift deployments into the disconnected VPC, where nodes have no internet access at all and must pull all images from a local source.
- **ROSA HCP with STS is used.** All operator permissions use short-lived STS credentials via IRSA (IAM Roles for Service Accounts), with OIDC WebIdentity trust policies scoped to specific Kubernetes service accounts.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ VPC Owner Account                                                   │
│                                                                     │
│  ┌──────────────────────────┐   Transit    ┌──────────────────────┐ │
│  │ Egress VPC 172.17.0.0/16 │◄────────────►│ Disconnected VPC     │ │
│  │                          │   Gateway    │ 172.16.0.0/16        │ │
│  │  Public subnets (AZ1-3)  │             │                      │ │
│  │  ┌────────────────────┐  │             │  Private subnets     │ │
│  │  │ Bastion EC2        │  │             │  (AZ1-3) — OCP nodes │ │
│  │  │                    │  │             │                      │ │
│  │  │ ROSA installer:    │  │             │  VPC Endpoints:      │ │
│  │  │ · ROSA CLI         │──┼─── proxy ──►│  S3, EC2, STS, ELB   │ │
│  │  │ · Squid proxy :3128│  │             │  ECR.api, ECR.dkr    │ │
│  │  │ · oc, kubectl      │  │             │                      │ │
│  │  │ · ccoctl, STS      │  │             └──────────────────────┘ │
│  │  │                    │  │                                       │
│  │  │ Self-managed OCP:  │  │                                       │
│  │  │ · Quay mirror :8443│  │                                       │
│  │  │ · oc-mirror        │  │                                       │
│  │  │ · openshift-install│  │                                       │
│  │  └────────────────────┘  │                                       │
│                                                                     │
│  Route53 private zones (associated with both VPCs):                 │
│  · <cluster>.<base_domain>                                          │
│  · rosa.<cluster>.<rosa_domain>                                     │
│  · <cluster>.hypershift.local                                       │
│                                                                     │
│  IAM roles (trusted by specific ROSA account roles):               │
│  · <cluster>-shared-vpc-route53   → ROSASharedVPCRoute53Policy     │
│  · <cluster>-shared-vpc-endpoint  → ROSASharedVPCEndpointPolicy    │
│                                                                     │
│  AWS RAM share → ROSA account:                                      │
│  · 3 × disconnected private subnets                                 │
│  · 1 × egress public subnet                                         │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ ROSA Account                                                        │
│                                                                     │
│  Account roles:                  Operator roles (IRSA / OIDC):     │
│  · HCP-ROSA-Installer-Role       · kube-system-kms-provider        │
│  · HCP-ROSA-Support-Role         · kube-system-kube-controller-mgr │
│  · HCP-ROSA-Worker-Role          · kube-system-capa-controller-mgr │
│                                  · kube-system-control-plane-op    │
│  Shared-VPC assume-role          · openshift-image-registry        │
│  policies (cross-account):       · openshift-ingress-operator      │
│  · shared-vpc-route53-assume     · openshift-cluster-csi-drivers   │
│  · shared-vpc-endpoint-assume    · openshift-cloud-network-config  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Module structure

```
tf-rosa-platform/
├── main.tf                     # Root orchestrator — provider aliases + module calls
├── variables.tf                # All input variables
├── outputs.tf                  # Key outputs surfaced after apply
├── terraform.tfvars.example    # Template — copy to terraform.tfvars
├── Makefile                    # Profile-based step-by-step workflow (Option B)
└── modules/
    ├── tf-disconnected/        # Step 1 — VPC owner account
    ├── tf-rosa-roles/          # Step 2 — ROSA account
    ├── tf-rosa-shared-vpc/     # Step 3 — VPC owner account
    └── tf-installer-ec2/       # Step 4 — ROSA account
```

### Module responsibilities

| Module | Account | What it creates |
|---|---|---|
| `tf-disconnected` | VPC owner | Disconnected VPC + 3 private subnets, Egress VPC + public/private subnets, Internet Gateway, Transit Gateway + attachments + route tables, S3 gateway endpoint, EC2/STS/ELB/ECR interface endpoints, IAM instance role for the installer EC2 |
| `tf-rosa-roles` | ROSA | 3 account roles (Installer, Support, Worker), 8 operator roles with OIDC WebIdentity trust policies scoped to specific service accounts, 2 cross-account assume-role managed policies targeting the VPC owner's shared-VPC roles |
| `tf-rosa-shared-vpc` | VPC owner | 2 shared-VPC IAM roles (Route53, Endpoint) with trust policies pinned to exact ROSA account role ARNs, 3 Route53 private hosted zones associated with both VPCs, AWS RAM resource share granting the ROSA account access to the 4 subnets |
| `tf-installer-ec2` | ROSA | EC2 key pair, security group (ports 22, 5999, 8443, 3128), installer EC2 instance in the egress public subnet with cloud-init bootstrapping (packages, OCP client tools, Quay mirror registry, Squid proxy, ROSA CLI, ROSA Terraform repos) |

---

## Execution order and dependencies

The four modules must be applied in sequence. Terraform enforces this automatically via the dependency graph when using `terraform apply` with `assume_role` (Option A). The explicit dependency chain is:

```
Step 1 (tf-disconnected)
  └─► Step 2 (tf-rosa-roles)         needs: vpc_owner_account_id from step 1
        └─► Step 3 (tf-rosa-shared-vpc)  needs: ROSA role ARNs from step 2
                                          (trust policy principals)
              └─► Step 4 (tf-installer-ec2)  needs: subnet/VPC IDs from step 3
```

This mirrors the original AAP workflow:

| AAP job template | Terraform equivalent |
|---|---|
| Job 1 + credential A | `module.disconnected_vpc` with `provider = aws.vpc_owner` |
| Job 2 + credential B | `module.rosa_roles` with `provider = aws.rosa_account` |
| Job 3 + credential A | `module.share_subnets` with `provider = aws.vpc_owner` |
| Job 4 + credential B | `module.installer_ec2` with `provider = aws.rosa_account` |
| `set_stats` between jobs | Module output → next module input (wired in `main.tf`) |

---

## Prerequisites

1. **Terraform >= 1.5** installed locally or in your CI runner.
2. **AWS CLI** configured with credentials for both accounts.
3. **OIDC config created** in the ROSA account before applying:
   ```bash
   rosa create oidc-config --managed --mode auto
   # Copy the returned ID into var.oidc_config_id
   ```
4. **Red Hat pull secret** downloaded from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret).
5. The `tf-disconnected` IAM instance role (`<prefix>-ocp-install-ec2`) must exist before Step 4 runs — it is created in Step 1.

---

## Usage

### Option A — Cross-account role assumption (recommended for CI/CD)

Each account needs an IAM role that your automation identity can assume. The trust policy on each role should allow your CI runner or local IAM user:

```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::<AUTOMATION_ACCOUNT>:role/CI" },
  "Action": "sts:AssumeRole"
}
```

Then run a single apply — Terraform resolves the order automatically:

```bash
terraform init

terraform apply \
  -var="vpc_owner_role_arn=arn:aws:iam::<VPC_OWNER_ACCOUNT>:role/TerraformAutomation" \
  -var="rosa_account_role_arn=arn:aws:iam::<ROSA_ACCOUNT>:role/TerraformAutomation" \
  -var="oidc_config_id=<your-oidc-id>" \
  -var="rosa_shared_vpc_cluster_domain=rosa.example.com" \
  -var="ssh_public_key=$SSH_PUBLIC_KEY" \
  -var="mirror_registry_password=$MIRROR_PASS" \
  -var="pull_secret=$PULL_SECRET"
```

Sensitive variables are best supplied via environment variables to keep them out of shell history:

```bash
export TF_VAR_ssh_public_key="ssh-rsa AAAA..."
export TF_VAR_mirror_registry_password="..."
export TF_VAR_pull_secret='{"auths":{...}}'
```

### Option B — Named AWS profiles (equivalent to the original AAP workflow)

Configure `~/.aws/credentials` with two named profiles:

```ini
[vpc-owner]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...

[rosa-account]
aws_access_key_id     = AKIA...
aws_secret_access_key = ...
```

In `main.tf`, comment out the `assume_role` dynamic blocks and uncomment the `profile` lines for each provider. Then use the Makefile to run each step individually:

```bash
make init
make step1   # VPC owner account
make step2   # ROSA account
make step3   # VPC owner account
make step4   # ROSA account
```

Or run all four in sequence:

```bash
make all
```

---

## What happens after `terraform apply`

The apply completes when the bastion EC2 is running and cloud-init has finished bootstrapping. The bastion is then ready to serve its two distinct purposes.

### Purpose 1 — ROSA HCP installer

ROSA does not require a mirror registry. It pulls images directly from Red Hat's registries via the Squid proxy running on the bastion, which provides controlled internet egress from the disconnected VPC. Cloud-init sets up the ROSA toolchain:

- Installing system packages (podman, squid, awscli2, ansible-core, terraform, etc.)
- Downloading and extracting OCP client tools (oc, rosa, kubectl, oc-mirror)
- Cloning the ROSA Terraform repos (`terraform-rosa`, `terraform-rhcs-rosa-hcp`)
- Starting and enabling Squid proxy

The following steps must then be completed by running the Ansible playbook:

```bash
# The exact command is printed as a Terraform output:
terraform output ansible_run_command

# Which will be something like:
ansible-playbook setup-bastion-ec2.yaml -i '<bastion_ip>,' -u ec2-user
```

The Ansible playbook completes the ROSA setup:
- Rendering and copying the Squid config and allow list
- Rendering ROSA cluster create/delete scripts
- Running `ccoctl aws create-all` to generate STS manifests
- Rendering `install-config.yaml` and generating manifests for self-managed installs

### Purpose 2 — Self-managed OpenShift installer (disconnected)

For self-managed OpenShift deployments into the disconnected VPC, nodes have no internet access and must pull all images from a local registry. Cloud-init also sets up the mirror registry toolchain:

- Installing the Quay mirror registry at `$HOSTNAME:8443` and trusting its root CA
- Placing the Red Hat pull secret and logging into the local registry

The Ansible playbook then completes the mirror registry setup:
- Running `oc mirror` to sync OCP release images into the local Quay registry (30–60 minutes)
- Extracting the `openshift-install` binary from the mirror registry
- Patching the DNS manifest (`cluster-dns-02-config.yml`) for disconnected operation
- Copying STS credentials and TLS files into the install directory

---

## Outputs

| Output | Description |
|---|---|
| `bastion_public_ip` | Public IP of the installer EC2 — SSH target for Ansible |
| `ansible_run_command` | Ready-to-run Ansible command with the bastion IP already filled in |
| `disconnected_subnet_ids` | Map of AZ1/2/3 → subnet ID for the disconnected private subnets |
| `hosted_zone_ids` | Map of the three Route53 private hosted zone IDs |
| `installer_role_arn` | ARN of the ROSA HCP Installer account role |
| `worker_role_arn` | ARN of the ROSA HCP Worker account role |
| `operator_role_arns` | Map of all 8 operator role keys → ARNs |

---

## Inputs

| Variable | Default | Description |
|---|---|---|
| `vpc_owner_role_arn` | `""` | IAM role ARN to assume in the VPC owner account. Empty = use default credential chain |
| `rosa_account_role_arn` | `""` | IAM role ARN to assume in the ROSA account. Empty = use default credential chain |
| `prefix_for_name` | `project_name` | Prefix applied to all resource names across both accounts |
| `aws_region` | `ap-southeast-1` | AWS region for all resources |
| `openshift_cluster_name_suffix` | `xt1` | Appended to `prefix_for_name` to form `<prefix>-<suffix>` cluster name |
| `openshift_base_domain` | `example.com` | Base DNS domain for the cluster |
| `openshift_major_version` | `4.20` | OCP major.minor version (e.g. `4.20`) |
| `openshift_minor_version` | `0` | OCP patch version |
| `rosa_shared_vpc_cluster_domain` | *(required)* | Domain for the ROSA shared-VPC hosted zone |
| `oidc_config_id` | *(required)* | OIDC config ID from `rosa create oidc-config` |
| `aws_disconnected_vpc_cidr` | `172.16.0.0/16` | CIDR for the disconnected VPC |
| `aws_egress_vpc_cidr` | `172.17.0.0/16` | CIDR for the egress VPC |
| `aws_ami` | `ami-04698733964af06d5` | AMI for the installer EC2 (RHEL in ap-southeast-1) |
| `aws_instance_type` | `t2.large` | EC2 instance type for the bastion |
| `ec2_disk_size` | `100` | Root EBS volume size in GB |
| `ssh_public_key` | *(required, sensitive)* | SSH public key imported as EC2 key pair |
| `mirror_registry_password` | *(required, sensitive)* | Initial password for the Quay mirror registry |
| `pull_secret` | *(required, sensitive)* | Red Hat pull secret JSON |

---

## Teardown

```bash
# Option A
terraform destroy \
  -var="vpc_owner_role_arn=..." \
  -var="rosa_account_role_arn=..."

# Option B (profile-based) — destroys in reverse dependency order
make destroy
```

> **Note:** Destroy the ROSA cluster itself with `rosa delete cluster` before running `terraform destroy`, otherwise the Route53 hosted zones and RAM shares will fail to delete due to active associations.
