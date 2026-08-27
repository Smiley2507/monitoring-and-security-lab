

data "aws_vpc" "cicd" {
  filter {
    name   = "tag:Project"
    values = [var.cicd_project_tag]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.cicd.id]
  }

  filter {
    name   = "tag:Project"
    values = [var.cicd_project_tag]
  }
}

# The CI/CD stack creates exactly one public subnet.
data "aws_subnet" "public" {
  id = one(data.aws_subnets.public.ids)
}

# Account ID, used to build a globally-unique S3 bucket name for CloudTrail.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}


data "http" "my_ip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = coalesce(
    var.admin_cidr,
    try("${trimspace(data.http.my_ip[0].response_body)}/32", null)
  )

  vpc_cidr = data.aws_vpc.cicd.cidr_block
}
