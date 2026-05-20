# ── Cluster identity ───────────────────────────────────────────────────────────

variable "infrastructure_name" {
  description = "Short unique cluster ID used to tag resources (infra_id from openshift-install metadata.json)"
  type        = string
  # Obtain after: INFRA_ID=$(jq -r .infraID install-dir/metadata.json)
}

variable "cluster_name" {
  description = "OpenShift cluster name (metadata.name in install-config.yaml)"
  type        = string
}

variable "cluster_domain" {
  description = "Cluster base domain (e.g. example.com)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

# ── Network ────────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "VPC ID where all cluster resources will be created"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used for intra-cluster security group rules"
  type        = string
}

variable "loadbalancer_cidr" {
  description = "External load balancer CIDR — allowed to reach 443, 80, 1936 on worker/infra nodes"
  type        = string
}

variable "bootstrap_subnet_id" {
  description = "Subnet ID for the bootstrap node (any AZ)"
  type        = string
}

variable "subnet_id_az1" {
  description = "Private subnet ID in AZ1 — used for master0, worker1, infra1"
  type        = string
}

variable "subnet_id_az2" {
  description = "Private subnet ID in AZ2 — used for master1, worker2, infra2"
  type        = string
}

variable "subnet_id_az3" {
  description = "Private subnet ID in AZ3 — used for master2, worker3, infra3"
  type        = string
}

# ── AMI ────────────────────────────────────────────────────────────────────────

variable "rhcos_ami_id" {
  description = "RHCOS AMI ID for the target OCP version and region. See Red Hat docs for the correct AMI per version/region."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.rhcos_ami_id))
    error_message = "rhcos_ami_id must be a valid AMI ID (e.g. ami-0123456789abcdef0). Update it in terraform.tfvars with the RHCOS AMI for your OCP version and region."
  }
}

# ── Instance types ─────────────────────────────────────────────────────────────

variable "bootstrap_instance_type" {
  description = "EC2 instance type for the bootstrap node"
  type        = string
  default     = "i3.large"
}

variable "master_instance_type" {
  description = "EC2 instance type for control plane nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "m5.xlarge"
}

variable "infra_instance_type" {
  description = "EC2 instance type for infra nodes"
  type        = string
  default     = "m6i.xlarge"
}

# ── Fixed private IPs ──────────────────────────────────────────────────────────
# Reserve these in AWS VPC -> Subnets -> Actions -> Edit IPv4 CIDR Reservation
# before running terraform apply.

variable "bootstrap_private_ip" {
  description = "Pre-reserved private IP for the bootstrap node"
  type        = string
}

variable "master0_private_ip" {
  description = "Pre-reserved private IP for master0 (AZ1)"
  type        = string
}

variable "master1_private_ip" {
  description = "Pre-reserved private IP for master1 (AZ2)"
  type        = string
}

variable "master2_private_ip" {
  description = "Pre-reserved private IP for master2 (AZ3)"
  type        = string
}

variable "worker1_private_ip" {
  description = "Pre-reserved private IP for worker1 (AZ1)"
  type        = string
}

variable "worker2_private_ip" {
  description = "Pre-reserved private IP for worker2 (AZ2)"
  type        = string
}

variable "worker3_private_ip" {
  description = "Pre-reserved private IP for worker3 (AZ3)"
  type        = string
}

variable "infra1_private_ip" {
  description = "Pre-reserved private IP for infra1 (AZ1)"
  type        = string
}

variable "infra2_private_ip" {
  description = "Pre-reserved private IP for infra2 (AZ2)"
  type        = string
}

variable "infra3_private_ip" {
  description = "Pre-reserved private IP for infra3 (AZ3)"
  type        = string
}

# ── Ignition ───────────────────────────────────────────────────────────────────

variable "certificate_authority" {
  description = <<-EOT
    Base64-encoded certificate authority from master.ign / worker.ign in data URI form.
    Extract with:
      export CERTIFICATE_AUTHORITY=$(cat install-dir/master.ign | cut -f8 -d{ | cut -f2,3 -d: | cut -f1 -d})
    The value should look like: data:text/plain;charset=utf-8;base64,<base64>
  EOT
  type        = string
  sensitive   = true
}

variable "allowed_bootstrap_ssh_cidr" {
  description = "CIDR allowed to SSH to the bootstrap node"
  type        = string
  default     = "0.0.0.0/0"
}

# ── DNS ───────────────────────────────────────────────────────────────────────

variable "egress_vpc_id" {
  description = "Egress VPC ID — the UPI hosted zone is associated with this VPC so the bastion can resolve cluster DNS"
  type        = string
}

# ── Feature flags ──────────────────────────────────────────────────────────────

variable "create_nlb_and_dns" {
  description = "Create an internal NLB with listeners/target-groups and Route53 A records. Set to false to bring your own load balancer and DNS."
  type        = bool
  default     = false
}

variable "create_infra_nodes" {
  description = "Set to true to deploy dedicated infra nodes in addition to workers"
  type        = bool
  default     = true
}
