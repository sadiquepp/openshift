variable "prefix_for_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "project_name"
}

variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "asia-southeast1"
}

# ── Service Account for openshift-install ─────────────────────────────────────

variable "installer_sa_key_file" {
  description = "Path to the pre-created GCP service account JSON key file for openshift-install. Create one with: gcloud iam service-accounts keys create key.json --iam-account=<SA_EMAIL>"
  type        = string
}

# ── Disconnected VPC ──────────────────────────────────────────────────────────

variable "disconnected_vpc_cidr" {
  description = "Primary CIDR for the disconnected VPC subnets"
  type        = string
  default     = "172.16.0.0/16"
}

variable "control_plane_subnet_cidr" {
  description = "CIDR block for the control-plane subnet in the disconnected VPC"
  type        = string
  default     = "172.16.1.0/24"
}

variable "compute_subnet_cidr" {
  description = "CIDR block for the compute (worker) subnet in the disconnected VPC"
  type        = string
  default     = "172.16.2.0/24"
}

# ── Egress VPC ────────────────────────────────────────────────────────────────

variable "egress_vpc_cidr" {
  description = "Primary CIDR for the egress VPC subnets"
  type        = string
  default     = "172.17.0.0/16"
}

variable "egress_subnet_cidr" {
  description = "CIDR block for the egress (bastion) subnet"
  type        = string
  default     = "172.17.1.0/24"
}

# ── PSC ───────────────────────────────────────────────────────────────────────

variable "psc_endpoint_ip" {
  description = "Static internal IP for the PSC endpoint in the disconnected VPC (must be within disconnected_vpc_cidr but outside subnet ranges)"
  type        = string
  default     = "172.16.100.2"
}

# ── OpenShift Cluster ─────────────────────────────────────────────────────────

variable "openshift_base_domain" {
  description = "Base domain for the OpenShift cluster (e.g. example.com)"
  type        = string
  default     = "example.com"
}

variable "openshift_cluster_name_suffix" {
  description = "Suffix appended to prefix_for_name to form the cluster name"
  type        = string
  default     = "xt1"
}

# ── Bastion VM ────────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key material for the bastion VM (also used for OpenShift nodes)"
  type        = string
}

variable "bastion_machine_type" {
  description = "GCE machine type for the bastion instance"
  type        = string
  default     = "e2-standard-4"
}

variable "bastion_disk_size_gb" {
  description = "Boot disk size in GB for the bastion instance"
  type        = number
  default     = 200
}

variable "bastion_image_family" {
  description = "Image family for the bastion VM"
  type        = string
  default     = "rhel-9"
}

variable "bastion_image_project" {
  description = "Project hosting the bastion VM image"
  type        = string
  default     = "rhel-cloud"
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for connecting to the bastion VM (used in generated Ansible inventory)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "admin_username" {
  description = "Admin username for the bastion VM"
  type        = string
  default     = "ocpuser"
}
