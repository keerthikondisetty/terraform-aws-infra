output "vpc_id" {
  description = "The VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "The VPC CIDR, for security group rules that need to allow the whole VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnets, for load balancers."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets, for application instances and databases."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "The AZs actually used."
  value       = local.azs
}
