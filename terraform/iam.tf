# The monitoring host ships its own container logs to CloudWatch, so it needs
# the same instance profile pattern as the app and Jenkins hosts.
#
# Why a role rather than access keys: an instance profile issues short-lived
# credentials through the instance metadata service. Nothing long-lived is
# written to disk, and revoking access is a policy change rather than a key
# rotation across every host.

resource "aws_iam_role" "monitoring" {
  name = "${var.project}-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "monitoring_logs" {
  name = "${var.project}-monitoring-logs"
  role = aws_iam_role.monitoring.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy",
      ]
      Resource = "arn:aws:logs:${var.region}:*:log-group:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_ssm" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring" {
  name = "${var.project}-monitoring"
  role = aws_iam_role.monitoring.name
}
