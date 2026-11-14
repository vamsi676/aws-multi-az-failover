resource "aws_lb" "this" {
  name               = "${var.name_prefix}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = var.subnet_ids
  # An NLB security group can only be added when the NLB is created.
  security_groups = [var.nlb_sg_id]

  # Either AZ's NLB node can send traffic to the single healthy instance.
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.name_prefix}-nlb"
  }
}

# TCP pass-through on port 80, but an HTTP health check so "healthy" means the app
# answered /healthz with 200, not just that a port is open.
resource "aws_lb_target_group" "this" {
  name                 = "${var.name_prefix}-tg"
  port                 = 80
  protocol             = "TCP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay

  health_check {
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = var.health_check_path
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.name_prefix}-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
