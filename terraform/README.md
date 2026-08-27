# Terraform — observability & security

Creates the monitoring host and enables the two AWS security services. It
deploys **into the network the CI/CD stack already created**, without sharing
state with it.

```
providers.tf     aws + http, pinned to the sandbox-user profile
variables.tf     every knob, all with working defaults
data.tf          finds the existing VPC/subnet by tag; detects your public IP
monitoring.tf    security group + the monitoring EC2 instance
iam.tf           instance role for shipping logs to CloudWatch
cloudtrail.tf    trail + S3 bucket with encryption, versioning, lifecycle
guardduty.tf     the detector
outputs.tf       IPs, URLs, bucket name, detector ID
```

## Usage

```bash
terraform init
terraform plan          # expect ~15 resources to add
terraform apply

terraform output -raw monitoring_private_ip   # goes in the app's nginx allow rule
terraform output -raw monitoring_url
```

## How it links to the CI/CD stack

There is **no** `terraform_remote_state` and no hardcoded IDs. `data.tf` finds
the VPC and subnet by their `Project` tag:

```hcl
data "aws_vpc" "cicd" {
  filter {
    name   = "tag:Project"
    values = [var.cicd_project_tag]   # "jenkins-cicd-lab"
  }
}
```

So the coupling between the two repositories is one tag string. If the lookup
fails, the CI/CD stack isn't deployed — apply that one first.

The monitoring instance reuses the CI/CD stack's **key pair** by name, so one
private key opens all three hosts and Ansible needs no per-host key config.
The trade-off — one key compromised means all three hosts compromised — is
noted in `variables.tf`.

## Notes

**The monitoring SG opens only 22 and 80**, both to your detected public IP.
Prometheus' own port 9090 and Grafana's 3000 are never exposed: nginx on the
same host proxies to them over the Docker network. This matters because
**Prometheus has no authentication of its own** — anyone who reaches 9090 can
read every metric and query the API.

**`admin_cidr` defaults to auto-detection** via `checkip.amazonaws.com`, the
same pattern as the CI/CD stack. If your ISP rotates your address you will lose
access until the next `apply`; pin it in `terraform.tfvars` to avoid that.

**The S3 bucket has `force_destroy = true`** so `terraform destroy` works during
the lab. In anything real that should be `false` — audit logs should not be
trivially destroyable.

**GuardDuty will find nothing in a clean account.** Generate labelled samples
for evidence; the command is in the comment at the bottom of `guardduty.tf`.

## Cost

The instance is ~$15/month. CloudTrail's first management-event trail is free.
GuardDuty is free for the first 30 days, then billed on event volume. S3 storage
for a few days of trail logs is pennies. `terraform destroy` when finished.
