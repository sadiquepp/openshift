terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Two provider aliases — one per AWS account.
# This is the Terraform equivalent of AAP attaching different credentials
# to each workflow job template.
#
# OPTION A (recommended for CI/CD): assume a role in each account from a
# central automation account. Set TF_VAR_vpc_owner_role_arn and
# TF_VAR_rosa_account_role_arn in your pipeline secrets.
#
# OPTION B (local / simple): use named AWS profiles and the Makefile.
# Comment out the assume_role blocks below and uncomment the profile lines.
# ─────────────────────────────────────────────────────────────────────────────

provider "aws" {
  alias  = "vpc_owner"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.vpc_owner_role_arn != "" ? [1] : []
    content {
      role_arn     = var.vpc_owner_role_arn
      session_name = "terraform-vpc-owner"
    }
  }

  # Option B — comment out assume_role above and uncomment this:
  # profile = "vpc-owner"
}

provider "aws" {
  alias  = "rosa_account"
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.rosa_account_role_arn != "" ? [1] : []
    content {
      role_arn     = var.rosa_account_role_arn
      session_name = "terraform-rosa-account"
    }
  }

  # profile = "rosa-account"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Create disconnected VPC (VPC owner account)
# ─────────────────────────────────────────────────────────────────────────────

module "disconnected_vpc" {
  source = "./modules/tf-disconnected"

  providers = {
    aws = aws.vpc_owner
  }

  prefix_for_name           = var.prefix_for_name
  aws_region                = var.aws_region
  aws_disconnected_vpc_cidr = var.aws_disconnected_vpc_cidr
  aws_egress_vpc_cidr       = var.aws_egress_vpc_cidr
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Create ROSA roles (ROSA cluster account)
# Depends on step 1 only for the vpc_owner_account_id output.
# ─────────────────────────────────────────────────────────────────────────────

module "rosa_roles" {
  source = "./modules/tf-rosa-roles"

  providers = {
    aws = aws.rosa_account
  }

  prefix_for_name               = var.prefix_for_name
  aws_region                    = var.aws_region
  openshift_cluster_name_suffix = var.openshift_cluster_name_suffix
  openshift_major_version       = var.openshift_major_version
  oidc_config_id                = var.oidc_config_id
  vpc_owner_account_id          = module.disconnected_vpc.aws_account_id
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Share subnets (VPC owner account)
# Depends on step 1 (subnets must exist) and step 2 (ROSA role ARNs must
# exist before the trust policies can reference them).
# ─────────────────────────────────────────────────────────────────────────────

module "share_subnets" {
  source = "./modules/tf-rosa-shared-vpc"

  providers = {
    aws = aws.vpc_owner
  }

  prefix_for_name                = var.prefix_for_name
  aws_region                     = var.aws_region
  openshift_cluster_name_suffix  = var.openshift_cluster_name_suffix
  openshift_base_domain          = var.openshift_base_domain
  rosa_shared_vpc_cluster_domain = var.rosa_shared_vpc_cluster_domain
  resource_share_name            = var.resource_share_name

  # Wired from step 2 — used to build exact role ARN principals in the
  # Route53 and Endpoint trust policies (from the actual Jinja2 templates).
  rosa_account_id                  = module.rosa_roles.rosa_account_id

  # Same account receives the RAM subnet share
  aws_account_number_to_share_with = module.rosa_roles.rosa_account_id
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Create and configure bastion/installer EC2 (ROSA account)
# Depends on step 3 (subnet IDs and VPC IDs must be known and shared).
# ─────────────────────────────────────────────────────────────────────────────

module "installer_ec2" {
  source = "./modules/tf-installer-ec2"

  providers = {
    aws = aws.rosa_account
  }

  prefix_for_name               = var.prefix_for_name
  aws_region                    = var.aws_region
  openshift_cluster_name_suffix = var.openshift_cluster_name_suffix
  openshift_base_domain         = var.openshift_base_domain
  openshift_major_version       = var.openshift_major_version
  openshift_minor_version       = var.openshift_minor_version
  aws_ami                       = var.aws_ami
  aws_instance_type             = var.aws_instance_type
  ec2_disk_size                 = var.ec2_disk_size
  ssh_public_key                = var.ssh_public_key
  mirror_registry_password      = var.mirror_registry_password
  pull_secret                   = var.pull_secret

  # Wired from step 3 outputs
  egress_vpc_id         = module.share_subnets.egress_vpc_id
  egress_vpc_cidr       = module.share_subnets.egress_vpc_cidr
  egress_subnet_id_a    = module.share_subnets.egress_subnet_id_a
  disconnected_vpc_cidr = module.share_subnets.disconnected_vpc_cidr
}
