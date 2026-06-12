variable "prefix_for_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "project_name"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

# ── Connected VPC ─────────────────────────────────────────────────────────────

variable "connected_vpc_cidr" {
  description = "CIDR block for the connected VPC"
  type        = string
  default     = "172.16.0.0/16"
}

variable "connected_private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
}

variable "connected_public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["172.16.4.0/24", "172.16.5.0/24", "172.16.6.0/24"]
}

# ── OpenShift ─────────────────────────────────────────────────────────────────

variable "openshift_base_domain" {
  description = "Base domain for OpenShift cluster"
  type        = string
  default     = "example.com"
}

variable "openshift_cluster_name_suffix" {
  description = "Suffix appended to prefix_for_name to form the cluster name"
  type        = string
  default     = "xx1"
}

# ── OpenShift Compute ────────────────────────────────────────────────────────

variable "compute_instance_type" {
  description = "Instance type for OpenShift compute (worker) nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "compute_replicas" {
  description = "Number of OpenShift compute (worker) node replicas"
  type        = number
  default     = 3
}

variable "control_plane_replicas" {
  description = "Number of OpenShift control plane (master) node replicas"
  type        = number
  default     = 3
}

# ── Bastion EC2 ───────────────────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key material for the EC2 key pair"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key (used by Ansible)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "installer_ami" {
  description = "AMI ID for the bastion EC2 instance"
  type        = string
  default     = "ami-04698733964af06d5"
}

variable "installer_instance_type" {
  description = "Instance type for the bastion EC2"
  type        = string
  default     = "t2.medium"
}

variable "installer_disk_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 50
}

# ── HCP Cross-Account ────────────────────────────────────────────────────────

variable "hcp_xacct_cluster_suffixes" {
  description = "List of HCP cluster suffixes to deploy into a separate AWS account (e.g. [\"hcp3\"]). Resources (VPC, IAM, OIDC, Route53) are created in the HCP account via assume_role. Must not overlap with hcp_cluster_suffixes."
  type        = list(string)
  default     = []
}

variable "hcp_account_role_arn" {
  description = "ARN of the IAM role to assume in the HCP account (e.g. arn:aws:iam::123456789012:role/TerraformHCPRole). Required when hcp_xacct_cluster_suffixes is non-empty."
  type        = string
  default     = ""
}

check "hcp_xacct_requires_role_arn" {
  assert {
    condition     = length(var.hcp_xacct_cluster_suffixes) == 0 || var.hcp_account_role_arn != ""
    error_message = "hcp_account_role_arn must be set when hcp_xacct_cluster_suffixes is non-empty."
  }
}

check "hcp_no_suffix_overlap" {
  assert {
    condition     = length(setintersection(toset(var.hcp_cluster_suffixes), toset(var.hcp_xacct_cluster_suffixes))) == 0
    error_message = "hcp_cluster_suffixes and hcp_xacct_cluster_suffixes must not overlap."
  }
}
