# ============================================================
# infra/terraform/network.tf
# Network Layer — VPC, Subnets, IGW, Route Tables, S3 Endpoint
# Topology replica of Production: 1 Public + 1 Private Subnet
# ============================================================

# ---- VPC ----
# Main VPC housing all project compute resources
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

# ---- Subnets ----
# Public Subnet — hosts applayer (internet-facing)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-${var.environment}-public-subnet"
  }
}

# Private Subnet — hosts datalayer & workers (isolated from direct internet access)
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
# Internet gateway for public subnet inbound/outbound traffic
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-${var.environment}-igw"
  }
}

# ---- Route Tables ----

# Route table for PUBLIC subnet — routes default traffic via IGW
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

# Associate public route table with public subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Route table for PRIVATE subnet — NO internet route
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Deliberately NO route to 0.0.0.0/0
  # Private subnet is completely isolated from the internet

  tags = {
    Name = "${var.project_name}-${var.environment}-private-rt"
  }
}

# Associate private route table with private subnet
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---- VPC Endpoint for S3 (Gateway) ----
# Allows servers in private subnet to access S3 WITHOUT internet egress
# Cost: Free
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
