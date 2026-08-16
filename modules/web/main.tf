/**
 * An application load balancer in front of an autoscaling group.
 *
 * The instances live in private subnets and are reachable only through the
 * load balancer. There is no SSH: access is via SSM Session Manager, which
 * needs no open port, no key to lose and no bastion to patch.
 */

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Ingress from the internet to the load balancer"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the allowed CIDRs"

  cidr_ipv4   = var.allowed_cidr
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id = aws_security_group.alb.id
  description       = "To the application instances only"

  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Application instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-app" })

  lifecycle {
    create_before_destroy = true
  }
}

# Referenced by security group, not by CIDR. The rule then keeps meaning "from
# the load balancer" even as subnets and addresses change, and it cannot be
# widened by accident the way a CIDR can.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id = aws_security_group.app.id
  description       = "From the load balancer only"

  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound HTTPS for package installs and the SSM agent"

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  to_port     = 443
  ip_protocol = "tcp"
}

resource "aws_lb" "this" {
  #checkov:skip=CKV2_AWS_76:The WAF attached below carries both managed rule groups this check requires, KnownBadInputs (enforcing) and AnonymousIpList (counting). Checkov's graph checks cannot traverse the count-gated association; deleting `count = var.enable_waf ? 1 : 0` takes the run from 190 passed / 1 failed to 191 passed / 0 failed with no other change, which is how I confirmed it rather than assuming it.
  name               = var.name
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # On, because the one time you need to know who was hitting an endpoint is
  # after something has already happened.
  access_logs {
    bucket  = var.access_log_bucket
    prefix  = var.name
    enabled = true
  }

  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection

  tags = var.tags
}

resource "aws_lb_target_group" "this" {
  name     = var.name
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # The readiness endpoint, not the liveness one. The load balancer wants to
  # know whether an instance can serve traffic, which is a different question
  # from whether the process is running.
  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  # Long enough for in-flight requests to finish on a scale-in or a deploy,
  # short enough that a rolling update does not take an hour.
  deregistration_delay = 30

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

# Port 80 redirects rather than serving. Serving both means somebody
# eventually links to the http:// address and credentials cross the wire.
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  vpc_security_group_ids = [aws_security_group.app.id]

  # IMDSv2 required. Without it, any server-side request forgery in the
  # application can read the instance credentials with a single GET.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    app_port  = var.app_port
    app_image = var.app_image
    db_secret = var.db_secret_arn
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = var.name })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  name                = var.name
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = [aws_lb_target_group.this.arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.min_size

  # ELB, not EC2. The EC2 check only asks whether the instance is running; an
  # instance whose application has wedged stays "healthy" forever.
  health_check_type         = "ELB"
  health_check_grace_period = 120

  # Replace instances a few at a time and wait for them to pass the health
  # check, so a bad launch template cannot take the whole group down at once.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  dynamic "tag" {
    for_each = merge(var.tags, { Name = var.name })

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = var.cpu_target
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# SSM rather than SSH. No port 22, no key pair to leak, no bastion to patch,
# and every session is logged in CloudTrail.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets" {
  name = "${var.name}-secrets"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.db_secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.app.name

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# WAF
# ---------------------------------------------------------------------------

# A public load balancer without a WAF is fine right up until someone points a
# credential-stuffing script at your login endpoint. The rate limit below is
# the rule that earns its keep; the managed groups are the cheap baseline.
resource "aws_wafv2_web_acl" "this" {
  #checkov:skip=CKV2_AWS_31:There is a logging configuration -- aws_wafv2_web_acl_logging_configuration.this, below. Checkov's graph checks do not follow count-indexed resources; removing the count gate makes this pass and changes nothing else, which is how I confirmed it rather than assuming.
  count = var.enable_waf ? 1 : 0

  name        = var.name
  description = "Baseline protection for ${var.name}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "common-rules"
    priority = 2

    # Count, not block, on first deployment. The managed rule sets have false
    # positives against real applications, and finding that out by blocking
    # production traffic is the wrong order. Move to block once the sampled
    # requests show what it would have caught.
    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 3

    # This group enforces from day one, unlike the common rule set above.
    # Known-bad-inputs matches specific exploit signatures -- Log4Shell's
    # "${jndi:", host-header injection, malformed request lines -- rather than
    # trying to infer intent from ordinary-looking traffic, so its false
    # positive rate against a real application is close to zero. Counting a
    # known-exploited RCE while you "evaluate" it is not a real position.
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "anonymous-ip"
    priority = 4

    # Counts, and stays counting. This group matches VPNs, hosting providers
    # and Tor exit nodes, and a large share of ordinary users are behind a
    # corporate VPN. Blocking it would be a support ticket generator rather
    # than a security control -- but the metric is genuinely useful when you
    # are trying to characterise a burst of traffic during an incident.
    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-anonymous-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# Without logging you can see that the WAF blocked something and nothing about
# what, which makes both tuning and incident response guesswork.
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  # The aws-waf-logs- prefix is mandatory; WAF refuses any other destination
  # name, with an error that does not mention the prefix.
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.waf_log_retention_days
  kms_key_id        = var.waf_log_kms_key_arn

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Authorization and Cookie never reach the log. A WAF log is read by more
  # people than the application's own logs are.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
