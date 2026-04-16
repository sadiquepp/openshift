variable "prefix_for_name" {
  description = "Prefix used for all resource names"
  type        = string
  default     = "project_name"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-southeast-1"
}

variable "aws_disconnected_vpc_cidr" {
  description = "CIDR block for the disconnected VPC"
  type        = string
  default     = "172.16.0.0/16"
}

variable "aws_egress_vpc_cidr" {
  description = "CIDR block for the egress VPC"
  type        = string
  default     = "172.17.0.0/16"
}

variable "aws_disconnected_subnet_cidrs" {
  description = "CIDRs for the three disconnected private subnets (one per AZ)"
  type        = list(string)
  default     = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
}

variable "aws_egress_subnet_public_cidrs" {
  description = "CIDRs for the egress public subnets (one per AZ)"
  type        = list(string)
  default     = ["172.17.1.0/24", "172.17.2.0/24", "172.17.3.0/24"]
}

variable "aws_egress_subnet_private_cidrs" {
  description = "CIDRs for the egress private subnets (one per AZ)"
  type        = list(string)
  default     = ["172.17.4.0/24", "172.17.5.0/24", "172.17.6.0/24"]
}
