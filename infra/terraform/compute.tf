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
  ami                         = var.ami_id
  instance_type               = var.applayer_instance_type
  subnet_id                   = aws_subnet.public.id
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.applayer.name
  user_data_replace_on_change = true

  depends_on = [
    aws_iam_role_policy.least_privilege,
    aws_ssm_parameter.cloudflare_api_token,
    aws_ssm_parameter.tailscale_auth_key,
    aws_ssm_parameter.cloudflare_tunnel_token
  ]

  vpc_security_group_ids = [
    aws_security_group.applayer.id
  ]

  # Bootstrapping (Otomatisasi instalasi software saat pertama kali server menyala)
  user_data = <<EOF
#!/bin/bash
set -uo pipefail
exec > >(tee -a /var/log/iot-user-data.log | logger -t iot-user-data -s 2>/dev/console) 2>&1

log() {
    echo "[$(date -Is)] $*" >&2
}

get_ssm_param() {
    aws ssm get-parameter \
      --name "$1" \
      --with-decryption \
      --region ${var.aws_region} \
      --query "Parameter.Value" \
      --output text 2>/dev/null || true
}

wait_ssm_param() {
    name="$1"
    label="$2"
    attempts=30
    delay=10

    for attempt in $(seq 1 "$attempts"); do
        value="$(get_ssm_param "$name")"
        if [ -n "$value" ] && [ "$value" != "placeholder_do_not_delete" ] && [ "$value" != "None" ]; then
            printf '%s' "$value"
            return 0
        fi
        log "Waiting for $label in SSM ($attempt/$attempts)..."
        sleep "$delay"
    done

    log "WARN: $label is missing or still placeholder after $((attempts * delay)) seconds."
    return 1
}

# 1. Update system & install package dasar
log "Installing base packages..."
dnf update -y
dnf install -y awscli git python3 python3-pip python3.12 java-21-amazon-corretto-devel

# 2. Install & jalankan Docker + Docker Compose v2 (Standar AL2023)
log "Installing Docker..."
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# Download & install Docker Compose V2 secara manual karena tidak ada di repo AL2023
mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.26.1/docker-compose-linux-x86_64 -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# 2.5 Tarik provisioning scripts dari S3 agar folder scripts lokal di Bastion langsung terisi lengkap
log "Waiting for scripts to be uploaded to S3..."
until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/scripts/deploy-mqtt-cert.sh --region ${var.aws_region} &>/dev/null; do
  log "Still waiting for scripts in s3..."
  sleep 10
done

