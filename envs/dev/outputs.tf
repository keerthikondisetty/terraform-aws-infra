output "alb_dns_name" {
  description = "Point a CNAME or Route 53 alias at this."
  value       = module.web.alb_dns_name
}

output "database_secret_arn" {
  description = "Where the application reads its connection string from."
  value       = module.database.secret_arn
}

output "vpc_id" {
  description = "The VPC id."
  value       = module.network.vpc_id
}

output "autoscaling_group_name" {
  description = "For triggering an instance refresh after a new image is published."
  value       = module.web.autoscaling_group_name
}
