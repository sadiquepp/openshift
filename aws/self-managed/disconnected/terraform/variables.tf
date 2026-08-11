variable "prefix_for_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "project_name"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

# ── Disconnected VPC ──────────────────────────────────────────────────────────

variable "disconnected_vpc_cidr" {
  description = "CIDR block for the disconnected VPC"
  type        = string
  default     = "172.16.0.0/16"
}

variable "disconnected_subnet_cidrs" {
  description = "CIDR blocks for disconnected private subnets (one per AZ)"
  type        = list(string)
  default     = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
}

# ── Egress VPC ────────────────────────────────────────────────────────────────

variable "egress_vpc_cidr" {
  description = "CIDR block for the egress VPC"
  type        = string
  default     = "172.17.0.0/16"
}

variable "egress_public_subnet_cidrs" {
  description = "CIDR blocks for egress public subnets (one per AZ)"
  type        = list(string)
  default     = ["172.17.1.0/24", "172.17.2.0/24", "172.17.3.0/24"]
}

variable "egress_private_subnet_cidrs" {
  description = "CIDR blocks for egress private subnets (one per AZ)"
  type        = list(string)
  default     = ["172.17.4.0/24", "172.17.5.0/24", "172.17.6.0/24"]
}

# ── VPC Endpoints ─────────────────────────────────────────────────────────────

variable "interface_endpoint_services" {
  description = "Regional AWS services to create Interface VPC endpoints for (service name: com.amazonaws.<region>.<service>)"
  type        = list(string)
  default     = ["ec2", "sts", "elasticloadbalancing", "ecr.api", "ecr.dkr"]
}

variable "global_endpoint_services" {
  description = "Global AWS services with cross-region VPC endpoint support (service name: com.amazonaws.<service>, no region prefix, DNS: <service>.amazonaws.com)"
  type        = list(string)
  default     = ["iam", "route53"]
}

variable "cross_region_endpoint_services" {
  description = "Regional AWS services in us-east-1 accessed via cross-region VPC endpoints (service name: com.amazonaws.us-east-1.<service>, DNS: <service>.us-east-1.amazonaws.com)"
  type        = list(string)
  default     = ["tagging"]
}

# ── UPI Node IPs ─────────────────────────────────────────────────────────────
# Host number (last octet for /24 subnets) for each UPI node.
# bootstrap, master0, worker1, infra1 → subnet A (AZ1)
# master1, worker2, infra2             → subnet B (AZ2)
# master2, worker3, infra3             → subnet C (AZ3)

variable "upi_node_host_numbers" {
  description = "Host number within its subnet for each UPI node IP reservation"
  type = object({
    bootstrap = number
    master0   = number
    master1   = number
    master2   = number
    worker1   = number
    worker2   = number
    worker3   = number
    infra1    = number
    infra2    = number
    infra3    = number
  })
  default = {
    bootstrap = 99
    master0   = 100
    master1   = 100
    master2   = 100
    worker1   = 110
    worker2   = 110
    worker3   = 110
    infra1    = 120
    infra2    = 120
    infra3    = 120
  }
}

# ── OpenShift Cluster ─────────────────────────────────────────────────────────

variable "openshift_base_domain" {
  description = "Base domain for the OpenShift cluster (e.g. example.com)"
  type        = string
  default     = "example.com"
}

variable "openshift_cluster_name_suffix" {
  description = "Suffix appended to prefix_for_name to form the cluster name"
  type        = string
  default     = "xt1"
}

variable "compute_replicas" {
  description = "Number of compute (worker) replicas for the OpenShift cluster"
  type        = number
  default     = 3
}

# ── Installer EC2 Instance ───────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key material for the EC2 key pair (also used for OpenShift nodes)"
  type        = string
}

variable "installer_ami" {
  description = "AMI ID for the installer / mirror-registry EC2 instance. Leave empty to auto-detect the latest RHEL 9 AMI in the region."
  type        = string
  default     = ""
}

variable "installer_instance_type" {
  description = "EC2 instance type for the installer instance"
  type        = string
  default     = "t2.large"
}

variable "installer_disk_size" {
  description = "Root volume size in GB for the installer instance"
  type        = number
  default     = 100
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key for connecting to the installer EC2 (used in generated Ansible inventory)"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "hcp_workaround_enabled" {
  description = "Enable HCP workaround to mirror additional images (cluster-api, capi-provider) for disconnected HCP."
  type        = bool
  default     = false
}

variable "olm_suppress_default_catalogs" {
  description = "Suppress community-operators and redhat-marketplace OLM catalogs on HCP clusters"
  type        = bool
  default     = false
}