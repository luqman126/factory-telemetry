# ============================================================
# VARIABLES FOR STAGING ENVIRONMENT
# ============================================================

# Nama environment
environment = "staging"

# AWS Region
aws_region = "ap-southeast-1"

# Project prefix
project_name = "iot-bigdata"

# VPC & Subnet CIDR (Menggunakan block 10.1.x.x untuk Staging)
vpc_cidr            = "10.1.0.0/16"
public_subnet_cidr  = "10.1.1.0/24"
private_subnet_cidr = "10.1.2.0/24"
availability_zone   = "ap-southeast-1b"

# Compute Config (Menggunakan instance type t3.small yang murah untuk Staging)
applayer_instance_type  = "t3.small"
datalayer_instance_type = "t3.small"
ebs_volume_size         = 30

# ---- Rincian AMI & Key Pair (SESUAIKAN DENGAN AKUN AWS ANDA) ----

# Custom AMI ID for applayer nodes
applayer_ami_id = "ami-06300b37dd6a8f1ce"

# Custom AMI ID for database nodes
datalayer_ami_id = "ami-0057a08287089dcfb"

# Custom AMI ID for Spark Worker nodes (Pre-installed Java 21 & Spark 3.5.8)
worker_ami_id = "ami-03256949a823ccf8b"

# Nama EC2 Key Pair yang sudah terdaftar di AWS Console region ap-southeast-1
# Contoh: "iot-worker-key" atau key pair lain milik Anda
key_pair_name = "iot-bigdata-key"

# ---- Dynamic logging system ---- 
log_level = "INFO"