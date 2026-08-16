variable "name" {
  description = "Name for the instance and its supporting resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the DB subnet group."
  type        = list(string)
}

variable "app_security_group_id" {
  description = "The only security group permitted to reach Postgres."
  type        = string
}

variable "engine_version" {
  description = "Postgres major version. Pinned, so a provider upgrade cannot silently move it."
  type        = string
  default     = "17.2"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Storage in GiB. Autoscaling is allowed up to four times this."
  type        = number
  default     = 20
}

variable "database_name" {
  description = "Initial database name."
  type        = string
  default     = "app"
}

variable "master_username" {
  description = "Master username. The password is generated, never passed in."
  type        = string
  default     = "app_admin"
}

variable "multi_az" {
  description = <<-DESC
    Standby in a second AZ. Roughly doubles the cost and is the difference
    between a failover measured in minutes and a restore measured in hours.
    Off for dev, on for anything holding data you would miss.
  DESC
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Automated backup retention. Zero disables backups entirely, which the validation below refuses."
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "Retention of 0 disables automated backups. If that is genuinely intended, say so somewhere more visible than a tfvars file."
  }
}

variable "deletion_protection" {
  description = "Deletion protection on the instance."
  type        = bool
  default     = true
}

variable "secret_recovery_days" {
  description = "Secrets Manager recovery window. 0 deletes immediately, which is useful when a failed apply leaves a name you need to reuse."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to everything in the module."
  type        = map(string)
  default     = {}
}
