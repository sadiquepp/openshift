terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# This stack runs in the ROSA/installer account — NOT the VPC owner account.
# Configure credentials for this account via AWS_PROFILE, environment
# variables, or an assume_role block below.
provider "aws" {
  region = var.aws_region

  # Uncomment and populate if using cross-account role assumption:
  # assume_role {
  #   role_arn = "arn:aws:iam::<INSTALLER_ACCOUNT_ID>:role/<ROLE>"
  # }
}

data "aws_caller_identity" "current" {}
