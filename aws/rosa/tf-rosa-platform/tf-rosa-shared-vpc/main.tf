terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────
# Look up existing VPCs created by the
# disconnected-env Terraform deployment
# ─────────────────────────────────────────

data "aws_vpc" "disconnected" {
  filter {
    name   = "tag:Name"
    values = [local.disconnected_vpc_name]
  }
}

data "aws_vpc" "egress" {
  filter {
    name   = "tag:Name"
    values = [local.egress_vpc_name]
  }
}

# Disconnected subnets — looked up individually by Name tag
# (mirrors the three separate Ansible ec2_vpc_subnet_info queries)

data "aws_subnet" "disconnected_az1" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.disconnected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["${local.disconnected_vpc_name}-subnet-az1"]
  }
}

data "aws_subnet" "disconnected_az2" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.disconnected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["${local.disconnected_vpc_name}-subnet-az2"]
  }
}

data "aws_subnet" "disconnected_az3" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.disconnected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["${local.disconnected_vpc_name}-subnet-az3"]
  }
}

# All egress subnets — the Ansible playbook grabs subnets[0] from
# an unfiltered list, which is non-deterministic. We pin to the
# public-az1 subnet to make the behaviour explicit and repeatable.

data "aws_subnet" "egress_public_az1" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.egress.id]
  }
  filter {
    name   = "tag:Name"
    values = ["${local.egress_vpc_name}-public-az1"]
  }
}
