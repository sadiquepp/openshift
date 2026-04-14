variable "prefix_for_name" {
  description = "Prefix for all resource names — must match the other stacks"
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

variable "openshift_major_version" {
  description = "OpenShift major.minor version string (e.g. 4.20)"
  type        = string
  default     = "4.20"
}

variable "oidc_config_id" {
  description = "OIDC configuration ID issued by Red Hat — appears in the OIDC provider URL"
  type        = string
  # Obtain this after running: rosa create oidc-config
}

variable "vpc_owner_account_id" {
  description = "AWS account ID of the VPC owner (for the shared-VPC assume-role policies)"
  type        = string
}
