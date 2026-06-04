# AWS Infrastructure Reference

> Dokumentasi konfigurasi AWS untuk project ini. Berisi struktur resource, security rules, dan IAM policies yang dipakai.
>
> **Audience:** Operator/maintainer untuk reference saat audit, troubleshoot, atau rebuild.
> **Tujuan:** Snapshot operasional. Bukan IaC — untuk reproducibility penuh, perlu Terraform/CloudFormation.
>
> Identifier seperti account ID, AMI ID, dan resource ID di-sanitize. Saat reproduce, ganti dengan value masing-masing.

---

## Region & Account

- **Region:** `ap-southeast-1` (Singapore)
- **Account ID:** `<AWS_ACCOUNT_ID>`

---

## Network

### VPC

| Atribut | Value |
|---------|-------|
| CIDR | `10.0.0.0/16` |
| DNS Hostnames | enabled |
| DNS Resolution | enabled |

### Subnet

| Atribut | Value |
|---------|-------|
| CIDR | `10.0.1.0/24` |
| Type | Public |
| AZ | `ap-southeast-1a` |
| `MapPublicIpOnLaunch` | `true` (untuk worker auto public IP) |

### Internet Gateway

VPC ini punya 1 Internet Gateway untuk akses outbound (S3 endpoint, Maven repo, dll).

> **Alternatif yang lebih cost-efficient:** VPC Endpoint untuk S3 (gateway endpoint, gratis). Tidak diimplementasi karena setup ini sudah cukup untuk skala project.

---

## EC2 Instances

| Name | Instance Type | Role | Lifecycle |
|------|---------------|------|-----------|
| `iot-bigdata-applayer-1` | `c7i-flex.large` | App Layer (FastAPI, MQTT, Grafana, Spark Master) | Always-on |
| `iot-bigdata-datalayer-1` | `t3.small` | DB Primary (PostgreSQL + TimescaleDB) | Always-on |
| `iot-bigdata-datalayer-2` | `t3.small` | DB Replica (streaming replication) | Always-on |
| `iot-bigdata-worker-N` | `t3.small` | Spark Worker (ephemeral) | Auto launch/terminate via `run_with_worker.sh` |

### Custom AMI (untuk Worker)

| Atribut | Value |
|---------|-------|
| AMI ID | `ami-xxxxxxxxxxxxxxxxx` |
| Base | Amazon Linux 2023 |
| Pre-installed | Java 21 (Amazon Corretto), Spark 3.5.8 di `/opt/spark` |
| Default user | `ec2-user` |

---

## Security Groups

### `applayer-sg` (`sg-xxxxxxxxxxxxxxxxx`)

Attached to: `iot-bigdata-applayer-1`

**Inbound:**

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| `worker-sg` | 0-65535 | TCP | Spark RPC + driver block manager |
| Tailscale CIDR | 22 | TCP | SSH via Tailscale |

**Outbound:** All traffic (default)

> Note: Akses Grafana dari user lewat Cloudflare Tunnel — tidak perlu inbound port 3000 dari internet.

### `datalayer-sg` (`sg-xxxxxxxxxxxxxxxxx`)

Attached to: `iot-bigdata-datalayer-1`, `iot-bigdata-datalayer-2`

**Inbound:**

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| `applayer-sg` | 5432 | TCP | Backend, Grafana, Spark JDBC |
| `worker-sg` | 5432 | TCP | Spark executor JDBC write |
| `datalayer-sg` (self) | 5432 | TCP | Streaming replication antar DB nodes |

**Outbound:** All traffic (default)

### `worker-sg` (`sg-xxxxxxxxxxxxxxxxx`)

Attached to: `iot-bigdata-worker-*` (ephemeral)

**Inbound:**

| Source | Port | Protocol | Purpose |
|--------|------|----------|---------|
| `applayer-sg` | 0-65535 | TCP | SSH dari applayer-1 + Spark worker registration |

**Outbound:** All traffic (default)

> Worker butuh outbound ke: S3 (HTTPS), datalayer-sg (5432), applayer-sg (random ports), Maven Central (HTTPS).

---

## IAM

