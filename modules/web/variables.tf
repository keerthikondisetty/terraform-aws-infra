variable "name" {
  description = "Name prefix for the load balancer, ASG and security groups."
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the load balancer."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets for the instances."
  type        = list(string)
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener. Required: there is no HTTP-only mode in this module."
  type        = string
}

variable "access_log_bucket" {
  description = "Existing bucket for load balancer access logs."
  type        = string
}

variable "db_secret_arn" {
  description = "Secrets Manager ARN holding the database connection string."
  type        = string
}

variable "app_image" {
  description = "Container image to run, pinned by digest in anything but dev."
  type        = string
}

variable "app_port" {
  description = "Port the application listens on."
  type        = number
  default     = 8000
}

variable "health_check_path" {
  description = <<-DESC
    Health check path. Point this at readiness, not liveness. The load balancer
    is asking whether the instance can serve traffic, which is a different
    question from whether the process is alive.
  DESC
  type        = string
  default     = "/readyz"
}

variable "instance_type" {
  description = "Instance type for the application."
  type        = string
  default     = "t3.small"
}

variable "min_size" {
  description = "Minimum instances. Two, so a rolling replacement never leaves zero."
  type        = number
  default     = 2

  validation {
    condition     = var.min_size >= 2
    error_message = "Keep at least 2 instances; with 1 there is an outage during every deploy and every AZ event."
  }
}

variable "max_size" {
  description = "Maximum instances."
  type        = number
  default     = 4
}

variable "cpu_target" {
  description = "Target average CPU for the scaling policy."
  type        = number
  default     = 60
}

variable "allowed_cidr" {
  description = "CIDR permitted to reach the load balancer. 0.0.0.0/0 for a public service, deliberately."
  type        = string
  default     = "0.0.0.0/0"
}

variable "deletion_protection" {
  description = "Deletion protection on the load balancer."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to everything in the module."
  type        = map(string)
  default     = {}
}

variable "enable_waf" {
  description = <<-DESC
    Attach a WAF to the load balancer. Roughly $5/month plus per-request
    charges. The rate limit is the part that pays for itself; the managed rule
    groups start in count mode so they cannot break real traffic on day one.
  DESC
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Requests per five minutes from a single IP before it is blocked."
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100
    error_message = "AWS enforces a floor of 100 requests per five minutes on a rate-based rule."
  }
}

variable "waf_log_retention_days" {
  description = "Retention for WAF logs."
  type        = number
  default     = 365
}

variable "waf_log_kms_key_arn" {
  description = "KMS key for the WAF log group. Null uses the CloudWatch default key."
  type        = string
  default     = null
}
