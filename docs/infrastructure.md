# AWS Cloud Infrastructure & Topology Design Reference

This document provides a comprehensive reference for the cloud infrastructure of the IoT Big Data pipeline. It covers network topology, security policies, IAM configurations, compute resources, and external service integrations.

> **Audience:** Operators and maintainers for audit, troubleshooting, or infrastructure rebuilds.
>
> Identifiers such as account IDs, AMI IDs, and resource IDs are sanitized. When reproducing, replace with your own values.
>
> For the architectural rationale behind the 3-node decoupled layout, see [ADR-001: Decouple Database Layer](adr/ADR-001-decouple-database-layer.md).

---

## Region & Account

- **Region:** `ap-southeast-1` (Singapore)
- **Account ID:** `<AWS_ACCOUNT_ID>`

---

## Network

> [!NOTE]
> The configuration below describes the VPC **Production** layout (`10.0.0.0/16`). For **Staging**, the scheme is `10.1.0.0/16` (Public Subnet: `10.1.1.0/24`, Private Subnet: `10.1.2.0/24`). All automation scripts support both schemes dynamically.

### VPC

| Attribute | Value |
|:---|:---|
| CIDR | `10.0.0.0/16` |
| DNS Hostnames | enabled |
| DNS Resolution | enabled |

### Subnets

| Subnet | CIDR | Type | AZ | Assigned Resources |
|:---|:---|:---|:---|:---|
| `iot-bigdata-public-subnet` | `10.x.1.0/24` | Public | `ap-southeast-1b` | `applayer-1` (Bastion + Backend) |
| `iot-bigdata-private-subnet` | `10.x.2.0/24` | Private | `ap-southeast-1b` | `datalayer-1` (Primary), `datalayer-2` (Replica), Ephemeral Spark Workers |

> **Design:** Database and Spark workers are isolated in the private subnet without internet access. `applayer-1` in the public subnet acts as the sole entry point (Bastion Host).

### Route Tables

| Route Table | Subnet | Routes |
|:---|:---|:---|
| `iot-bigdata-public-rt` | `iot-bigdata-public-subnet` | `10.x.0.0/16 -> local`, `0.0.0.0/0 -> igw` |
| `iot-bigdata-private-rt` | `iot-bigdata-private-subnet` | `10.x.0.0/16 -> local`, `pl-xxx -> S3 VPC Endpoint` |

> The private route table has **no route** to the Internet Gateway. Outbound internet is completely blocked.

### Internet Gateway

The VPC has 1 Internet Gateway, associated only with the public subnet route table.

### VPC Endpoint (S3 Gateway)

| Attribute | Value |
|:---|:---|
| Service | `com.amazonaws.ap-southeast-1.s3` |
| Type | Gateway |
| Route Table | `iot-bigdata-private-rt` |
| Cost | **Free** |

> Spark workers in the private subnet access the S3 Data Lake through this endpoint, without a NAT Gateway and without internet transfer costs.

---

## EC2 Instances

| Name | Instance Type | Role | Lifecycle |
|:---|:---|:---|:---|
| `iot-bigdata-applayer-1` | `c7i-flex.large` | App Layer (FastAPI, MQTT, Grafana, Spark Master) | Always-on |
| `iot-bigdata-datalayer-1` | `t3.small` | DB Primary (PostgreSQL + TimescaleDB) | Always-on |
| `iot-bigdata-datalayer-2` | `t3.small` | DB Replica (streaming replication) | Always-on |
| `iot-bigdata-worker-N` | `t3.small` | Spark Worker (ephemeral, private subnet) | Auto launch/terminate via `run_with_worker.sh` |

### Custom AMI (for Workers)

| Attribute | Value |
|:---|:---|
| AMI ID | `ami-xxxxxxxxxxxxxxxxx` |
| Base | Amazon Linux 2023 |
| Pre-installed | Java 21 (Amazon Corretto), Spark 3.5.8 at `/opt/spark` |
| Default user | `ec2-user` |

---

## Security Groups

### 1. `applayer-sg`

