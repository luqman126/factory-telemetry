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

resource "aws_iam_role_policy_attachment" "applayer_ssm" {
  role       = aws_iam_role.applayer.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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
          "ec2:DescribeInstances",
          "ec2:CreateTags"
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
      },
      # 4. SECRETS MANAGEMENT: Hanya izinkan membaca secrets untuk environment ini dari SSM
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.project_name}/${var.environment}/*"
      },
      # 5. KMS DECRYPT: Diperlukan untuk mendekripsi SSM SecureString parameters
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ---- 2. EC2 Instance: Applayer-1 (Bastion + Apps) ----

# ---- Dynamically computes the subdomain name ----
# If environment is production, use mqtt.chescloud.my.id; otherwise staging-mqtt.chescloud.my.id
locals {
  mqtt_subdomain = var.environment == "production" ? "mqtt.${var.domain_name}" : "${var.environment}-mqtt.${var.domain_name}"
}

# Ditempatkan di Public Subnet agar bisa diakses oleh client / IoT Device
resource "aws_instance" "applayer" {
  ami                         = var.applayer_ami_id
  instance_type               = var.applayer_instance_type
  subnet_id                   = aws_subnet.public.id
  key_name                    = var.key_pair_name
  private_ip                  = cidrhost(var.public_subnet_cidr, 10) # 10.1.1.10
  iam_instance_profile        = aws_iam_instance_profile.applayer.name
  user_data_replace_on_change = true

  depends_on = [
    aws_iam_role_policy.least_privilege,
    aws_ssm_parameter.tailscale_auth_key
  ]

  vpc_security_group_ids = [
    aws_security_group.applayer.id
  ]

  user_data = <<EOF
#!/bin/bash
set -uo pipefail
exec > >(tee -a /var/log/iot-user-data.log) 2>&1

# Fetch Tailscale auth key from SSM (guaranteed to exist via depends_on)
TS_KEY="$(aws ssm get-parameter \
  --name "/${var.project_name}/${var.environment}/TAILSCALE_AUTH_KEY" \
  --with-decryption --region ${var.aws_region} \
  --query "Parameter.Value" --output text 2>/dev/null || true)"

if [ -n "$TS_KEY" ]; then
    echo "[$(date -Is)] Registering Tailscale..."
    tailscale up --authkey="$TS_KEY" --accept-routes --accept-dns=true
    tailscale status || true
    echo "[$(date -Is)] Tailscale Registered."
else
    echo "[$(date -Is)] WARN: Tailscale auth key not found in SSM."
fi

echo "[$(date -Is)] Applayer boot complete. Awaiting Ansible configuration."
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
  ami                         = var.datalayer_ami_id
  instance_type               = var.datalayer_instance_type
  subnet_id                   = aws_subnet.private.id
  key_name                    = var.key_pair_name
  private_ip                  = cidrhost(var.private_subnet_cidr, 10) # Contoh: 10.1.2.10
  iam_instance_profile        = aws_iam_instance_profile.applayer.name
  user_data_replace_on_change = true

  vpc_security_group_ids = [
    aws_security_group.datalayer.id
  ]

  # Packages are pre-installed in the custom datalayer AMI.
  # Database initialization, pg_hba, users, and replication are
  # configured by Ansible (timescaledb_primary/tasks/configure.yml)
  # triggered by the null_resource.ansible_configure below.
  user_data = <<EOF
#!/bin/bash
echo "Datalayer Primary booted. Awaiting Ansible configuration."
EOF

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
  ami                         = var.datalayer_ami_id
  instance_type               = var.datalayer_instance_type
  subnet_id                   = aws_subnet.private.id
  key_name                    = var.key_pair_name
  private_ip                  = cidrhost(var.private_subnet_cidr, 20) # Contoh: 10.1.2.20
  iam_instance_profile        = aws_iam_instance_profile.applayer.name
  user_data_replace_on_change = true

  vpc_security_group_ids = [
    aws_security_group.datalayer.id
  ]

  # Packages are pre-installed in the custom datalayer AMI.
  # Base backup, replication config, and service start are
  # configured by Ansible (timescaledb_replica/tasks/configure.yml)
  # triggered by the null_resource.ansible_configure below.
  user_data = <<EOF
#!/bin/bash
echo "Datalayer Replica booted. Awaiting Ansible configuration."
EOF

  root_block_device {
    volume_size           = var.ebs_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-datalayer-2"
  }
}