### Instance Profile: `iot-bigdata-node2-s3-role`

Attached to: `applayer-1`, dan dipakai sebagai instance profile ke ephemeral worker.

> **Note tentang naming:** Nama role legacy (dari arsitektur lama). Sekarang dipakai untuk applayer-1 + workers. Bisa di-rename, tapi tidak prioritas.

**Trust Policy:**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {"Service": "ec2.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }
    ]
}
```

**Attached Policies:**

| Policy | Type | Purpose |
|--------|------|---------|
| `AmazonS3FullAccess` | AWS managed | Read/write data lake |
| `AllowPassRoleAndEC2` | Inline (custom) | Launch ephemeral worker dengan role |

**Inline Policy: `AllowPassRoleAndEC2`**

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/iot-bigdata-node2-s3-role"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:TerminateInstances",
                "ec2:DescribeInstances"
            ],
            "Resource": "*"
        }
    ]
}
```

> Untuk production, batasi `ec2:RunInstances` dan `TerminateInstances` dengan resource conditions (misal: hanya untuk SG/subnet/AMI tertentu).

---

## S3

### Bucket: `iot-bigdata-datalake-kagebyo`

| Prefix | Purpose | Retention |
|--------|---------|-----------|
| `raw/` | Parquet hasil export dari `export_to_parquet.py` | Manual |
| `benchmark/` | Synthetic dataset dari `generate_bulk_data.py` | Manual |

**Access pattern:** Read/write via IAM Role (no hardcoded credentials).

---

## Key Pairs

| Key Name | Purpose | Lokasi |
|----------|---------|--------|
| `iot-worker-key` | SSH dari applayer-1 ke ephemeral worker | `~/.ssh/iot-worker-key` di applayer-1 |
| (admin key) | SSH ke applayer-1 dan datalayer | Local machine + Tailscale |

---

## External Services (di luar AWS)

| Service | Purpose | Note |
|---------|---------|------|
| **Tailscale** | Zero-trust SSH ke semua node | Tidak ada inbound port 22 dari internet |
| **Cloudflare Tunnel** | User access Grafana di `grafana.chescloud.my.id` | Tidak ada inbound port 3000 dari internet |
| **Telegram Bot** | Alerting dari Grafana | Bot token + chat ID di `contact-points.yaml` (gitignored) |

---

## Reproduction Checklist

Untuk membuat infrastruktur serupa dari scratch (manual via AWS Console / CLI):

1. Buat VPC `10.0.0.0/16` + public subnet `10.0.1.0/24` (enable auto public IP).
2. Buat 3 Security Group dengan rules sesuai tabel di atas.
3. Buat IAM Role dengan policies sesuai dokumentasi.
4. Buat Custom AMI worker (Amazon Linux 2023 + Java 21 + Spark 3.5.8).
5. Launch 3 EC2 instance: applayer-1, datalayer-1, datalayer-2.
6. Setup Tailscale di semua node.
7. Setup Cloudflare Tunnel di applayer-1 (kalau perlu public access).
8. Jalankan provisioning scripts:
   - `provision-db-primary.sh` di datalayer-1
   - `provision-db-replica.sh` di datalayer-2
9. Setup app stack di applayer-1 (lihat `runbook-spark-setup.md`).
10. Buat S3 bucket + attach IAM policy.

---

## Cost Estimation (rough, on-demand)

Untuk infrastruktur always-on di `ap-southeast-1`:

| Resource | Qty | Hourly | Monthly |
|----------|-----|--------|---------|
| `c7i-flex.large` (applayer-1) | 1 | ~$0.078 | ~$57 |
| `t3.small` (datalayer x2) | 2 | ~$0.024 | ~$36 |
| EBS gp3 (30GB × 3) | 90GB | — | ~$7 |
| S3 storage | <1GB | — | ~$0.02 |
| Data transfer | varies | — | varies |
| **Total estimate** | | | **~$100/month** |

> Ephemeral worker cost negligible (jalan beberapa menit per job, $0.024/jam × jumlah job × durasi).
> Untuk estimasi akurat, gunakan [AWS Pricing Calculator](https://calculator.aws/).
