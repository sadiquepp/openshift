# Disconnected OpenShift Environment on GCP

> **Also available for:**
> - **AWS:** See [`aws/self-managed/disconnected/`](../../../../aws/self-managed/disconnected/terraform/README.md)
> - **Azure:** See [`azure/self-managed/disconnected/`](../../../../azure/self-managed/disconnected/terraform/README.md)

Set up a disconnected (air-gapped) environment on Google Cloud for deploying
OpenShift clusters. This creates the network infrastructure, a bastion host
with a mirror registry and mirrored OCP images, and leaves you ready to
deploy a cluster using **IPI** (Installer-Provisioned Infrastructure).

## Architecture

```
                        ┌──────────────────────────────────────────┐
                        │       Egress VPC (172.17.0.0/16)         │
                        │                                          │
                        │   ┌──────────────┐    ┌───────────┐      │
  Internet ◄── NAT ◄──  ┤   │ Bastion VM   │    │ Egress    │      │
                        │   │  - mirror    │    │ Subnet    │      │
                        │   │  - squid     │    │           │      │
                        │   │  - terraform │    │           │      │
                        │   └──────────────┘    └───────────┘      │
                        │                                          │
                        │   ┌──────────────────────────────────┐   │
                        │   │ Cloud Router + Cloud NAT         │   │
                        │   │  (bastion outbound internet)     │   │
                        │   └──────────────────────────────────┘   │
                        └────────────┬─────────────────────────────┘
                                     │
                            VPC Peering (Disconnected → Egress)
                                     │
                        ┌────────────┴─────────────────────────────┐
                        │   Disconnected VPC (172.16.0.0/16)       │
                        │                                          │
                        │  ┌───────────────┐  ┌───────────────┐    │
                        │  │ Control Plane │  │ Compute       │    │
                        │  │ Subnet        │  │ Subnet        │    │
                        │  │ (172.16.1.0)  │  │ (172.16.2.0)  │    │
                        │  └───────────────┘  └───────────────┘    │
                        │                                          │
                        │  ┌───────────────────────────────────┐   │
                        │  │ PSC Endpoint (all-apis)           │   │
                        │  │  172.16.100.2 → all Google APIs   │   │
                        │  └───────────────────────────────────┘   │
                        │                                          │
                        │  Cloud DNS Private Zones:                │
                        │    *.googleapis.com  → PSC IP            │
                        │    *.gcr.io          → PSC IP            │
                        │    *.pkg.dev         → PSC IP            │
                        │    accounts.google.com → PSC IP          │
                        │    bastion.mirror.internal → bastion IP  │
                        └──────────────────────────────────────────┘
```

### Egress Traffic Flow

OpenShift nodes in the disconnected VPC have **no proxy configuration**.
All Google API access is handled transparently via Private Service Connect:

| Destination               | Path           | Notes                                    |
| ------------------------- | -------------- | ---------------------------------------- |
| `*.googleapis.com`        | PSC endpoint   | Compute, Storage, IAM, DNS, all APIs     |
| `*.gcr.io`               | PSC endpoint   | Container Registry                       |
| `*.pkg.dev`              | PSC endpoint   | Artifact Registry                        |
| `accounts.google.com`    | PSC endpoint   | OAuth / identity                         |
| Mirror registry (bastion) | VPC peering    | Port 8444, via `mirror.internal` DNS     |
| Everything else           | Blocked        | Denied by firewall rules                 |

> **Cost note:** Private Service Connect has **no ongoing per-hour charge**
> (unlike Azure Firewall ~$288/month or AWS PrivateLink per-endpoint fees).
> You only pay standard data processing charges for traffic through the
> PSC endpoint.

## Prerequisites

- Terraform >= 1.5
- Ansible (with `community.general` collection)
- Google Cloud SDK (`gcloud`) authenticated with a project
- An SSH key pair
- An OpenShift pull secret ([console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))

### Service Account for openshift-install

`openshift-install` on GCP requires a service account JSON key file.
Create the service account and key before running `deploy.sh`:

```bash
# Create the service account
gcloud iam service-accounts create ocp-installer \
  --display-name="OpenShift Installer"

# Grant required roles
SA_EMAIL="ocp-installer@<project-id>.iam.gserviceaccount.com"

for ROLE in \
  roles/compute.admin \
  roles/dns.admin \
  roles/iam.roleAdmin \
  roles/iam.securityAdmin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountKeyAdmin \
  roles/iam.serviceAccountUser \
  roles/storage.admin \
  roles/serviceusage.serviceUsageAdmin; do
  gcloud projects add-iam-policy-binding <project-id> \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}"
done

# Create the JSON key
gcloud iam service-accounts keys create ~/ocp-installer-sa-key.json \
  --iam-account="${SA_EMAIL}"
```

Add the path to `terraform.tfvars`:

```hcl
installer_sa_key_file = "~/ocp-installer-sa-key.json"
```

