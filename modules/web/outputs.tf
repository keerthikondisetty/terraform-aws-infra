output "alb_dns_name" {
  description = "Load balancer DNS name, for the Route 53 alias record."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "Load balancer hosted zone, also for the alias record."
  value       = aws_lb.this.zone_id
}

output "app_security_group_id" {
  description = "Application security group, so the database module can allow it."
  value       = aws_security_group.app.id
}

output "autoscaling_group_name" {
  description = "ASG name, for triggering an instance refresh from CI."
  value       = aws_autoscaling_group.this.name
}