Attached to: `iot-bigdata-applayer-1`

**Inbound:**

| Source | Port | Protocol | Purpose |
|:---|:---|:---|:---|
| `worker-sg` | 0-65535 | TCP | Spark RPC + driver block manager |
| Tailscale CIDR | 22 | TCP | SSH via Tailscale |

**Outbound:** All traffic (default)

> Grafana is accessed via Cloudflare Tunnel, so no inbound port 3000 is needed from the internet.

### 2. `datalayer-sg`

Attached to: `iot-bigdata-datalayer-1`, `iot-bigdata-datalayer-2`

**Inbound:**

| Source | Port | Protocol | Purpose |
|:---|:---|:---|:---|
| `applayer-sg` | 5432 | TCP | Backend, Grafana, Spark JDBC |
| `applayer-sg` | 22 | TCP | SSH via Bastion (`applayer-1`) |
| `worker-sg` | 5432 | TCP | Spark executor JDBC write |
| `datalayer-sg` (self) | 5432 | TCP | Streaming replication between DB nodes |

**Outbound:** All traffic (default)

> Database nodes are in the private subnet without internet access. SSH is only possible through `applayer-1` as Bastion Host.

### 3. `worker-sg`

Attached to: `iot-bigdata-worker-*` (ephemeral, private subnet)

**Inbound:**

| Source | Port | Protocol | Purpose |
|:---|:---|:---|:---|
| `applayer-sg` | 0-65535 | TCP | SSH from `applayer-1` + Spark worker registration |

**Outbound:** All traffic (default)

> Workers access S3 via the VPC Gateway Endpoint (free, no internet). Database connections go through internal VPC routing.

---

## IAM

### Instance Profile: `iot-bigdata-{env}-s3-role`

Attached to: `applayer-1` and used as instance profile for ephemeral workers.

> **Note on naming:** The role is named `iot-bigdata-{env}-s3-role` (e.g. `iot-bigdata-staging-s3-role`), created and managed entirely by Terraform.

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
|:---|:---|:---|
| `AmazonSSMManagedInstanceCore` | AWS managed | SSM Run Command and Session Manager access |
| `iot-bigdata-{env}-least-privilege-policy` | Inline (custom) | All project-specific permissions, scoped by resource |

**Inline Policy: `iot-bigdata-{env}-least-privilege-policy`**

