output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "subnet_ids" {
  description = "Map of AZ name -> public subnet ID."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "nlb_sg_id" {
  description = "Security group of the NLB."
  value       = aws_security_group.nlb.id
}

output "instance_sg_id" {
  description = "Security group of the app instances."
  value       = aws_security_group.instance.id
}

output "route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}
