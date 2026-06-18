terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "hcp"
  region = var.aws_region
}

provider "aws" {
  alias  = "xacct"
  region = var.aws_region

  assume_role {
    role_arn     = var.hcp_account_role_arn != "" ? var.hcp_account_role_arn : null
    session_name = var.hcp_account_role_arn != "" ? "terraform-hcp-xacct" : null
  }
}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

data "aws_caller_identity" "current" {}

data "aws_caller_identity" "hcp" {
  provider = aws.hcp
}

data "aws_caller_identity" "xacct" {
  provider = aws.xacct
}
