variable "prefix_for_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "project_name"
}

variable "ibmcloud_region" {
  description = "IBM Cloud region"
  type        = string
  default     = "us-east"
}

variable "ibmcloud_api_key" {
  description = "IBM Cloud API key. If empty, the provider falls back to IC_API_KEY or IBMCLOUD_API_KEY env var."
  type        = string
  sensitive   = true
  default     = ""
}

variable "create_resource_group" {
  description = "Create a new resource group. When false, resource_group_name must refer to an existing group."
  type        = bool
  default     = true
}

variable "resource_group_name" {
  description = "Name of the IBM Cloud resource group (created or existing, depending on create_resource_group)"
  type        = string
  default     = "Default"
}

variable "zones" {
  description = "VPC zones in the selected region (one subnet per zone)"
  type        = list(string)
  default     = ["us-east-1", "us-east-2", "us-east-3"]
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

variable "connected_vpc_cidr" {
  description = "Supernet CIDR covering all subnets (used in install-config machineNetwork)"
  type        = string
  default     = "172.16.0.0/16"
}

variable "control_plane_subnet_cidrs" {
  description = "CIDR blocks for the control-plane subnets (one per zone)"
  type        = list(string)
  default     = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
}

variable "compute_subnet_cidrs" {
  description = "CIDR blocks for the compute (worker) subnets (one per zone)"
  type        = list(string)
  default     = ["172.16.4.0/24", "172.16.5.0/24", "172.16.6.0/24"]
}

variable "bastion_subnet_cidr" {
  description = "CIDR block for the bastion subnet (zone 1)"
  type        = string
  default     = "172.16.10.0/24"
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

variable "bastion_profile" {
  description = "VPC instance profile for the bastion (vCPU x RAM)"
  type        = string
  default     = "bx2-4x16"
}

variable "bastion_image_name" {
  description = "Stock image name for the bastion VM. List available RHEL 9 images with: ibmcloud is images --visibility public --status available | grep redhat-9"
  type        = string
  default     = "ibm-redhat-9-4-minimal-amd64-3"
}

variable "bastion_boot_volume_size" {
  description = "Boot volume size in GB for the bastion instance"
  type        = number
  default     = 100
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for connecting to the bastion VM (used in generated Ansible inventory)"
  type        = string
  default     = "~/.ssh/id_rsa"
}
