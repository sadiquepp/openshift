# Replace the share_subnets module block in tf-rosa-platform/main.tf with this.
# The key change: rosa_account_id is now wired explicitly from step 2,
# and aws_account_number_to_share_with is the same value (kept for RAM share).

module "share_subnets" {
  source = "./modules/tf-rosa-shared-vpc"

  providers = {
    aws = aws.vpc_owner
  }

  prefix_for_name                  = var.prefix_for_name
  aws_region                       = var.aws_region
  openshift_cluster_name_suffix    = var.openshift_cluster_name_suffix
  openshift_base_domain            = var.openshift_base_domain
  rosa_shared_vpc_cluster_domain   = var.rosa_shared_vpc_cluster_domain
  resource_share_name              = var.resource_share_name

  # Wired from Step 2 — used to build exact role ARN principals in trust policies
  rosa_account_id                  = module.rosa_roles.rosa_account_id

  # Same account receives the RAM subnet share
  aws_account_number_to_share_with = module.rosa_roles.rosa_account_id
}
