# Runbook: Spark Cluster Setup & Benchmarking

> Dokumentasi setup Spark Master di applayer-1 + ephemeral worker pipeline,
> berdasarkan pengalaman setup 25 Mei 2026.

---

## Arsitektur Big Data Pipeline

### Overview

Sistem ini mengimplementasikan **batch processing pipeline** menggunakan Apache Spark untuk menganalisis data sensor IoT yang terkumpul dari lingkungan manufaktur. Pipeline ini merupakan bagian dari arsitektur Lambda yang simplified — fokus pada batch layer.

### Data Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DATA INGESTION (Real-time)                       │
│                                                                         │
│  IoT Simulator ──MQTT──► Mosquitto ──► FastAPI Consumer ──► TimescaleDB │
│  (3 device)              (broker)       (batch insert)       (primary)  │
└─────────────────────────────────────────────────────────────────────────┘
                                                        │
                                                        │ export (hourly/on-demand)
                                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           DATA LAKE (S3)                                │
│                                                                         │
│  s3://iot-bigdata-datalake-kagebyo/                                     │
│  ├── raw/              ← Parquet dari export_to_parquet.py              │
│  └── benchmark/        ← Parquet sintetis dari generate_bulk_data.py    │
│                                                                         │
│  Format: Apache Parquet (columnar, compressed)                          │
│  Alasan: efisien untuk analytical query, native Spark support           │
└─────────────────────────────────────────────────────────────────────────┘
                                                        │
                                                        │ s3a:// read
                                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     BATCH PROCESSING (Apache Spark)                     │
│                                                                         │
│  ┌──────────────────┐     ┌──────────────────────────────────────┐      │
│  │  Spark Master    │     │  Ephemeral Workers (0-N)             │      │
│  │  (applayer-1)    │────►│  - Auto-launch via AWS CLI           │      │
│  │                  │     │  - Auto-terminate setelah job selesai│      │
│  │  Roles:          │     │  - t3.small (2 vCPU, 2GB RAM)        │      │
│  │  - Scheduler     │     │  - Custom AMI (Java 21 + Spark 3.5)  │      │
│  │  - Driver host   │     │                                      │      │
│  └──────────────────┘     └──────────────────────────────────────┘      │
│                                                                         │
│  Job: batch_analytics.py                                                │
│  ├── Read Parquet dari S3 (distributed)                                 │
│  ├── Repartition (smart, berdasarkan worker count)                      │
│  ├── Cache di memory (avoid re-read S3)                                 │
│  ├── Agregasi per device (avg, min, max per sensor)                     │
│  ├── Anomaly detection (threshold-based)                                │
│  └── Write hasil ke DB (JDBC distributed)                               │
└─────────────────────────────────────────────────────────────────────────┘
                                                        │
                                                        │ JDBC write
                                                        ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      SERVING LAYER (PostgreSQL + Grafana)               │
│                                                                         │
│  TimescaleDB (datalayer-1)                                              │
│  ├── analytics_results   ← output agregasi per device                   │
│  ├── anomaly_events      ← threshold violations                         │
│  └── spark_job_log       ← metadata setiap job run                      │
│                                                                         │
│  Grafana (applayer-1)                                                   │
│  ├── Dashboard real-time sensor readings                                │
│  ├── Dashboard analytics results                                        │
│  └── Telegram alerting                                                  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Komponen Big Data

| Komponen | Teknologi | Peran |
|----------|-----------|-------|
| Message Broker | Eclipse Mosquitto (MQTT) | Decouple producer-consumer, reliable delivery |
| Time-Series DB | PostgreSQL + TimescaleDB | Penyimpanan optimized untuk data sensor time-series |
| Data Lake | Amazon S3 (Parquet) | Storage murah, format columnar untuk analytics |
| Batch Engine | Apache Spark 3.5.8 | Distributed processing, in-memory computation |
| Orchestration | Bash + AWS CLI | Ephemeral worker lifecycle management |
| Visualization | Grafana | Dashboard + alerting |

