# ============================================================
# infra/terraform/environments/staging.tfvars
# Variabel spesifik untuk Staging Environment
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

# AMI ID Amazon Linux 2023 di Region ap-southeast-1 (Singapore)
# Secara default, ini adalah base AMI AL2023 (bisa disesuaikan jika perlu)
ami_id = "ami-05b741ae2ab9f1742"

# Custom AMI ID untuk Spark Worker (Pre-installed Java 21 & Spark 3.5.8)
# Diambil dari script spark-jobs/run_with_worker.sh
worker_ami_id = "ami-03256949a823ccf8b"

# Nama EC2 Key Pair yang sudah terdaftar di AWS Console region ap-southeast-1
# Contoh: "iot-worker-key" atau key pair lain milik Anda
key_pair_name = "iot-bigdata-key"

# ---- Dynamic logging system ---- 
log_level = "INFO"