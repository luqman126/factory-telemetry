# ============================================================
# infra/terraform/s3.tf
# S3 Bucket untuk Data Lake (Parquet)
# ============================================================

resource "aws_s3_bucket" "datalake" {
  bucket        = "${var.project_name}-datalake-${var.environment}"
  force_destroy = true # Mengizinkan bucket dihapus beserta isinya saat 'terraform destroy'

  tags = {
    Name = "${var.project_name}-datalake-${var.environment}"
  }
}

# Blokir semua akses publik secara eksplisit demi keamanan (Best Practice)
resource "aws_s3_bucket_public_access_block" "datalake" {
  bucket = aws_s3_bucket.datalake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
