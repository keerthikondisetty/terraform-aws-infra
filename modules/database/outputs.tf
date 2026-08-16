output "endpoint" {
  description = "Database endpoint, host and port."
  value       = aws_db_instance.this.endpoint
}

output "secret_arn" {
  description = "Secrets Manager ARN holding the connection string. The application reads this at boot."
  value       = aws_secretsmanager_secret.db.arn
}

output "security_group_id" {
  description = "The database security group."
  value       = aws_security_group.db.id
}
