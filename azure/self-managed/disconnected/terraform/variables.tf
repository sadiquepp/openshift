variable "prefix_for_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "project_name"
}

variable "azure_region" {
  description = "Azure region"
  type        = string
  default     = "southeastasia"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

# ── Service Principal for openshift-install ──────────────────────────────────

variable "installer_sp_client_id" {
  description = "Client (app) ID of the pre-created service principal for openshift-install"
  type        = string
}

variable "installer_sp_client_secret" {
  description = "Client secret of the pre-created service principal for openshift-install"
  type        = string
  sensitive   = true
}

# ── Disconnected VNet ────────────────────────────────────────────────────────

variable "disconnected_vnet_cidr" {
  description = "Address space for the disconnected VNet"
  type        = string
  default     = "172.16.0.0/16"
}

variable "disconnected_subnet_cidrs" {
  description = "CIDR blocks for disconnected private subnets (one per availability zone)"
  type        = list(string)
  default     = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
}

# ── Egress VNet ──────────────────────────────────────────────────────────────

variable "egress_vnet_cidr" {
  description = "Address space for the egress VNet"
  type        = string
  default     = "172.17.0.0/16"
}

variable "egress_public_subnet_cidr" {
  description = "CIDR block for the egress public subnet (bastion)"
  type        = string
  default     = "172.17.1.0/24"
}

# ── Private Endpoints ────────────────────────────────────────────────────────

variable "private_endpoint_subnet_cidr" {
  description = "Dedicated subnet CIDR for private endpoints in the disconnected VNet"
  type        = string
  default     = "172.16.10.0/24"
}

# ── OpenShift Cluster ────────────────────────────────────────────────────────

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

# ── Bastion VM ───────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key material for the bastion VM (also used for OpenShift nodes)"
  type        = string
}

variable "installer_vm_size" {
  description = "Azure VM size for the bastion / installer instance"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "installer_disk_size" {
  description = "OS disk size in GB for the bastion instance"
  type        = number
  default     = 100
}

variable "installer_image" {
  description = "Source image reference for the bastion VM"
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "9_4"
    version   = "latest"
  }
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for connecting to the bastion VM (used in generated Ansible inventory)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "admin_username" {
  description = "Admin username for the bastion VM"
  type        = string
  default     = "azureuser"
}
