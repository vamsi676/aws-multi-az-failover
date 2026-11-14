data "aws_region" "current" {}

locals {
  # Two single-instance ASGs, one AZ each. a = active, b = standby.
  asgs = {
    a = { subnet_id = var.subnet_a_id, desired = 1 }
    b = { subnet_id = var.subnet_b_id, desired = 0 }
  }
}

resource "aws_launch_template" "this" {
  name        = "${var.name_prefix}-lt"
  description = "Taskboard host: AL2023, nginx, python3.11, CodeDeploy agent"

  # Resolved by EC2 at every launch, so a new AMI release causes no Terraform drift.
  image_id               = "resolve:ssm:${var.ami_ssm_parameter}"
  instance_type          = var.instance_type
  update_default_version = true

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    region     = data.aws_region.current.region
    table_name = var.table_name
  }))

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  # IMDSv2 only; hop limit 1 because nothing runs in containers.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Public IP is needed to reach SSM/CodeDeploy/S3 without a NAT Gateway.
  # Inbound is still only port 80 from the NLB security group.
  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [var.instance_sg_id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-app"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.name_prefix}-app"
    }
  }
}

resource "aws_autoscaling_group" "this" {
  for_each = local.asgs

  name                = "${var.name_prefix}-asg-${each.key}"
  min_size            = 0
  max_size            = 1
  desired_capacity    = each.value.desired
  vpc_zone_identifier = [each.value.subnet_id]
  target_group_arns   = [var.target_group_arn]

  # EC2 (not ELB): the ASG must NOT replace an instance whose app is down,
  # otherwise the failover would never trigger.
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-app-${each.key}"
    propagate_at_launch = true
  }

  lifecycle {
    # Lambdas change desired capacity at runtime during failover/failback.
    ignore_changes = [desired_capacity]
  }
}
