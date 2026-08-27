output "monitoring_public_ip" {
  description = "Public IP of the monitoring host"
  value       = module.monitoring_server.public_ip
}

output "monitoring_private_ip" {
  description = "Private IP. This is the address that must appear in the app's nginx allow rule."
  value       = module.monitoring_server.private_ip
}

output "monitoring_url" {
  description = "nginx entry point. /prometheus and /grafana live behind basic auth."
  value       = "http://${module.monitoring_server.public_ip}"
}

output "ssh_monitoring" {
  description = "Ready-to-paste SSH command (uses the CI/CD stack's key)"
  value       = "ssh -i ../../jenkins-cicd-lab/terraform/cicd-key.pem ec2-user@${module.monitoring_server.public_ip}"
}

output "admin_cidr_in_use" {
  description = "The CIDR currently permitted to reach SSH and the UIs"
  value       = local.admin_cidr
}

# --- discovered from the CI/CD stack ---------------------------------------

output "vpc_id" {
  description = "VPC this stack deployed into, discovered by tag"
  value       = data.aws_vpc.cicd.id
}

output "vpc_cidr" {
  description = "VPC CIDR — the range the app and Jenkins security groups allow scraping from"
  value       = local.vpc_cidr
}

# --- security services ------------------------------------------------------

output "cloudtrail_bucket" {
  description = "S3 bucket holding CloudTrail logs"
  value       = aws_s3_bucket.cloudtrail.id
}

output "cloudtrail_name" {
  description = "Name of the trail"
  value       = aws_cloudtrail.main.name
}

output "guardduty_detector_id" {
  description = "Detector ID — needed for `aws guardduty create-sample-findings`"
  value       = aws_guardduty_detector.main.id
}

output "log_groups" {
  description = "CloudWatch log groups receiving container and Jenkins logs"
  value       = [for g in aws_cloudwatch_log_group.app : g.name]
}