### Distributed Computing Model

```
                    ┌─────────────────────────────┐
                    │         DRIVER              │
                    │    (applayer-1, 512MB)      │
                    │                             │
                    │  - Parse job                │
                    │  - Build DAG                │
                    │  - Schedule tasks           │
                    │  - Collect small results    │
                    └──────────┬──────────────────┘
                               │ assign tasks
                    ┌──────────┴──────────────────┐
                    │                             │
            ┌───────▼───────┐            ┌────────▼──────┐
            │  EXECUTOR 1   │            │  EXECUTOR 2   │
            │  (worker-1)   │            │  (worker-2)   │
            │               │            │               │
            │  - Read S3    │            │  - Read S3    │
            │  - Transform  │            │  - Transform  │
            │  - Write DB   │            │  - Write DB   │
            └───────────────┘            └───────────────┘
```

**Key concepts yang diterapkan:**
- **Lazy evaluation** — Spark membangun DAG (Directed Acyclic Graph) dari transformasi, baru execute saat action dipanggil
- **In-memory caching** — `df.cache()` menyimpan data di RAM executor, menghindari re-read dari S3
- **Data locality** — Spark mencoba schedule task di node yang sudah punya data
- **Fault tolerance** — Task yang gagal otomatis di-retry di executor lain
- **Partitioning** — Data dibagi ke N partition, setiap partition = 1 task = 1 unit parallelism

### Spark Job DAG (batch_analytics.py)

```
Stage 0: Read Parquet dari S3
    └── 1 task (1 file = 1 partition awal)

Stage 1: Repartition (shuffle)
    └── N tasks (N = worker_count × 2)
    └── Trigger: repartition() — redistribute data ke N partition

Stage 2: Cache materialization
    └── N tasks (count() trigger cache)

Stage 3: Aggregation (groupBy + agg)
    └── N tasks → collect ke driver (output kecil: 160 rows)

Stage 4: Anomaly detection + JDBC write
    └── Filter per sensor → union → coalesce(2) → write.jdbc()
    └── 2 tasks (2 parallel DB connections)
```

### Hasil Eksperimen & Analisis

| Skenario | Workers | Avg Time | Insight |
|----------|---------|----------|---------|
| Local mode | 0 | 28.56s | Baseline — semua di 1 JVM, no network |
| 1 worker | 1 | 42.47s | +50% overhead dari network + coordination |
| 2 worker | 2 | 44.13s* | Tidak ada speedup vs 1 worker |

*) 2 worker memiliki variance tinggi — beberapa run stuck > 5 menit.

**Kesimpulan:**

Pada skala dataset 1M records (64MB Parquet) dengan hardware constraint (t3.small, 2GB RAM):

1. **Overhead > Benefit** — Network transfer, shuffle, coordination cost lebih besar dari compute saving.
2. **Amdahl's Law** — Serial portion (S3 I/O, DB write, driver coordination) membatasi maximum speedup.
3. **Threshold** — Distributed computing baru memberikan ROI positif pada:
   - Dataset > 1GB (ratusan juta records)
   - Worker dengan RAM > 8GB (r5.xlarge+)
   - Job yang compute-intensive (ML training, complex joins)

Ini adalah **temuan valid** yang konsisten dengan literatur distributed computing — bukan kegagalan sistem.

---

## Setup Spark Master di applayer-1

### 1. Install Java 21

```bash
sudo dnf install -y java-21-amazon-corretto-devel
java -version
```

### 2. Install Spark 3.5.8

```bash
cd /opt
sudo curl -O https://dlcdn.apache.org/spark/spark-3.5.8/spark-3.5.8-bin-hadoop3.tgz
sudo tar -xzf spark-3.5.8-bin-hadoop3.tgz
sudo ln -s /opt/spark-3.5.8-bin-hadoop3 /opt/spark
sudo rm spark-3.5.8-bin-hadoop3.tgz
```

### 3. Fix permissions

