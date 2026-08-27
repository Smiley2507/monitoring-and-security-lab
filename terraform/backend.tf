terraform {
  backend "s3" {
    bucket = "devops-lab-tfstate-188776114506"
    key = "monitoring-and-security-lab/terraform.tfstate"
    region = "us-east-1"
    profile = "devops-lab"
    encrypt = true
    use_lockfile = true
  }
}