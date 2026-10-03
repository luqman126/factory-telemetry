# ============================================================
# infra/terraform/variables.tf
# Input variables — default values for Production,
# overridden via .tfvars for Staging
# ============================================================

# ---- General ----
variable "environment" {
  description = "Environment name (staging / production)"
  type        = string
  default     = "staging"
}

variable "aws_region" {
  description = "AWS deployment region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "iot-bigdata"
}

variable "domain_name" {
  description = "Domain name for SSL certificates and DNS"
  type        = string
  default     = "chescloud.my.id"
}

# ---- Network ----
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.1.0.0/16" # Staging uses 10.1.x, Production uses 10.0.x
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.1.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for private subnet"
  type        = string
  default     = "10.1.2.0/24"
}

variable "availability_zone" {
  description = "Availability Zone for subnets"
  type        = string
  default     = "ap-southeast-1b"
}

# ---- Compute ----
variable "applayer_instance_type" {
  description = "EC2 instance type for applayer"
  type        = string
  default     = "t3.small" # Production: c7i-flex.large
}

variable "datalayer_instance_type" {
  description = "EC2 instance type for datalayer"
  type        = string
  default     = "t3.small"
}

variable "applayer_ami_id" {
  description = "Custom AMI ID for applayer nodes (Base RPM packages + Tailscale + Certbot + Cloudflared CLI + Alloy Agent)"
  type        = string
}

variable "datalayer_ami_id" {
  description = "Custom AMI ID for database nodes (Postgresql + TimescaleDB + Alloy Agent)"
  type        = string
}

variable "worker_ami_id" {
  description = "Custom AMI ID for Spark Worker (Java 21 + Spark pre-installed)"
  type        = string
}

variable "key_pair_name" {
  description = "EC2 Key Pair name for SSH access"
  type        = string
}

variable "ebs_volume_size" {
  description = "EBS root volume size in GB"
  type        = number
  default     = 30
}

# ---- Database Credentials ----
# All values must be supplied via secrets.auto.tfvars or TF_VAR_xxx
# No hardcoded defaults to comply with ISO 27001 (credential non-disclosure)
variable "db_name" {
  description = "PostgreSQL database name"
  type        = string
}

variable "db_user" {
  description = "PostgreSQL username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "PostgreSQL password"
  type        = string
  sensitive   = true
}

# ---- MQTT Credentials ----
variable "mqtt_user" {
  description = "MQTT broker username"
  type        = string
  sensitive   = true
}

variable "mqtt_password" {
  description = "MQTT broker password"
  type        = string
  sensitive   = true
}

# ---- Grafana Credentials ----
variable "grafana_admin_user" {
  description = "Grafana admin username"
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}

# ---- Telegram Configs ----
variable "telegram_bot_token_iot" {
  description = "Telegram Bot Token for IoT alerts"
  type        = string
  sensitive   = true
  default     = ""
}

variable "telegram_chat_id_iot" {
  description = "Telegram Chat ID for IoT alerts"
  type        = string
  default     = ""
}

variable "telegram_bot_token_server" {
  description = "Telegram Bot Token for server alerts"
  type        = string
  sensitive   = true
  default     = ""
}

variable "telegram_chat_id_server" {
  description = "Telegram Chat ID for server alerts"
  type        = string
  default     = ""
}

# ---- Dynamic Provisioning Credentials ---- 
variable "cloudflare_api_token" {
  description = "Cloudflare API Token for Let's Encrypt Certbot DNS challenge"
  type        = string
  sensitive   = true
}

variable "tailscale_auth_key" {
  description = "Tailscale Auth Key for automated VPN node registraion"
  type        = string
  sensitive   = true
}

variable "cloudflare_tunnel_token" {
  description = "Cloudflare Tunnel Token for remote secure access to Grafana (Optional)"
  type        = string
  sensitive   = true
  default     = ""
}

# ---- Dynamic logging system ---- 
variable "log_level" {
  description = "Logging level configuration (DEBUG / INFO / WARNING / ERROR)"
  type        = string
  default     = "INFO"
}