```bash
sudo mkdir -p /opt/spark/logs /opt/spark/work
sudo chown -R ec2-user:ec2-user /opt/spark/logs /opt/spark/work
```

> **Penting:** Tanpa ini, Spark Master/Worker akan fail saat start dengan error `cannot create directory`.

### 4. Set environment variables

```bash
echo 'export SPARK_HOME=/opt/spark' | sudo tee /etc/profile.d/spark.sh
echo 'export PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin' | sudo tee -a /etc/profile.d/spark.sh
source /etc/profile.d/spark.sh
```

### 5. Start Master

```bash
SPARK_LOCAL_IP=$(hostname -I | awk '{print $1}')
$SPARK_HOME/sbin/start-master.sh --host $SPARK_LOCAL_IP

# Verify
jps | grep Master
curl -s localhost:8080 | grep -o "Spark Master"
```

---

## Setup Ephemeral Worker Pipeline

### Prerequisites

1. **SSH key** untuk akses ke worker:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/iot-worker-key -N "" -C "applayer-1-spark"
   ```
   Public key di-inject ke worker via `USER_DATA` di `run_with_worker.sh`.

2. **AWS CLI** terinstall:
   ```bash
   sudo dnf install -y aws-cli-2
   ```

3. **IAM Role applayer-1** harus punya permissions:
   - `ec2:RunInstances`
   - `ec2:TerminateInstances`
   - `ec2:DescribeInstances`
   - `iam:PassRole` (untuk attach role ke worker EC2)
   - S3 read/write

   Inline policy yang dipakai:
   ```json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Action": "iam:PassRole",
               "Resource": "arn:aws:iam::<account>:role/<role-name>"
           },
           {
               "Effect": "Allow",
               "Action": ["ec2:RunInstances", "ec2:TerminateInstances", "ec2:DescribeInstances"],
               "Resource": "*"
           }
       ]
   }
   ```

4. **`.env` config:**
   ```
   SPARK_MASTER_URL=spark://10.0.1.127:7077
   WORKER_SUBNET_ID=subnet-xxx
   WORKER_SG_ID=sg-xxx
   WORKER_IAM_PROFILE=<instance_profile_name>  # NAMA, bukan ARN
   ```

### Security Group Rules

Worker SG (`<worker_sg>`) → applayer SG (`<applayer_sg>`):
- **All TCP ports** allow (untuk Spark RPC + driver block manager)

Worker SG → datalayer SG (`<datalayer_sg>`):
- **TCP 5432** allow (untuk JDBC write ke PostgreSQL)

> Tanpa "All TCP" dari worker → applayer, executor tidak bisa connect balik ke driver
> dan job stuck di `Initial job has not accepted any resources`.

---

## Known Issues & Lessons Learned

### Issue 1: Worker fail dengan `createDirectory permission denied`

**Penyebab:** `/opt/spark` owned by root setelah install via sudo, tapi worker jalan sebagai ec2-user.

**Solusi:** `chown ec2-user:ec2-user /opt/spark/logs /opt/spark/work`

### Issue 2: `Initial job has not accepted any resources`

Tiga kemungkinan penyebab — diagnose via Master Web UI (port 8080):

| Gejala | Penyebab | Solusi |
|--------|----------|--------|
| `Alive Workers: 0` | Worker tidak register | Cek log worker, biasanya permission |
| `requires more resource` | Executor memory > worker memory | Set `--executor-memory 1g` |
| Worker registered tapi job stuck | SG block worker → driver | Allow all TCP dari worker SG ke applayer SG |

### Issue 3: Driver bind ke Tailscale IP, bukan VPC IP

**Penyebab:** Applayer-1 punya multiple IP (VPC `10.0.1.x`, Tailscale `100.x.x.x`, Docker bridges).
Spark default pick salah satu yang tidak reachable dari worker.

**Solusi:** Explicit pin di spark-submit:
```bash
--conf spark.driver.host=10.0.1.127
--conf spark.driver.bindAddress=10.0.1.127
```

### Issue 4: `iam:PassRole` denied saat launch worker

**Penyebab:** IAM Role applayer-1 tidak punya permission untuk attach IAM Role ke EC2 lain.

**Solusi:** Tambahkan inline policy `AllowPassRoleAndEC2` (lihat di atas).

### Issue 5: Worker tidak punya akses S3 saat baca Parquet

**Penyebab:** Ephemeral worker EC2 di-launch tanpa IAM Profile.

**Solusi:** Pass IAM profile ke worker via `--iam-instance-profile Name=<profile_name>`.

### Issue 6: Job sangat lambat (>30 menit untuk 1M records)

**Penyebab utama:** Multiple actions tanpa cache → Spark re-read S3 berkali-kali untuk setiap action.

```python
# BAD — setiap action re-read dari S3
df.count()
df.agg(F.min("time"))
df.agg(F.max("time"))
df.groupBy(...).collect()
df.filter(...).collect()  # 4× untuk 4 sensor

