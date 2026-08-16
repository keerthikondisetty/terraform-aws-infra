variable "name" {
  description = "Name prefix for every resource in the VPC."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "name must be lowercase alphanumeric with hyphens, starting with a letter."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. A /16 leaves room for the /24 subnets carved out of it."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "The VPC needs at least a /20 to fit the subnets this module creates."
  }
}

variable "az_count" {
  description = "Availability zones to spread across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "Use at least 2 AZs; a single-AZ deployment fails entirely during a zonal incident."
  }
}

variable "single_nat_gateway" {
  description = <<-DESC
    One NAT gateway for the whole VPC instead of one per AZ. Saves roughly
    $33/month per AZ and gives up the redundancy: losing the NAT's AZ takes
    outbound connectivity from every other AZ too. Fine for dev, wrong for
    production.
  DESC
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to everything in the module."
  type        = map(string)
  default     = {}
}
