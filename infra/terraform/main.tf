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

  backend "s3" {
    bucket          = "iot-bigdata-terraform-state"
    key             = "staging/terraform.tfstate"
    region          = "ap-southeast-1"
    use_lockfile    = true
    encrypt         = true
  }
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