# GOOD
df = spark.read.parquet(path).repartition(N).cache()
df.count()  # materialize cache
df.agg(F.min("time"), F.max("time"))  # combined
df.write.jdbc(...)  # distributed write, no collect
```

**Solusi tambahan:**
- `df.cache()` setelah read + repartition
- Combine multiple `agg()` calls jadi 1
- Pakai distributed JDBC write untuk output besar (anomaly events), bukan collect ke driver
- Set `batchsize` di JDBC properties: `--option batchsize 5000`

### Issue 7: `--master local[*]` di spark-submit tidak diterapkan

**Gejala:** Pakai `--master local[*]` tapi job tetap connect ke standalone master.

**Penyebab:** Kalau code memanggil `SparkSession.builder.master(...)` eksplisit, ini akan **override** `--master` dari spark-submit. Precedence order:

```
SparkSession.builder.master(...) di code   ← paling tinggi
> spark-submit --master flag
> spark-defaults.conf
```

**Solusi:** Hapus `.master()` call dari code. Biarkan spark-submit `--master` jadi satu-satunya tempat menentukan master URL:

```python
# BAD
spark = SparkSession.builder \
    .master(os.getenv("SPARK_MASTER_URL", "local[*]")) \
    .getOrCreate()

# GOOD — master ditentukan dari spark-submit
spark = SparkSession.builder \
    .appName(...) \
    .config(...) \
    .getOrCreate()
```

### Issue 8: Worker stuck saat baca S3 (Stage 0 task 0/N forever)

**Gejala:** Job submitted ke ephemeral worker, worker registered, tapi Stage 0 (read Parquet dari S3) tidak pernah selesai. Tidak ada error eksplisit.

**Penyebab:** Amazon Linux 2023 default pakai **IMDSv2** (metadata service v2 yang require token). AWS SDK lama (`aws-java-sdk-bundle:1.12.261`) yang dipakai Hadoop S3A tidak fully compatible dengan IMDSv2 strict mode → gagal ambil IAM credentials → gagal akses S3.

**Diagnosa:**
```bash
# Test akses metadata tanpa token (IMDSv1)
ssh ec2-user@<worker_ip> "curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/"
# Empty response = IMDSv2 required

# Test dengan token (IMDSv2)
ssh ec2-user@<worker_ip> 'TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60") && curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/'
# Return role name = IAM OK, masalah di SDK compatibility
```

**Solusi:** Launch worker dengan IMDSv1 enabled:
```bash
aws ec2 run-instances \
    ... \
    --metadata-options "HttpTokens=optional,HttpEndpoint=enabled"
```

Atau update existing worker:
```bash
aws ec2 modify-instance-metadata-options \
    --instance-id <worker_id> \
    --http-tokens optional
