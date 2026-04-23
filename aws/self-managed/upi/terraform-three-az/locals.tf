locals {
  infra_id = var.infrastructure_name

  # MCS ignition endpoints — served by the bootstrap/masters during install
  master_ignition_location = "https://api-int.${var.cluster_name}.${var.cluster_domain}:22623/config/master"
  worker_ignition_location = "https://api-int.${var.cluster_name}.${var.cluster_domain}:22623/config/worker"

  # Bootstrap ignition is fetched from S3 by the bootstrap instance at boot
  bootstrap_ignition_location = "s3://${local.infra_id}/bootstrap.ign"

  # Instance profile names match what openshift-install expects
  master_instance_profile = "${local.infra_id}-master-profile"
  worker_instance_profile = "${local.infra_id}-worker-profile"

  common_tags = {
    "kubernetes.io/cluster/${local.infra_id}" = "shared"
  }
}
