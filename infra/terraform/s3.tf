# ============================================================
# infra/terraform/s3.tf
# S3 Bucket for Data Lake (Parquet telemetry)
# ============================================================

resource "aws_s3_bucket" "datalake" {
  bucket        = "${var.project_name}-datalake-${var.environment}-apse1-944551807382"
  force_destroy = true # Allow bucket deletion including contents on 'terraform destroy'

  tags = {
    Name = "${var.project_name}-datalake-${var.environment}-apse1-944551807382"
  }
}

# Block all public access explicitly for security hardening (Best Practice)
resource "aws_s3_bucket_public_access_block" "datalake" {
  bucket = aws_s3_bucket.datalake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