```

### Issue 9: Worker tidak bisa akses S3 (stuck di Stage 0 read)

**Gejala:** Worker registered, executor running, tapi Stage 0 (parquet read) tidak progress. CPU executor idle (~2%), `tasks 0/1`, `bytes read 0`.

**Diagnosa:** SSH ke worker, test akses S3:
```bash
ssh ec2-user@<worker_ip> "aws s3 ls s3://<bucket>/ --region ap-southeast-1"
# Stuck/timeout → worker tidak bisa reach S3 endpoint
```

**Penyebab:** Worker subnet tidak auto-assign public IP, dan tidak ada:
- NAT Gateway (untuk private subnet outbound)
- VPC Endpoint untuk S3 (gateway endpoint)

S3 endpoint butuh internet route. Tanpa public IP/NAT/VPC endpoint, worker tidak bisa keluar.

**Solusi (pilih salah satu):**

1. **Enable subnet auto-assign public IP**:
   ```bash
   aws ec2 modify-subnet-attribute \
       --subnet-id <subnet_id> \
       --map-public-ip-on-launch
   ```

2. **Launch worker dengan `--network-interfaces` flag** yang explicit set `AssociatePublicIpAddress=true` (sudah dipakai di `run_with_worker.sh`).

3. **Buat VPC Endpoint untuk S3** (paling clean, gratis, tidak butuh public IP).

### Issue 10: SSH host key conflict saat IP worker recycled

**Gejala:**
```
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Host key verification failed.
```

**Penyebab:** AWS recycle private IP — worker baru punya IP yang sama dengan worker lama, tapi host key berbeda. SSH client refuse connect.

**Solusi:** Jangan simpan host key. Tambahkan `-o UserKnownHostsFile=/dev/null` di SSH command (sudah dipakai di `run_with_worker.sh`):
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ec2-user@<worker_ip>
```

Atau hapus entry lama:
```bash
ssh-keygen -R <worker_ip>
```

### Issue 11: Disk space habis di worker (No space left on device)

**Gejala:**
```
ERROR TaskSchedulerImpl: Lost executor X on Y: Unable to create executor due to No space left on device
```

**Penyebab:** EBS volume worker terlalu kecil. Spark executor butuh disk untuk:
- Maven `--packages` jars (~250MB)
- Shuffle intermediate files (bisa GB untuk dataset besar)
- Cache spill ke disk kalau memory tidak cukup
- Spark logs + work directory

EBS 8GB default tidak cukup. Untuk dataset 1M records, **30GB minimum**.

**Solusi:** Naikkan VolumeSize di `aws ec2 run-instances`:
```bash
--block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}"
```

Untuk dataset > 5M records, pertimbangkan 50GB+ atau instance dengan instance store.

### Issue 12: Heartbeat timeout / Worker lost

**Gejala:**
```
WARN HeartbeatReceiver: Removing executor X with no recent heartbeats: 155816 ms exceeds timeout 120000 ms
ERROR TaskSchedulerImpl: Lost executor X: Executor heartbeat timed out
```

**Penyebab:** Executor JVM stop-the-world GC pause panjang karena memory pressure. Common di t3.small dengan dataset besar — heap kecil, GC frequent dan lama.

**Solusi:**
- Naikkan worker instance type (t3.medium 4GB, atau lebih)
- Naikkan `--executor-memory` proportional dengan instance memory
- Untuk dataset besar, jangan pakai `df.cache()` (let it spill alami daripada GC thrash)
- Tune G1GC: `--conf spark.executor.extraJavaOptions="-XX:+UseG1GC -XX:G1HeapRegionSize=4M"`

**Trade-off:** Free-tier hardware ada limit. Untuk benchmark dataset besar (10M+ records), perlu r5.xlarge atau lebih.

---

## Troubleshooting Cheatsheet

### Quick health check

```bash
# Spark Master alive?
jps | grep Master
curl -s localhost:8080 | grep "Spark Master"

# Worker registered?
curl -s localhost:8080 | grep -E "Alive Workers|Cores"

# Driver running?
ps aux | grep spark-submit | grep -v grep

# Get current app ID
APP_ID=$(curl -s localhost:8080/json/ | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['activeapps'][0]['id'] if d['activeapps'] else 'NO_APP')")
```

