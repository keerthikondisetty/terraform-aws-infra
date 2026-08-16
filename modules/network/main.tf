/**
 * A VPC with public and private subnets across two availability zones.
 *
 * The shape almost every AWS environment ends up with, and the one worth being
 * able to draw on a whiteboard: load balancers in public subnets, application
 * and database in private ones, outbound internet via NAT.
 */

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Two AZs, not one. A single-AZ deployment fails entirely when AWS has a
  # zonal incident, and those happen more often than region-wide ones.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carved deterministically out of the VPC range so the layout is predictable
  # and no two subnets can be given overlapping CIDRs by hand.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 100)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Every VPC is created with a default security group that allows all traffic
# between anything attached to it. Nothing here uses it, but an instance
# launched without an explicit group lands in it, so it is worth emptying.
# Declaring it with no rules does exactly that -- it cannot be deleted.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-do-not-use" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Off by default. Anything that needs to be reachable gets an address from a
  # load balancer; an instance that auto-assigns a public IP is one firewall
  # rule away from being on the internet by accident.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

# One NAT gateway, or one per AZ.
#
# This is the cost decision in the module. A NAT gateway is about $33/month
# plus data processing, so one per AZ triples that. Single is right for dev;
# production wants one per AZ, because with a single NAT the loss of its AZ
# takes outbound connectivity away from every other AZ too.
resource "aws_eip" "nat" {
  count = var.single_nat_gateway ? 1 : var.az_count

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = var.single_nat_gateway ? 1 : var.az_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet, so each AZ can point at its own NAT when
# there is more than one. A single shared table would send everything through
# one AZ and quietly undo the redundancy you paid for.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
  }

  tags = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Flow logs. The first thing anybody asks for after a security incident, and
# the thing nobody has enabled beforehand.
resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow.arn

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_cloudwatch_log_group" "flow" {
  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = aws_kms_key.flow.arn

  tags = var.tags
}

resource "aws_kms_key" "flow" {
  description             = "Encrypts VPC flow logs for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.flow_key.json

  tags = var.tags
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "flow_key" {
  #checkov:skip=CKV_AWS_109:Key administration has to live somewhere. Without the root grant the key is orphaned and only AWS support can recover it.
  #checkov:skip=CKV_AWS_111:Same statement -- the documented way to keep a KMS key administrable.
  #checkov:skip=CKV_AWS_356:kms:* on "*" inside a key policy scopes to this key alone; the wildcard is the only form the API accepts.

  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc/${var.name}/flow-logs"]
    }
  }
}

resource "aws_iam_role" "flow" {
  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role_policy" "flow" {
  name = "${var.name}-flow-logs"
  role = aws_iam_role.flow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow.arn}:*"
    }]
  })
}
