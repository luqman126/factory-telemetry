# Runbook: Spark Cluster Setup & Benchmarking

> Dokumentasi setup Spark Master di applayer-1 + ephemeral worker pipeline,
> berdasarkan pengalaman setup 25 Mei 2026.

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
