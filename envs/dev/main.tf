/**
 * The dev environment: three modules wired together.
 *
 * This file is deliberately boring. All the decisions live in the modules;
 * an environment is just a set of choices about cost and durability, and
 * every one of them is visible here rather than buried.
 */

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State in S3 with native locking. Local state means the first person to run
  # apply from a different laptop destroys what the second one built.
  #
  # Configured with -backend-config at init so the bucket name is not
  # hardcoded per environment. See README.
  backend "s3" {
    key          = "dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  name = "demo-dev"

  tags = {
    Environment = "dev"
    Project     = "devops-demo-app"
    ManagedBy   = "opentofu"
    Repository  = "terraform-aws-infra"
  }
}

module "network" {
  source = "../../modules/network"

  name     = local.name
  vpc_cidr = "10.20.0.0/16"
  az_count = 2

  # Dev accepts the single point of failure to save about $33/month.
  # Production sets this false.
  single_nat_gateway = true

  tags = local.tags
}

module "web" {
  source = "../../modules/web"

  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids

  certificate_arn   = var.certificate_arn
  access_log_bucket = var.access_log_bucket
  app_image         = var.app_image
  db_secret_arn     = module.database.secret_arn

  instance_type = "t3.small"
  min_size      = 2
  max_size      = 4

  # Off in dev so the environment can actually be torn down at the end of the
  # day. Anything holding real traffic leaves it on.
  deletion_protection = false

  tags = local.tags
}

module "database" {
  source = "../../modules/database"

  name                  = local.name
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  app_security_group_id = module.web.app_security_group_id

  instance_class = "db.t4g.micro"

  # No standby in dev. A dev outage costs an afternoon; the standby costs
  # every month.
  multi_az            = false
  deletion_protection = false

  # Still backed up. "It is only dev" is what people say right up until
  # somebody has spent two weeks building test data in it.
  backup_retention_days = 7

  tags = local.tags
}
