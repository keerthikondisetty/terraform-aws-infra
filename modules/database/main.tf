/**
 * A Postgres instance, reachable only from the application security group.
 *
 * The password is generated here and stored in Secrets Manager. It is never
 * a variable, because a variable ends up in a tfvars file, and a tfvars file
 * ends up in git.
 */

resource "random_password" "master" {
  length  = 32
  special = true
  # Characters RDS rejects in a master password. Finding this out from a
  # failed apply after a fifteen minute create is a memorable afternoon.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "Postgres, reachable from the application only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_app" {
  security_group_id = aws_security_group.db.id
  description       = "Postgres from the application security group"

  referenced_security_group_id = var.app_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# No egress rule at all. A database has no reason to open outbound
# connections, and the absence of a rule is the strongest possible statement
# of that.

resource "aws_db_subnet_group" "this" {
  name_prefix = "${var.name}-"
  subnet_ids  = var.private_subnet_ids

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_kms_key" "db" {
  description             = "Encrypts the ${var.name} database and its snapshots"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # Explicit rather than the implicit default, which grants the whole account
  # access through IAM. A key protecting a database should be narrower.
  policy = data.aws_iam_policy_document.db_key.json

  tags = var.tags
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "db_key" {
  #checkov:skip=CKV_AWS_109:Key administration has to live somewhere; without the root grant the key is orphaned.
  #checkov:skip=CKV_AWS_111:Same statement -- the documented way to keep a KMS key administrable.
  #checkov:skip=CKV_AWS_356:kms:* on "*" in a key policy scopes to this key alone; the wildcard is the only accepted form.

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
    sid    = "AllowRDS"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Query logging. Off by default in RDS, and the first thing you want when
# somebody reports "the app got slow last Tuesday".
resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "Logging and statement timeout for ${var.name}"

  # Refuse unencrypted connections outright. Postgres will happily accept
  # plaintext otherwise, and "we assumed the VPC was private" is how database
  # traffic ends up readable to anything else in the VPC.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  # Log anything slower than a second rather than every statement. Logging
  # everything on a busy database costs more in I/O than the queries do.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name}-db"
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_db_instance" "this" {
  identifier = var.name

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 4
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_days
  # Backup window before the maintenance window, so a maintenance-triggered
  # reboot always has a fresh snapshot behind it.
  backup_window      = "03:00-04:00"
  maintenance_window = "Mon:04:30-Mon:05:30"

  copy_tags_to_snapshot = true

  # A final snapshot on destroy. The one time this matters is the time someone
  # runs destroy against the wrong workspace.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  deletion_protection       = var.deletion_protection

  parameter_group_name = aws_db_parameter_group.this.name

  # IAM authentication as well as the password. It lets an application assume
  # a role and request a short-lived token instead of holding a long-lived
  # credential, and costs nothing to leave enabled for whoever wants it.
  iam_database_authentication_enabled = true

  auto_minor_version_upgrade = true
  apply_immediately          = false

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.db.arn
  performance_insights_retention_period = 7

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.monitoring.arn

  tags = var.tags

  lifecycle {
    # The snapshot name contains a timestamp, so it differs on every plan and
    # would otherwise show a permanent diff.
    ignore_changes = [final_snapshot_identifier]
  }
}

resource "aws_iam_role" "monitoring" {
  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_secretsmanager_secret" "db" {
  #checkov:skip=CKV2_AWS_57:Automatic rotation needs a rotation Lambda with network access to the database, which is a larger piece of work than this module covers. IAM authentication is enabled above as the path that avoids a long-lived password entirely; the generated one is the fallback. Rotating it is tracked, not forgotten.
  name_prefix = "${var.name}/database-"
  description = "Connection details for the ${var.name} database"
  kms_key_id  = aws_kms_key.db.arn

  # Zero means "delete immediately", which is what you want when a bad apply
  # leaves a secret name you need to reuse straight away.
  recovery_window_in_days = var.secret_recovery_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.database_name
    url      = "postgresql://${var.master_username}:${urlencode(random_password.master.result)}@${aws_db_instance.this.endpoint}/${var.database_name}"
  })
}
