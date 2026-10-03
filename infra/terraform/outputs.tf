# ============================================================
# infra/terraform/outputs.tf
# Terraform Outputs — key infrastructure attributes
# ============================================================

output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_id" {
  description = "Public Subnet ID"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "Private Subnet ID"
  value       = aws_subnet.private.id
}

output "s3_bucket" {
  description = "Data Lake S3 Bucket name"
  value       = aws_s3_bucket.datalake.id
}

output "applayer_public_ip" {
  description = "Public IPv4 address of applayer (Bastion Host)"
  value       = aws_eip.applayer.public_ip
}

output "applayer_private_ip" {
  description = "Private IPv4 address of applayer"
  value       = aws_instance.applayer.private_ip
}

output "applayer_instance_id" {
  description = "EC2 Instance ID of applayer"
  value       = aws_instance.applayer.id
}

output "datalayer_1_private_ip" {
  description = "Private IPv4 address of datalayer-1 (DB Primary)"
  value       = aws_instance.datalayer_primary.private_ip
}

output "datalayer_2_private_ip" {
  description = "Private IPv4 address of datalayer-2 (DB Replica)"
  value       = aws_instance.datalayer_replica.private_ip
}

output "worker_sg_id" {
  description = "Security Group ID for ephemeral Spark workers"
  value       = aws_security_group.worker.id
}

output "worker_subnet_id" {
  description = "Subnet ID for ephemeral Spark workers"
  value       = aws_subnet.private.id
}

output "iam_instance_profile_name" {
  description = "IAM Instance Profile name for workers"
  value       = aws_iam_instance_profile.applayer.name
}

# ---- Summary ----
output "connection_info" {
  description = "Connection and setup summary for this environment"
  value = <<-EOT

    ============================================
    ${upper(var.environment)} Environment Ready!
    ============================================
    
  EOT
}
