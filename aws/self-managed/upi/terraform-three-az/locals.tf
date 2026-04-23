locals {
  infra_id = var.infrastructure_name

  # MCS ignition endpoints — served by the bootstrap/masters during install
  master_ignition_location = "https://api-int.${var.cluster_name}.${var.cluster_domain}:22623/config/master"
  worker_ignition_location = "https://api-int.${var.cluster_name}.${var.cluster_domain}:22623/config/worker"

  # Bootstrap ignition is fetched from S3 by the bootstrap instance at boot.
  # Uses the regional HTTPS URL so traffic routes through the S3 VPC Gateway
  # endpoint in disconnected environments (s3:// scheme can fail if Ignition
  # cannot determine the bucket region).
  bootstrap_ignition_location = "https://${local.infra_id}.s3.${var.aws_region}.amazonaws.com/bootstrap.ign"

  # Instance profile names match what openshift-install expects
  master_instance_profile = "${local.infra_id}-master-profile"
  worker_instance_profile = "${local.infra_id}-worker-profile"

  common_tags = {
    "kubernetes.io/cluster/${local.infra_id}" = "shared"
  }
}
