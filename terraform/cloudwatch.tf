# Log groups for the container and Jenkins logs.

locals {
  log_groups = [
    "/weather-app/web",
    "/weather-app/nginx",
    "/jenkins/system",
  ]
}

resource "aws_cloudwatch_log_group" "app" {
  for_each = toset(local.log_groups)

  name = each.value
  retention_in_days = 14
}