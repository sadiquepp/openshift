terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# This stack runs in the ROSA / installer account.
provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