Terraform passes the key file path to the bastion via Ansible, which
copies it to `~/.gcp/osServiceAccount.json` and configures
`GOOGLE_APPLICATION_CREDENTIALS` automatically.

## Directory Structure

```
disconnected/
├── terraform/
│   ├── main.tf                      # Provider configuration
│   ├── variables.tf                 # All input variables
│   ├── vpc.tf                       # VPCs, subnets, peering, Cloud Router + NAT
│   ├── psc.tf                       # Private Service Connect endpoint (all-apis)
│   ├── dns.tf                       # Cloud DNS private zones (googleapis, gcr, mirror)
│   ├── firewall.tf                  # GCP firewall rules for both VPCs
│   ├── iam.tf                       # Service account + IAM role bindings
│   ├── vm.tf                        # Bastion compute instance + external IP
│   ├── ansible.tf                   # Generated Ansible inventory + vars
│   ├── outputs.tf                   # All outputs
│   ├── deploy.sh                    # Environment setup script
│   ├── terraform.tfvars.example     # Example variable file
│   └── README.md                    # This file
├── setup-bastion-vm.yaml            # Ansible: configure bastion, mirror registry, images
├── files/
│   └── squid.conf                   # Squid proxy configuration
└── templates/
    ├── install-config.yaml.j2       # IPI install-config template for GCP
    ├── imageset-config.yaml.j2      # oc-mirror imageset configuration
    └── squid-allow-list.txt.j2      # Squid allow-list (GCP + Red Hat endpoints)
```

---

## Environment Setup

### 1. Setup the control node (only applies to RHEL9/Fedora)

```bash
sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo yum install ansible-core terraform -y
ansible-galaxy collection install community.general
git clone https://github.com/sadiquepp/openshift.git
gcloud auth login          # Authenticate with GCP
gcloud config set project <project-id>
gcloud auth application-default login
ssh-keygen                 # Generate SSH key pair
```

### 2. Create `terraform.tfvars`

Use the provided `terraform.tfvars.example` as a template:

```hcl
# ── Required ──────────────────────────────────────────────────────
gcp_project_id = "my-gcp-project"
gcp_region     = "asia-southeast1"
ssh_public_key = "ssh-rsa AAAAB3Nza..."

# Service account key for openshift-install (see above)
installer_sa_key_file = "~/ocp-installer-sa-key.json"

# ── Naming ────────────────────────────────────────────────────────
prefix_for_name               = "myproject"
openshift_base_domain         = "example.com"
openshift_cluster_name_suffix = "xt1"
```

### 3. Run the setup

```bash
cd openshift/gcp/self-managed/disconnected/terraform
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
| `--openshift-version`        | No       | Full version string, e.g. `4.20.0` (default: `4.20.0`)         |
| `--operators`                | No       | Comma-separated list of operators to mirror (default: none)     |

> **Disk sizing:** Each mirrored operator adds several GB of images to the bastion's
> mirror registry. If you include more than a handful of operators, increase
> `bastion_disk_size_gb` in `terraform.tfvars` (e.g. `300` or `400` GB) before
> running `deploy.sh`.

Any extra arguments are forwarded to the Ansible playbook (e.g. `-e "key=value"`).

This runs two steps:

| Step | Tool                              | What it does                                                                                                              |
| ---- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| 1    | Terraform                         | Creates VPCs, peering, PSC endpoint, Cloud DNS zones, firewall rules, service account, bastion VM                         |
| 2    | Ansible (`setup-bastion-vm.yaml`) | Installs packages, sets up mirror registry, mirrors OCP images, extracts tools, creates CCO credentials, prepares install-dir |

When complete, the bastion has:

- `openshift-install`, `oc`, `terraform`, `ccoctl`, `gcloud`
- Mirror registry on port 8444 with mirrored OCP images
- Squid proxy on port 3128
- IPI `~/install-dir/` with manifests ready for `create cluster`
- CCO credentials in `~/cco/`

### 4. SSH into the bastion

```bash
BASTION_IP=$(terraform output -raw bastion_public_ip)
ssh -i ~/.ssh/id_rsa ocpuser@$BASTION_IP
```

---

## Deploy a Cluster

### IPI (Installer-Provisioned Infrastructure)

GCP does not require the mid-install DNS linking that Azure needs -- Cloud DNS
private zones are project-scoped and immediately visible to all attached VPCs.

```bash
ssh ocpuser@$BASTION_IP
```
```bash
./openshift-install create cluster \
  --dir ~/install-dir \
  --log-level=debug
```

### Destroy and re-run

```bash
# 1. Destroy the cluster
./openshift-install destroy cluster \
  --dir ~/install-dir \
  --log-level=debug

# 2. Delete install-dir
rm -rf ~/install-dir

# 3. Unpack the backup of install-dir
tar -xjf ~/install-dir-backup.bz2

