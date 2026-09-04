module "monitoring_sg" {
  source = "git::https://github.com/Smiley2507/terraform-aws-modules.git//modules/security-group?ref=main"

  name        = "${var.project}-monitoring-sg"
  description = "Monitoring host: SSH and the Prometheus/Grafana UIs, restricted to the operator"
  vpc_id      = data.aws_vpc.cicd.id

  ingress_rules = [
    {
      description = "SSH for Ansible and manual access"
      from_port   = 22
      to_port     = 22
      ip_protocol = "tcp"
      cidr_ipv4   = local.admin_cidr
    },
        {
      description = "Grafana UI. Grafana has its own login."
      from_port   = 3000
      to_port     = 3000
      ip_protocol = "tcp"
      cidr_ipv4   = local.admin_cidr
    },
    {
      description = "Prometheus UI. No auth of its own; access controlled here."
      from_port   = 9090
      to_port     = 9090
      ip_protocol = "tcp"
      cidr_ipv4   = local.admin_cidr
    },
    {
      description = "Jaeger UI. No auth of its own; access controlled here."
      from_port   = 16686
      to_port     = 16686
      ip_protocol = "tcp"
      cidr_ipv4   = local.admin_cidr
    },
    {
      description = "OTLP HTTP span ingest from the app. VPC only."
      from_port   = 4318
      to_port     = 4318
      ip_protocol = "tcp"
      cidr_ipv4   = local.vpc_cidr
    },

  ]
}

module "monitoring_server" {
  source = "git::https://github.com/Smiley2507/terraform-aws-modules.git//modules/ec2-instance?ref=main"

  name                        = "${var.project}-monitoring-server"
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.public.id
  vpc_security_group_ids      = [module.monitoring_sg.security_group_id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  root_volume_size            = var.root_volume_size
  ami_name_filter             = var.ami_name_filter
  ami_owner                   = "amazon"
  ami_id                      = var.ami_id
  iam_instance_profile = aws_iam_instance_profile.monitoring.name
  tags = {
    Role = "monitoring"
  }
}