### Diagnose stuck job

```bash
# Stage progress
curl -s "localhost:4040/api/v1/applications/$APP_ID/stages" | python3 -c "
import json, sys
for s in json.load(sys.stdin):
    print(f\"Stage {s['stageId']} [{s['status']}]: {s.get('numCompleteTasks',0)}/{s.get('numTasks',0)} tasks | input={s.get('inputBytes',0)/1024/1024:.1f}MB\")"

# Worker resource usage
curl -s localhost:8080/json/ | python3 -c "
import json, sys
for w in json.load(sys.stdin)['workers']:
    print(f\"{w['host']}: cores {w['coresused']}/{w['cores']}, mem {w['memoryused']}/{w['memory']}MB\")"

# Worker disk + load (replace WORKER_IP)
ssh -i ~/.ssh/iot-worker-key -o UserKnownHostsFile=/dev/null \
    ec2-user@<WORKER_IP> "df -h / && uptime && free -h"
```

### Diagnose DB connectivity

```bash
# Cek koneksi aktif ke DB primary (run di datalayer-1)
sudo -u postgres psql -c "SELECT client_addr, state FROM pg_stat_activity WHERE client_addr IS NOT NULL;"

# Test connectivity dari worker ke DB
ssh ec2-user@<worker_ip> "nc -zv 10.0.1.247 5432 -w 5"
```

### Cleanup stale state

```bash
# Restart Spark Master (clear stale apps)
$SPARK_HOME/sbin/stop-master.sh && $SPARK_HOME/sbin/start-master.sh --host 10.0.1.127

# Force terminate orphan workers
aws ec2 describe-instances --region ap-southeast-1 \
    --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=iot-bigdata-worker-ephemeral-*" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text | \
    xargs -I {} aws ec2 terminate-instances --region ap-southeast-1 --instance-ids {}
```

### Query benchmark results

```bash
sudo -u postgres psql -d iot_db -c "
SELECT
    worker_count,
    COUNT(*) as samples,
    ROUND(MIN(execution_time_sec)::numeric, 2) as min_s,
    ROUND(AVG(execution_time_sec)::numeric, 2) as avg_s,
    ROUND(MAX(execution_time_sec)::numeric, 2) as max_s
FROM spark_job_log
WHERE records_processed = 1000000 AND status = 'SUCCESS'
GROUP BY worker_count
ORDER BY worker_count;"
```

---

## Benchmark Procedure

### 1. Generate dataset

```bash
cd ~/iot-bigdata-project/spark-jobs
source .venv/bin/activate
python generate_bulk_data.py --records 1000000 --devices 20 --days 30 --upload
```

Output: S3 URI dari Parquet file.

### 2. Run benchmark dengan berbagai worker count

**Baseline (local mode, no ephemeral worker):**
```bash
spark-submit \
    --executor-memory 512m \
    --driver-memory 512m \
    --packages org.apache.hadoop:hadoop-aws:3.3.4,com.amazonaws:aws-java-sdk-bundle:1.12.261,org.postgresql:postgresql:42.7.4 \
    batch_analytics.py <s3_uri> 0
```

**Dengan ephemeral worker:**
```bash
./run_with_worker.sh <s3_uri> <worker_count>
```

### 3. Cek hasil

Execution time tercatat otomatis di tabel `spark_job_log`:

```sql
SELECT
    job_id,
    worker_count,
    records_processed,
    execution_time_sec,
    status
FROM spark_job_log
ORDER BY started_at DESC
LIMIT 10;
```

---

## Topology

```
applayer-1 (10.0.1.127)
├── Spark Master (port 7077, UI 8080)
├── Spark Driver (saat spark-submit)
└── PySpark venv

ephemeral worker (10.0.1.x)
├── Spark Worker
└── Executor → JDBC write ke datalayer-1

datalayer-1 (10.0.1.247)
└── PostgreSQL Primary

S3 (Data Lake)
└── Parquet files dibaca oleh Spark
```
