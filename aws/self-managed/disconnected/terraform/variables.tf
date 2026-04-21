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
  description = "List of AWS services to create Interface VPC endpoints for"
  type        = list(string)
  default     = ["ec2", "sts", "elasticloadbalancing", "ecr.api", "ecr.dkr"]
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

# ── Installer EC2 Instance ───────────────────────────────────────────────────

variable "ssh_public_key" {
  description = "SSH public key material for the EC2 key pair (also used for OpenShift nodes)"
  type        = string
}

variable "installer_ami" {
  description = "AMI ID for the installer / mirror-registry EC2 instance"
  type        = string
  default     = "ami-04698733964af06d5"
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
