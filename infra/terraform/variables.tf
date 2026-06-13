# ============================================================
# infra/terraform/variables.tf
# Input variables — nilai default untuk Production,
# override via .tfvars untuk Staging
# ============================================================

# ---- General ----
variable "environment" {
  description = "Nama environment (staging / production)"
  type        = string
  default     = "staging"
}

variable "aws_region" {
  description = "AWS region untuk deploy"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Nama project, dipakai sebagai prefix resource"
  type        = string
  default     = "iot-bigdata"
}

# ---- Network ----
variable "vpc_cidr" {
  description = "CIDR block untuk VPC"
  type        = string
  default     = "10.1.0.0/16" # Staging pakai 10.1.x, Production 10.0.x
}

variable "public_subnet_cidr" {
  description = "CIDR block untuk public subnet"
  type        = string
  default     = "10.1.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block untuk private subnet"
  type        = string
  default     = "10.1.2.0/24"
}

variable "availability_zone" {
  description = "AZ untuk semua subnet"
  type        = string
  default     = "ap-southeast-1b"
}

# ---- Compute ----
variable "applayer_instance_type" {
  description = "Tipe EC2 untuk app layer"
  type        = string
  default     = "t3.small" # Production: c7i-flex.large
}

variable "datalayer_instance_type" {
  description = "Tipe EC2 untuk data layer"
  type        = string
  default     = "t3.small"
}

variable "ami_id" {
  description = "AMI ID Amazon Linux 2023 (region-specific)"
  type        = string
  # Amazon Linux 2023 di ap-southeast-1 — update jika perlu
}

variable "worker_ami_id" {
  description = "Custom AMI ID untuk Spark Worker (Java 21 + Spark pre-installed)"
  type        = string
}

variable "key_pair_name" {
  description = "Nama EC2 Key Pair untuk SSH access"
  type        = string
}

variable "ebs_volume_size" {
  description = "Ukuran EBS root volume (GB)"
  type        = number
  default     = 30
}
