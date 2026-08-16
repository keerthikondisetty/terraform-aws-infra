variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener."
  type        = string
}

variable "access_log_bucket" {
  description = "Existing bucket for load balancer access logs."
  type        = string
}

variable "app_image" {
  description = <<-DESC
    Container image for the application. Pin by digest rather than tag in
    anything that matters: a tag can be moved under you, and then the thing
    running is not the thing you reviewed.
  DESC
  type        = string
  default     = "ghcr.io/keerthikondisetty/devops-demo-app:latest"
}
