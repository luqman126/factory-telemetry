# ============================================================
# infra/terraform/secrets.tf
# SSM Parameter Store configuration for Secrets & Configs
# ============================================================

# Prefix path helper: /${var.project_name}/${var.environment}/

# ---- Database config ----
resource "aws_ssm_parameter" "postgres_db" {
  name        = "/${var.project_name}/${var.environment}/POSTGRES_DB"
  type        = "String"
  value       = var.db_name
  description = "Database name for TimescaleDB"
}

resource "aws_ssm_parameter" "postgres_user" {
  name        = "/${var.project_name}/${var.environment}/POSTGRES_USER"
  type        = "String"
  value       = var.db_user
  description = "Database user for TimescaleDB"
}

resource "aws_ssm_parameter" "postgres_password" {
  name        = "/${var.project_name}/${var.environment}/POSTGRES_PASSWORD"
  type        = "SecureString"
  value       = var.db_password
  description = "Database password for TimescaleDB"
}

resource "aws_ssm_parameter" "postgres_host" {
  name        = "/${var.project_name}/${var.environment}/POSTGRES_HOST"
  type        = "String"
  value       = aws_instance.datalayer_primary.private_ip
  description = "Database primary private IP address"
}

resource "aws_ssm_parameter" "postgres_port" {
  name        = "/${var.project_name}/${var.environment}/POSTGRES_PORT"
  type        = "String"
  value       = "5432"
  description = "Database connection port"
}

resource "aws_ssm_parameter" "postgres_host_replica" {
  name        = "/${var.project_name}/${var.environment}/POSTGRES_HOST_REPLICA"
  type        = "String"
  value       = aws_instance.datalayer_replica.private_ip
  description = "Database replica private IP address"
}

# ---- MQTT Config ----
resource "aws_ssm_parameter" "mqtt_broker_host" {
  name        = "/${var.project_name}/${var.environment}/MQTT_BROKER_HOST"
  type        = "String"
  value       = "localhost"
  description = "MQTT broker host for backend"
}

resource "aws_ssm_parameter" "mqtt_broker_port" {
  name        = "/${var.project_name}/${var.environment}/MQTT_BROKER_PORT"
  type        = "String"
  value       = "1883"
  description = "MQTT broker port for backend"
}

resource "aws_ssm_parameter" "mqtt_topic_prefix" {
  name        = "/${var.project_name}/${var.environment}/MQTT_TOPIC_PREFIX"
  type        = "String"
  value       = "iot/sensor"
  description = "MQTT topic prefix for messages"
}

resource "aws_ssm_parameter" "mqtt_user" {
  name        = "/${var.project_name}/${var.environment}/MQTT_USER"
  type        = "String"
  value       = var.mqtt_user
  description = "MQTT broker username"
}

resource "aws_ssm_parameter" "mqtt_password" {
  name        = "/${var.project_name}/${var.environment}/MQTT_PASSWORD"
  type        = "SecureString"
  value       = var.mqtt_password
  description = "MQTT broker password"
}

# ---- Grafana Config ----
resource "aws_ssm_parameter" "grafana_admin_user" {
  name        = "/${var.project_name}/${var.environment}/GRAFANA_ADMIN_USER"
  type        = "String"
  value       = var.grafana_admin_user
  description = "Grafana admin username"
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name        = "/${var.project_name}/${var.environment}/GRAFANA_ADMIN_PASSWORD"
  type        = "SecureString"
  value       = var.grafana_admin_password
  description = "Grafana admin password"
}

# ---- AWS Region & S3 ----
resource "aws_ssm_parameter" "aws_region" {
  name        = "/${var.project_name}/${var.environment}/AWS_REGION"
  type        = "String"
  value       = var.aws_region
  description = "AWS deployment region"
}

resource "aws_ssm_parameter" "s3_bucket" {
  name        = "/${var.project_name}/${var.environment}/S3_BUCKET"
  type        = "String"
  value       = "${var.project_name}-datalake-${var.environment}"
  description = "AWS S3 data lake bucket name"
}

