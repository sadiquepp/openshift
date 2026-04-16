variable "prefix_for_name" {
  description = "Prefix for all resource names — must match the other stacks"
  type        = string
  default     = "project_name"
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

variable "rosa_shared_vpc_cluster_domain" {
  description = "Domain for the ROSA shared-VPC hosted zone (rosa.<cluster>.<this>)"
  type        = string
}

variable "resource_share_name" {
  type    = string
  default = "rosa-share-subnet"
}

variable "rosa_account_id" {
  description = <<-EOT
    AWS account ID of the ROSA / installer account.
    Used to construct the exact role ARN principals in the Route53 and
    Endpoint IAM trust policies — replacing the overly broad :root principal.
    In the root module this is wired from module.rosa_roles.rosa_account_id.
  EOT
  type        = string
}

variable "aws_account_number_to_share_with" {
  description = "AWS account ID to receive the RAM subnet share (same as rosa_account_id in most deployments)"
  type        = string
}
