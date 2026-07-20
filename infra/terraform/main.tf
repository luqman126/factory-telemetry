# ============================================================
# infra/terraform/main.tf
# Provider AWS dan konfigurasi Terraform
# ============================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State disimpan lokal (akan migrasi ke S3 backend nanti)
  # backend "s3" { ... }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "iot-bigdata"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
