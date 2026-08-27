variable "region" {
  description = "AWS region. Must match the region the CI/CD stack was deployed to."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "Named profile in ~/.aws/credentials"
  type        = string
  default     = "sandbox-user"
}

variable "project" {
  description = "Prefix for resource names created by this repository"
  type        = string
  default     = "obs"
}

# --- linking to the existing CI/CD stack ------------------------------------

variable "cicd_project_tag" {
  description = <<-EOT
    The Project tag the CI/CD stack applies to its resources. Used by data
    sources to find the existing VPC and subnet, so this repository never
    hardcodes an ID and never needs access to the other stack's state.
  EOT
  type        = string
  default     = "jenkins-cicd-lab"
}

variable "key_name" {
  description = <<-EOT
    Name of the EXISTING AWS key pair to attach to the monitoring instance.
    Deliberately reuses the CI/CD stack's key so a single private key opens all
    three hosts and Ansible needs no per-host key configuration.
    Trade-off: one key compromised means all three hosts compromised.
  EOT
  type        = string
  default     = "cicd-key"
}

# --- monitoring instance ----------------------------------------------------

variable "instance_type" {
  description = <<-EOT
    Prometheus holds its recent series in memory and Grafana is a Go binary, so
    2 GB is comfortable for ~10 targets at a 15s scrape interval.
    Note: t3.micro's 1 GB would also put /tmp (a tmpfs at 50% of RAM) at 512 MB.
  EOT
  type        = string
  default     = "t3.small"
}

variable "root_volume_size" {
  description = "Root volume in GB. Prometheus' TSDB grows with retention."
  type        = number
  default     = 20
}

variable "ami_name_filter" {
  description = "Pinned to the standard AL2023 AMI. A looser filter matches the ECS/Neuron variants, which carry 30 GB snapshots."
  type        = string
  default     = "al2023-ami-2023.*-kernel-6.1-x86_64"
}

variable "admin_cidr" {
  description = <<-EOT
    Who may reach SSH and the monitoring UIs. Leave null to detect your current
    public IP automatically (see locals in monitoring.tf). Set explicitly to
    pin it, e.g. "41.75.10.20/32".
  EOT
  type        = string
  default     = null
}

# --- CloudTrail -------------------------------------------------------------

variable "cloudtrail_retention_days" {
  description = "Days before CloudTrail objects are deleted from S3"
  type        = number
  default     = 365
}

variable "tags" {
  description = "Default tags applied to everything this repository creates"
  type        = map(string)
  default = {
    Project     = "weather-observability"
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}