# ---- Spark Config ----
resource "aws_ssm_parameter" "spark_master_url" {
  name        = "/${var.project_name}/${var.environment}/SPARK_MASTER_URL"
  type        = "String"
  value       = "spark://${aws_instance.applayer.private_ip}:7077"
  description = "Spark Master URL connection endpoint"
}

# ---- Telegram Alerting ----
resource "aws_ssm_parameter" "telegram_bot_token_iot" {
  name        = "/${var.project_name}/${var.environment}/TELEGRAM_BOT_TOKEN_IOT"
  type        = "SecureString"
  value       = var.telegram_bot_token_iot != "" ? var.telegram_bot_token_iot : "dummy_token"
  description = "Telegram bot token for IoT alarms"
}

resource "aws_ssm_parameter" "telegram_chat_id_iot" {
  name        = "/${var.project_name}/${var.environment}/TELEGRAM_CHAT_ID_IOT"
  type        = "String"
  value       = var.telegram_chat_id_iot != "" ? var.telegram_chat_id_iot : "dummy_chat_id"
  description = "Telegram chat ID for IoT alarms"
}

resource "aws_ssm_parameter" "telegram_bot_token_server" {
  name        = "/${var.project_name}/${var.environment}/TELEGRAM_BOT_TOKEN_SERVER"
  type        = "SecureString"
  value       = var.telegram_bot_token_server != "" ? var.telegram_bot_token_server : "dummy_token"
  description = "Telegram bot token for server health alarms"
}

resource "aws_ssm_parameter" "telegram_chat_id_server" {
  name        = "/${var.project_name}/${var.environment}/TELEGRAM_CHAT_ID_SERVER"
  type        = "String"
  value       = var.telegram_chat_id_server != "" ? var.telegram_chat_id_server : "dummy_chat_id"
  description = "Telegram chat ID for server health alarms"
}

# ---- External/Dynamic Credentials (Managed via local-bootstrap.sh) ----
resource "aws_ssm_parameter" "cloudflare_api_token" {
  name        = "/${var.project_name}/${var.environment}/CLOUDFLARE_API_TOKEN"
  type        = "SecureString"
  value       = "placeholder_do_not_delete"
  description = "Cloudflare API token for Certbot DNS challenge"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "tailscale_auth_key" {
  name        = "/${var.project_name}/${var.environment}/TAILSCALE_AUTH_KEY"
  type        = "SecureString"
  value       = "placeholder_do_not_delete"
  description = "Tailscale auth key for VPN registration"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "cloudflare_tunnel_token" {
  name        = "/${var.project_name}/${var.environment}/CLOUDFLARE_TUNNEL_TOKEN"
  type        = "SecureString"
  value       = "placeholder_do_not_delete"
  description = "Cloudflare Tunnel Token for Grafana remote access"

  lifecycle {
    ignore_changes = [value]
  }
}

# ---- Spark Ephemeral Worker SSM Parameters ----
resource "aws_ssm_parameter" "worker_subnet_id" {
  name        = "/${var.project_name}/${var.environment}/WORKER_SUBNET_ID"
  type        = "String"
  value       = aws_subnet.private.id
  description = "Subnet ID for ephemeral Spark worker"
}

resource "aws_ssm_parameter" "worker_sg_id" {
  name        = "/${var.project_name}/${var.environment}/WORKER_SG_ID"
  type        = "String"
  value       = aws_security_group.worker.id
  description = "Security Group ID for ephemeral Spark worker"
}

resource "aws_ssm_parameter" "worker_iam_profile" {
  name        = "/${var.project_name}/${var.environment}/WORKER_IAM_PROFILE"
  type        = "String"
  value       = aws_iam_instance_profile.applayer.name
  description = "IAM Instance Profile name for ephemeral Spark worker"
}

