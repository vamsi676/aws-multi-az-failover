data "aws_region" "current" {}

locals {
  # { "us-east-1a" = "10.20.1.0/24", "us-east-1b" = "10.20.2.0/24" }
  subnets = zipmap(var.azs, var.public_subnet_cidrs)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Take over the default SG and leave it with no rules, so nothing uses it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-unused"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# Public subnets (no NAT Gateway, to save cost). Public IPs are assigned by the
# launch template, not by the subnet.
resource "aws_subnet" "public" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${substr(each.key, -2, 2)}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Free gateway endpoint: DynamoDB traffic stays on the AWS network.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]

  tags = {
    Name = "${var.name_prefix}-dynamodb-endpoint"
  }
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------
resource "aws_security_group" "nlb" {
  name        = "${var.name_prefix}-nlb-sg"
  description = "NLB: HTTP from the allowed CIDR only"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-nlb-sg"
  }
}

resource "aws_security_group" "instance" {
  name        = "${var.name_prefix}-instance-sg"
  description = "App instances: HTTP from the NLB only, HTTPS out"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-instance-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_http_from_allowed" {
  security_group_id = aws_security_group.nlb.id
  description       = "HTTP from allowed CIDR"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = var.allowed_cidr
}

# Traffic and health checks from the NLB to the instances.
resource "aws_vpc_security_group_egress_rule" "nlb_to_instances" {
  security_group_id            = aws_security_group.nlb.id
  description                  = "HTTP to app instances"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.instance.id
}

resource "aws_vpc_security_group_ingress_rule" "instance_http_from_nlb" {
  security_group_id            = aws_security_group.instance.id
  description                  = "HTTP from the NLB only"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.nlb.id
}

# SSM, CodeDeploy, S3, DynamoDB and dnf repos are all HTTPS.
resource "aws_vpc_security_group_egress_rule" "instance_https_out" {
  security_group_id = aws_security_group.instance.id
  description       = "HTTPS to AWS APIs and package repos"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
