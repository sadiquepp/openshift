# Step 1: Deploy the disconnected VPC
cd tf-disconnected
terraform plan -var="prefix_for_name=myproject"
terraform init && terraform apply

# Step 2: Deploy the ROSA roles
cd ../tf-rosa-roles
terraform plan -var="prefix_for_name=myproject"
terraform init
terraform apply \
  -var="oidc_config_id=<your-oidc-id>" \
  -var="vpc_owner_account_id=<vpc-owner-account>"

# Step 3: Share the subnets with the ROSA account
cd ../tf-rosa-shared-vpc
terraform plan -var="prefix_for_name=myproject"
terraform init && terraform apply \
  -var="aws_account_number_to_share_with=123456789012" \
  -var="rosa_shared_vpc_cluster_domain=rosa.example.com"


