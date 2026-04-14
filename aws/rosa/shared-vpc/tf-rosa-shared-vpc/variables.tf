variable "prefix_for_name" {
  description = "Prefix used for all resource names — must match the disconnected-env deployment"
  type        = string
  default     = "project_name"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "openshift_base_domain" {
  description = "Base DNS domain for the OpenShift cluster (e.g. example.com)"
  type        = string
  default     = "example.com"
}

variable "openshift_cluster_name_suffix" {
  description = "Short suffix appended to prefix_for_name to form the cluster name"
  type        = string
  default     = "xt1"
}

variable "rosa_shared_vpc_cluster_domain" {
  description = "Domain used for the ROSA shared-VPC hosted zone (rosa.<cluster>.<this>)"
  type        = string
}

variable "aws_account_number_to_share_with" {
  description = "AWS account ID that will receive the RAM subnet share (the ROSA account)"
  type        = string
}

variable "resource_share_name" {
  description = "Suffix for the RAM resource share name"
  type        = string
  default     = "rosa-share-subnet"
}
