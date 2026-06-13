# ============================================================
# infra/terraform/compute.tf
# Compute Layer — EC2 Instances, Elastic IP, and IAM Roles
# ============================================================

# ---- 1. IAM Role & Instance Profile untuk Applayer (dan Worker) ----
# Role ini memungkinkan applayer-1 mengakses S3 dan mendeploy ephemeral workers.
resource "aws_iam_role" "applayer" {
  name = "${var.project_name}-${var.environment}-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-s3-role"
  }
}

# Instance Profile untuk dipasang pada EC2 Instance
resource "aws_iam_instance_profile" "applayer" {
  name = "${var.project_name}-${var.environment}-s3-profile"
  role = aws_iam_role.applayer.name
}

# Single Custom Inline Policy - Menerapkan "Principle of Least Privilege"
resource "aws_iam_role_policy" "least_privilege" {
  name = "${var.project_name}-${var.environment}-least-privilege-policy"
  role = aws_iam_role.applayer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1. ORKESTRASI EC2: Hanya izinkan action yang dibutuhkan oleh run_with_worker.sh
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:TerminateInstances",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      # 2. PASS ROLE: Hanya izinkan me-pass role ini saja ke worker node baru
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.applayer.arn
      },
      # 3. S3 DATA LAKE: Hanya izinkan akses ke bucket milik project ini (staging/prod)
      # Memblokir akses ke bucket lain di luar project untuk keamanan
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = "arn:aws:s3:::${var.project_name}-datalake-*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = "arn:aws:s3:::${var.project_name}-datalake-*/*"
      }
    ]
  })
}

# ---- 2. EC2 Instance: Applayer-1 (Bastion + Apps) ----
# Ditempatkan di Public Subnet agar bisa diakses oleh client / IoT Device
resource "aws_instance" "applayer" {
  ami                  = var.ami_id
  instance_type        = var.applayer_instance_type
  subnet_id            = aws_subnet.public.id
  key_name             = var.key_pair_name
  iam_instance_profile = aws_iam_instance_profile.applayer.name

  vpc_security_group_ids = [
    aws_security_group.applayer.id
  ]

  # Bootstrapping (Otomatisasi instalasi software saat pertama kali server menyala)
  user_data = <<-EOF
              #!/bin/bash
              # 1. Update system & install package dasar
              dnf update -y
              dnf install -y git python3 python3-pip

              # 2. Install & jalankan Docker + Docker Compose v2
              dnf install -y docker
              dnf install -y docker-compose-plugin
              systemctl enable --now docker
              usermod -aG docker ec2-user

              # 3. Install Tailscale
              curl -fsSL https://tailscale.com/install.sh | sh
              systemctl enable --now tailscaled
              EOF

  root_block_device {
    volume_size           = var.ebs_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-applayer-1"
  }
}

# Elastic IP (EIP) untuk Applayer-1
# Menjaga agar IP publik tetap statis saat server reboot / maintenance
resource "aws_eip" "applayer" {
  instance = aws_instance.applayer.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-${var.environment}-applayer-1-eip"
  }
}

# ---- 3. EC2 Instance: Datalayer-1 (PostgreSQL DB Primary) ----
# Ditempatkan di Private Subnet, menggunakan static IP untuk kemudahan replikasi
resource "aws_instance" "datalayer_primary" {
  ami           = var.ami_id
  instance_type = var.datalayer_instance_type
  subnet_id     = aws_subnet.private.id
  key_name      = var.key_pair_name
  private_ip    = cidrhost(var.private_subnet_cidr, 10) # Contoh: 10.1.2.10

  vpc_security_group_ids = [
    aws_security_group.datalayer.id
  ]

  root_block_device {
    volume_size           = var.ebs_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-datalayer-1"
  }
}

# ---- 4. EC2 Instance: Datalayer-2 (PostgreSQL DB Replica) ----
# Ditempatkan di Private Subnet, menggunakan static IP
resource "aws_instance" "datalayer_replica" {
  ami           = var.ami_id
  instance_type = var.datalayer_instance_type
  subnet_id     = aws_subnet.private.id
  key_name      = var.key_pair_name
  private_ip    = cidrhost(var.private_subnet_cidr, 20) # Contoh: 10.1.2.20

  vpc_security_group_ids = [
    aws_security_group.datalayer.id
  ]

  root_block_device {
    volume_size           = var.ebs_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-datalayer-2"
  }
}
