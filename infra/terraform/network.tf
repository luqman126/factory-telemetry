# ============================================================
# infra/terraform/network.tf
# Network Layer — VPC, Subnets, IGW, Route Tables, S3 Endpoint
# Replika topologi Production: 1 Public + 1 Private Subnet
# ============================================================

# ---- VPC ----
# "Gedung" utama tempat semua server tinggal
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

# ---- Subnets ----
# Public Subnet — tempat applayer (bisa akses internet)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.environment}-public-subnet"
  }
}

# Private Subnet — tempat datalayer & worker (TANPA akses internet)
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project_name}-${var.environment}-private-subnet"
  }
}

# ---- Internet Gateway ----
# "Pintu keluar" ke internet, HANYA untuk public subnet
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-igw"
  }
}

# ---- Route Tables ----

# Route table untuk PUBLIC subnet — ada rute ke internet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-public-rt"
  }
}

# Kaitkan route table public ke public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Route table untuk PRIVATE subnet — TIDAK ada rute ke internet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Sengaja TIDAK ada route ke 0.0.0.0/0
  # Private subnet benar-benar terisolasi dari internet

  tags = {
    Name = "${var.project_name}-${var.environment}-private-rt"
  }
}

# Kaitkan route table private ke private subnet
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---- VPC Endpoint untuk S3 (Gateway) ----
# Agar server di private subnet bisa akses S3 TANPA internet
# Biaya: GRATIS
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.private.id,
  ]

  tags = {
    Name = "${var.project_name}-${var.environment}-s3-endpoint"
  }
}