log "Downloading provisioning scripts from S3..."
mkdir -p /home/ec2-user/iot-bigdata-project/infra/scripts
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/scripts/ /home/ec2-user/iot-bigdata-project/infra/scripts/ --recursive --region ${var.aws_region}
chmod +x /home/ec2-user/iot-bigdata-project/infra/scripts/*.sh
chown -R ec2-user:ec2-user /home/ec2-user/iot-bigdata-project

# 3. Install & configure Spark 3.5.8
log "Installing Spark..."
cd /opt
curl -SL https://dlcdn.apache.org/spark/spark-3.5.8/spark-3.5.8-bin-hadoop3.tgz -o spark-3.5.8-bin-hadoop3.tgz
tar -xzf spark-3.5.8-bin-hadoop3.tgz
ln -sf /opt/spark-3.5.8-bin-hadoop3 /opt/spark
rm -f spark-3.5.8-bin-hadoop3.tgz
mkdir -p /opt/spark/logs /opt/spark/work
chown -R ec2-user:ec2-user /opt/spark-3.5.8-bin-hadoop3 /opt/spark/logs /opt/spark/work
echo 'export SPARK_HOME=/opt/spark' > /etc/profile.d/spark.sh
echo 'export PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin' >> /etc/profile.d/spark.sh

# 4. Install & Configure Tailscale
log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# Ambil Tailscale key dari SSM dan login secara otomatis
TS_KEY="$(wait_ssm_param "/${var.project_name}/${var.environment}/TAILSCALE_AUTH_KEY" "Tailscale auth key")"
if [ -n "$TS_KEY" ]; then
    log "Registering Tailscale with auth key..."
    tailscale up --authkey="$TS_KEY" --accept-routes --accept-dns=true
    tailscale status || true
fi

# 5. Install Certbot & Cloudflare DNS Plugin untuk SSL (AL2023 pip method)
log "Installing Certbot..."
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-dns-cloudflare
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

# Ambil Cloudflare Token dari SSM dan terbitkan sertifikat SSL
CF_TOKEN="$(wait_ssm_param "/${var.project_name}/${var.environment}/CLOUDFLARE_API_TOKEN" "Cloudflare API token")"
if [ -n "$CF_TOKEN" ]; then
    log "Requesting Let's Encrypt SSL cert via Certbot..."
    mkdir -p /etc/letsencrypt
    cat <<SEC > /etc/letsencrypt/cloudflare.ini
dns_cloudflare_api_token = $CF_TOKEN
SEC
    chmod 600 /etc/letsencrypt/cloudflare.ini
    
    # Jalankan Certbot DNS-01 challenge untuk domain staging / production dengan deploy-hook untuk auto-renewal
    certbot certonly --dns-cloudflare \
      --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
      -d "${local.mqtt_subdomain}" \
      --email "admin@${var.domain_name}" \
      --agree-tos --no-eff-email \
      --non-interactive \
      --deploy-hook "/home/ec2-user/iot-bigdata-project/infra/scripts/deploy-mqtt-cert.sh ${local.mqtt_subdomain}"
fi

# 6. Install & Configure Cloudflare Tunnel (cloudflared)
curl -L --output cloudflared.rpm https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm
dnf localinstall -y cloudflared.rpm
rm -f cloudflared.rpm

TUNNEL_TOKEN="$(wait_ssm_param "/${var.project_name}/${var.environment}/CLOUDFLARE_TUNNEL_TOKEN" "Cloudflare tunnel token")"
if [ -n "$TUNNEL_TOKEN" ]; then
    log "Installing and starting cloudflared systemd service..."
    cloudflared service install "$TUNNEL_TOKEN"
    systemctl enable --now cloudflared
    systemctl status cloudflared --no-pager || true
fi

log "Applayer bootstrap finished."
EOF

  # Execute local-bootstrap after applayer instance and S3 bucket is ready
  provisioner "local-exec" {
    command = "bash ${path.module}/../scripts/local-bootstrap.sh --post-apply"
    environment = {
      AWS_REGION          = var.aws_region
      S3_BUCKET           = aws_s3_bucket.datalake.id
      BASTION_INSTANCE_ID = self.id
      ENV                 = var.environment
      PROJECT_NAME        = var.project_name
    }
  }

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
  ami                  = var.ami_id
  instance_type        = var.datalayer_instance_type
  subnet_id            = aws_subnet.private.id
  key_name             = var.key_pair_name
  private_ip           = cidrhost(var.private_subnet_cidr, 10) # Contoh: 10.1.2.10
  iam_instance_profile = aws_iam_instance_profile.applayer.name

  vpc_security_group_ids = [
    aws_security_group.datalayer.id
  ]

  user_data = <<EOF
#!/bin/bash
# 1. Tunggu hingga RPM dan script tersedia di S3 (diunggah oleh local-bootstrap.sh)
until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/packages/ | grep -q '\.rpm'; do
    echo "Waiting for packages in S3..."
    sleep 10
done

until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/scripts/ | grep -q 'provision-db'; do
    echo "Waiting for scripts in S3..."
    sleep 10
done

# 2. Buat folder download
mkdir -p /home/ec2-user/db-pkg
cd /home/ec2-user

# 3. Tarik RPM dan script dari S3
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/packages/ /home/ec2-user/ --recursive --exclude "*" --include "*.rpm" --region ${var.aws_region}
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/scripts/ /home/ec2-user/db-pkg/ --recursive --region ${var.aws_region}

# 4. Ambil parameter DB dari file rahasia di S3
until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/secrets/db-secrets.env; do
    echo "Waiting for DB secrets in S3..."
    sleep 10
done
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/secrets/db-secrets.env /tmp/db-secrets.env
chmod 600 /tmp/db-secrets.env
source /tmp/db-secrets.env
rm -f /tmp/db-secrets.env

REPLICA_IP="${cidrhost(var.private_subnet_cidr, 20)}"

# 5. Jalankan provisioning primary
chmod +x /home/ec2-user/db-pkg/provision-db-primary.sh
cp /home/ec2-user/db-pkg/init.sql /tmp/init.sql || true
# 6. Jalankan provisioning primary
cd /home/ec2-user/db-pkg
./provision-db-primary.sh "$POSTGRES_DB" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$REPLICA_IP"

# 7. Fix ownership of ec2-user directory
chown -R ec2-user:ec2-user /home/ec2-user
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
  ami                  = var.ami_id
  instance_type        = var.datalayer_instance_type
  subnet_id            = aws_subnet.private.id
  key_name             = var.key_pair_name
  private_ip           = cidrhost(var.private_subnet_cidr, 20) # Contoh: 10.1.2.20
  iam_instance_profile = aws_iam_instance_profile.applayer.name

  vpc_security_group_ids = [
    aws_security_group.datalayer.id
  ]

  user_data = <<EOF
#!/bin/bash
# 1. Tunggu hingga RPM dan script tersedia di S3
until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/packages/ | grep -q '\.rpm'; do
    echo "Waiting for packages in S3..."
    sleep 10
done

until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/scripts/ | grep -q 'provision-db'; do
    echo "Waiting for scripts in S3..."
    sleep 10
done

# 2. Buat folder download
mkdir -p /home/ec2-user/db-pkg
cd /home/ec2-user

# 3. Tarik RPM dan script dari S3
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/packages/ /home/ec2-user/ --recursive --exclude "*" --include "*.rpm" --region ${var.aws_region}
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/scripts/ /home/ec2-user/db-pkg/ --recursive --region ${var.aws_region}

# 4. Ambil parameter DB dari file rahasia di S3
until aws s3 ls s3://${var.project_name}-datalake-${var.environment}/secrets/db-secrets.env; do
    echo "Waiting for DB secrets in S3..."
    sleep 10
done
aws s3 cp s3://${var.project_name}-datalake-${var.environment}/secrets/db-secrets.env /tmp/db-secrets.env
chmod 600 /tmp/db-secrets.env
source /tmp/db-secrets.env
rm -f /tmp/db-secrets.env

PRIMARY_IP="${cidrhost(var.private_subnet_cidr, 10)}"

# 5. Tunggu hingga primary DB port 5432 aktif sebelum running replica script
until timeout 3 bash -c "cat < /dev/null > /dev/tcp/$PRIMARY_IP/5432" 2>/dev/null; do
    echo "Waiting for primary database at $PRIMARY_IP..."
    sleep 5
done

# 6. Jalankan provisioning replica
chmod +x /home/ec2-user/db-pkg/provision-db-replica.sh
cd /home/ec2-user/db-pkg
./provision-db-replica.sh "$PRIMARY_IP" "$POSTGRES_PASSWORD"

# 7. Fix ownership of ec2-user directory
chown -R ec2-user:ec2-user /home/ec2-user
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
