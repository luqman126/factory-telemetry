# ============================================================
# infra/terraform/outputs.tf
# Output setelah terraform apply — informasi penting
# ============================================================

output "vpc_id" {
  description = "ID VPC yang dibuat"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID Public Subnet"
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID Private Subnet"
  value       = aws_subnet.private.id
}

output "applayer_public_ip" {
  description = "Public IP dari applayer (Bastion Host)"
  value       = aws_instance.applayer.public_ip
}

output "applayer_private_ip" {
  description = "Private IP dari applayer"
  value       = aws_instance.applayer.private_ip
}

output "datalayer_1_private_ip" {
  description = "Private IP dari datalayer-1 (DB Primary)"
  value       = aws_instance.datalayer_primary.private_ip
}

output "datalayer_2_private_ip" {
  description = "Private IP dari datalayer-2 (DB Replica)"
  value       = aws_instance.datalayer_replica.private_ip
}

output "worker_sg_id" {
  description = "Security Group ID untuk ephemeral Spark worker"
  value       = aws_security_group.worker.id
}

output "worker_subnet_id" {
  description = "Subnet ID untuk ephemeral Spark worker"
  value       = aws_subnet.private.id
}

output "iam_instance_profile_name" {
  description = "IAM Instance Profile name untuk worker"
  value       = aws_iam_instance_profile.applayer.name
}

# ---- Summary ----
output "connection_info" {
  description = "Ringkasan koneksi SSH ke environment ini"
  value = <<-EOT

    ============================================
    ${upper(var.environment)} Environment Ready!
    ============================================
    Bastion (applayer):  ssh ec2-user@${aws_instance.applayer.public_ip}
    DB Primary:          ssh -J ec2-user@${aws_instance.applayer.public_ip} ec2-user@${aws_instance.datalayer_primary.private_ip}
    DB Replica:          ssh -J ec2-user@${aws_instance.applayer.public_ip} ec2-user@${aws_instance.datalayer_replica.private_ip}
    ============================================

  EOT
}