A single inline policy enforces the principle of least privilege across all actions the role needs to perform:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EC2WorkerOrchestration",
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:TerminateInstances",
                "ec2:DescribeInstances"
            ],
            "Resource": "*"
        },
        {
            "Sid": "PassRoleToWorker",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/iot-bigdata-{env}-s3-role"
        },
        {
            "Sid": "S3DataLakeBucketAccess",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::iot-bigdata-datalake-*"
        },
        {
            "Sid": "S3DataLakeObjectAccess",
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::iot-bigdata-datalake-*/*"
        },
        {
            "Sid": "SSMSecretsReadOnly",
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameters",
                "ssm:GetParameter",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:<region>:<AWS_ACCOUNT_ID>:parameter/iot-bigdata/{env}/*"
        },
        {
            "Sid": "KMSDecryptForSSM",
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "kms:ViaService": "ssm.<region>.amazonaws.com"
                }
            }
        }
    ]
}
```

**What each statement covers:**

| Statement | Purpose |
|:---|:---|
| `EC2WorkerOrchestration` | Allows `run_with_worker.sh` to launch, describe, and terminate ephemeral Spark worker instances |
| `PassRoleToWorker` | Allows attaching this same role to newly launched worker instances |
| `S3DataLakeBucketAccess` | Allows listing the project's data lake buckets (scoped to `iot-bigdata-datalake-*` only) |
| `S3DataLakeObjectAccess` | Allows read/write/delete of objects inside project buckets (Parquet exports, RPM packages, scripts, secrets temp files) |
| `SSMSecretsReadOnly` | Allows reading SSM parameters under the project's path prefix — used by `fetch-secrets.sh` on every deployment |
| `KMSDecryptForSSM` | Allows decrypting `SecureString` SSM parameters (database passwords, tokens) via the KMS key tied to SSM |

---

## S3

### Bucket: `iot-bigdata-datalake-<env>`

| Prefix | Purpose | Retention |
|:---|:---|:---|
| `raw/` | Parquet exports from `export_to_parquet.py` | Manual |
| `benchmark/` | Synthetic datasets from `generate_bulk_data.py` | Manual |

**Access pattern:** Read/write via IAM Role (no hardcoded credentials).

---

## Key Pairs

| Key Name | Purpose | Location |
|:---|:---|:---|
| `iot-worker-key` | SSH from `applayer-1` to ephemeral workers | `~/.ssh/iot-worker-key` on `applayer-1` |
| (admin key) | SSH to `applayer-1` (Bastion) | Local machine -> Tailscale -> `applayer-1` |

> **Access to database nodes:** SSH to `applayer-1` first (via Tailscale), then jump to the private database IP (`10.x.2.x`) using SSH Agent Forwarding (`ssh -A`).

---

## External Services (Outside AWS)

| Service | Purpose | Notes |
|:---|:---|:---|
| **Tailscale** | Zero-trust SSH to `applayer-1` (Bastion) | Database nodes do not use Tailscale (private subnet, no internet) |
| **Cloudflare Tunnel** | User access to Grafana at `<grafana-domain>` | No inbound port 3000 from the internet |
| **Telegram Bot** | Alerting from Grafana | Bot token + chat ID in `.env`, provisioned via `contact-points.yaml` |

---

## Administrative Access & Tunnels

- **VPN ingress via Tailscale:** All servers join an isolated Tailscale network at boot time. To SSH into any host, administrators must authenticate to the Tailscale mesh, making standard public port 22 scanner sweeps completely ineffective.
- **Public access via Cloudflare Tunnel:** Grafana dashboards on `applayer-1` are exposed to DNS via `cloudflared`. The tunnel initiates outgoing connections to Cloudflare's edge network, allowing users to view charts via HTTPS without exposing raw ingress web ports to the internet.

---

## Cost Estimation (rough, on-demand)

For always-on infrastructure in `ap-southeast-1`:

| Resource | Qty | Hourly | Monthly |
|:---|:---|:---|:---|
| `c7i-flex.large` (applayer-1) | 1 | ~$0.098 | ~$71.38 |
| `t3.small` (datalayer x2) | 2 | ~$0.026 | ~$38.54 |
| EBS gp3 (30GB x 3) | 90GB | - | ~$7.20 |
| S3 storage | <1GB | - | ~$0.02 |
| Data transfer | varies | - | varies |
| **Total estimate** | | | **~$117.14/month** |

> Ephemeral worker cost is negligible (runs for a few minutes per job, $0.0264/hr x job count x duration).
> For accurate estimates, use the [AWS Pricing Calculator](https://calculator.aws/).

---

## Disaster Recovery & Immutable Infrastructure (IaC)

This architecture strictly adheres to **Infrastructure as Code (IaC)** principles using Terraform, treating instances as "cattle, not pets." 

If a catastrophic failure occurs—such as a fatal kernel panic (OOM) on the `applayer` node caused by an unpartitioned Big Data stress test—recovery is fully automated without manual SSH debugging or OS-level repairs.

### Recovery Workflow Example (Proven via Stress Test)
When an instance like `applayer-1` crashes irrecoverably:
1. The administrator simply runs `terraform apply`.
2. Terraform detects the tainted or destroyed instance state and removes the broken node (`1 destroyed`).
3. Terraform provisions a brand new instance on AWS (`1 added`).
4. The heavily automated `local-exec` provisioners install all dependencies (Java, Python, Spark, systemd services) from scratch.
5. Within ~2.5 minutes, the entire server is completely rebuilt and restored to the exact desired production state.

This immutable architecture guarantees that human error, heavy analytical crashes, or OS corruption can be resolved instantly via automated rebuilds, ensuring massive fault tolerance.
