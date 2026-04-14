variable "prefix_for_name" {
  description = "Prefix used for all resource names — must match the VPC owner stacks"
  type        = string
  default     = "project_name"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "openshift_cluster_name_suffix" {
  description = "Short suffix appended to prefix_for_name to form the cluster name"
  type        = string
  default     = "xt1"
}

variable "openshift_base_domain" {
  description = "Base DNS domain for the OpenShift cluster"
  type        = string
  default     = "example.com"
}

variable "aws_ami" {
  description = "AMI ID for the installer/bastion EC2 instance"
  type        = string
  default     = "ami-04698733964af06d5"
}

variable "aws_instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.large"
}

variable "ec2_disk_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

variable "ssh_public_key" {
  description = "SSH public key material to import as an EC2 key pair"
  type        = string
  # Override this — do not store real keys in source control
  default     = ""
}

# ── Variables passed in from the VPC owner account outputs ──────────────────
# These mirror the set_stats outputs from the share-subnets playbook.
# In practice, feed these from terraform_remote_state or tfvars.

variable "egress_vpc_id" {
  description = "ID of the egress VPC (from VPC owner account)"
  type        = string
}

variable "egress_vpc_cidr" {
  description = "CIDR of the egress VPC (from VPC owner account)"
  type        = string
}

variable "egress_subnet_id_a" {
  description = "Egress public subnet ID in AZ1 — the EC2 is placed here"
  type        = string
}

variable "disconnected_vpc_cidr" {
  description = "CIDR of the disconnected VPC (from VPC owner account)"
  type        = string
}

# ── Bastion setup variables (fed into user_data) ────────────────────────────

variable "openshift_major_version" {
  description = "OpenShift major.minor version (e.g. 4.20)"
  type        = string
  default     = "4.20"
}

variable "openshift_minor_version" {
  description = "OpenShift patch version"
  type        = number
  default     = 0
}

variable "mirror_registry_password" {
  description = "Initial password for the Quay mirror registry"
  type        = string
  sensitive   = true
}

variable "pull_secret" {
  description = "Red Hat pull secret JSON (from console.redhat.com)"
  type        = string
  sensitive   = true
}

variable "quay_root_mount" {
  description = "Mount path for Quay registry storage"
  type        = string
  default     = "/registry"
}

variable "openshift_local_repository" {
  description = "Repository path used when extracting the installer from the mirror"
  type        = string
  default     = "openshift/release-images"
}
