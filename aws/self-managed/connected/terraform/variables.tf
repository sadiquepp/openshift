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

# ── Route53 ───────────────────────────────────────────────────────────────────

variable "create_public_hosted_zone" {
  description = "Create a public Route53 hosted zone for the base domain (required for public clusters)"
  type        = bool
  default     = true
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