# 4. Re-run the installer
./openshift-install create cluster --dir ~/install-dir --log-level=debug
```

---

## Variables Reference

### Required

| Variable              | Description                                        |
| --------------------- | -------------------------------------------------- |
| `gcp_project_id`      | GCP project ID                                     |
| `ssh_public_key`      | SSH public key material for the bastion VM          |
| `installer_sa_key_file` | Path to GCP service account JSON key for installer |

### Naming and Region

| Variable                        | Default          | Description                                   |
| ------------------------------- | ---------------- | --------------------------------------------- |
| `prefix_for_name`               | `project_name`   | Prefix for all resource names                 |
| `gcp_region`                    | `asia-southeast1`| GCP region                                    |
| `openshift_base_domain`         | `example.com`    | Cluster base domain                           |
| `openshift_cluster_name_suffix` | `xt1`            | Suffix for cluster name (`<prefix>-<suffix>`) |

### Network CIDRs

| Variable                    | Default          | Description                           |
| --------------------------- | ---------------- | ------------------------------------- |
| `disconnected_vpc_cidr`     | `172.16.0.0/16`  | Disconnected VPC address space        |
| `control_plane_subnet_cidr` | `172.16.1.0/24`  | Control-plane subnet CIDR             |
| `compute_subnet_cidr`       | `172.16.2.0/24`  | Compute (worker) subnet CIDR          |
| `egress_vpc_cidr`           | `172.17.0.0/16`  | Egress VPC address space              |
| `egress_subnet_cidr`        | `172.17.1.0/24`  | Egress (bastion) subnet CIDR          |
| `psc_endpoint_ip`           | `172.16.100.2`   | Static IP for PSC endpoint            |

### Bastion VM

| Variable                | Default          | Description                      |
| ----------------------- | ---------------- | -------------------------------- |
| `bastion_machine_type`  | `e2-standard-4`  | GCE machine type                 |
| `bastion_disk_size_gb`  | `200`            | Boot disk size in GB             |
| `bastion_image_family`  | `rhel-9`         | Image family for the VM          |
| `bastion_image_project` | `rhel-cloud`     | Project hosting the VM image     |
| `admin_username`        | `ocpuser`        | Admin username for the VM        |
| `ssh_private_key_path`  | `~/.ssh/id_rsa`  | Path to SSH private key          |

---

## Outputs

After `terraform apply`, these outputs are available:

| Output                          | Description                         |
| ------------------------------- | ----------------------------------- |
| `bastion_public_ip`             | Bastion external IP for SSH         |
| `bastion_private_ip`            | Bastion internal IP                 |
| `bastion_name`                  | Bastion VM name                     |
| `psc_endpoint_ip`               | PSC endpoint IP for Google APIs     |
| `disconnected_vpc_name`         | Disconnected VPC name               |
| `control_plane_subnet_name`     | Control-plane subnet name           |
| `compute_subnet_name`           | Compute subnet name                 |
| `egress_vpc_name`               | Egress VPC name                     |
| `bastion_service_account_email` | Bastion VM service account email    |
| `cluster_domain`                | Fully qualified cluster domain      |
| `gcp_project_id`                | GCP project ID                      |
| `gcp_region`                    | GCP region                          |

These values are also automatically written to `ansible-vars.json` for use
by the Ansible playbook.

---

## Populate Operators from Mirror Registry

To populate operators from the mirror registry, run the following commands
from the bastion node:

```bash
export KUBECONFIG=~/install-dir/auth/kubeconfig
oc patch OperatorHub cluster --type json \
  -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
oc apply -f oc-mirror-output/working-dir/cluster-resources
```

## Teardown

```bash
# 1. Destroy any cluster first:
#    openshift-install destroy cluster --dir ~/install-dir

# 2. Destroy the environment
cd gcp/self-managed/disconnected/terraform
terraform destroy
```

---

## AWS / Azure / GCP Resource Mapping

| AWS Resource                | Azure Equivalent               | GCP Equivalent                     |
| --------------------------- | ------------------------------ | ---------------------------------- |
| VPC                         | Virtual Network (VNet)         | VPC Network                        |
| Subnet                      | Subnet                         | Subnetwork                         |
| Transit Gateway             | VNet Peering                   | VPC Network Peering                |
| Internet Gateway            | Public IP (on bastion NIC)     | Cloud NAT + External IP            |
| VPC Endpoints (Interface)   | Azure Firewall (FQDN rules)   | Private Service Connect (all-apis) |
| VPC Endpoints (Gateway/S3)  | Private Endpoint for Storage   | PSC (covers GCS)                   |
| Route53 Private Zone        | Azure Private DNS Zone         | Cloud DNS (private)                |
| IAM Role + Instance Profile | User-Assigned Managed Identity | Service Account (attached to VM)   |
| EC2 Instance                | Linux Virtual Machine          | Compute Engine Instance            |
| Security Group              | Network Security Group (NSG)   | VPC Firewall Rules                 |
| Key Pair                    | SSH key on VM                  | SSH key via instance metadata      |
