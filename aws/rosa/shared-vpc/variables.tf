# ── Account targeting ─────────────────────────────────────────────────────────

variable "vpc_owner_role_arn" {
  description = "IAM role ARN to assume in the VPC owner account. Leave empty to use the default credential chain (e.g. AWS_PROFILE)."
  type        = string
  default     = ""
}

variable "rosa_account_role_arn" {
  description = "IAM role ARN to assume in the ROSA/installer account. Leave empty to use the default credential chain."
  type        = string
  default     = ""
}

# ── Shared naming ─────────────────────────────────────────────────────────────

variable "prefix_for_name" {
  type    = string
  default = "project_name"
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "openshift_cluster_name_suffix" {
  type    = string
  default = "xt1"
}

variable "openshift_base_domain" {
  type    = string
  default = "example.com"
}

variable "openshift_major_version" {
  type    = string
  default = "4.20"
}

variable "openshift_minor_version" {
  type    = number
  default = 0
}

variable "rosa_shared_vpc_cluster_domain" {
  type = string
}

variable "resource_share_name" {
  type    = string
  default = "rosa-share-subnet"
}

variable "oidc_config_id" {
  description = "OIDC configuration ID from: rosa create oidc-config"
  type        = string
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "aws_disconnected_vpc_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "aws_egress_vpc_cidr" {
  type    = string
  default = "172.17.0.0/16"
}

# ── Bastion EC2 ───────────────────────────────────────────────────────────────

variable "aws_ami" {
  type    = string
  default = "ami-04698733964af06d5"
}

variable "aws_instance_type" {
  type    = string
  default = "t2.large"
}

variable "ec2_disk_size" {
  type    = number
  default = 100
}

variable "ssh_public_key" {
  type      = string
  sensitive = true
}

variable "mirror_registry_password" {
  type      = string
  sensitive = true
}

variable "pull_secret" {
  type      = string
  sensitive = true
}
