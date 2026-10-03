# Apache Spark Batch Analytics & Scaling Benchmarks

This document describes the design, execution logic, and performance evaluations of the PySpark batch processing pipeline.

---

## 1. Arsitektur Big Data Pipeline

The analytical pipeline is orchestrated by a systemd hourly timer (`iot-analytics.timer`) on `applayer-1` that triggers `run_hourly_pipeline.sh`. The workflow consists of two main steps:

```text
  [TimescaleDB Standby]
           │
           │ 1. export_to_parquet.py (Incremental Export)
           ▼
     [Amazon S3 Data Lake]
           │
           │ 2. batch_analytics.py (PySpark aggregation & anomalies)
           ▼
  [TimescaleDB Primary] (Write aggregate tables)
```

### Step 1: Incremental S3 Export (`export_to_parquet.py`)
To prevent heavy analytics queries from locking database tables, the export script connects directly to the read-only standby database (`datalayer-2`). It pulls the last hour of raw sensor readings, packages them into a schema-validated Parquet dataset, and uploads them to the S3 bucket using the partition prefix format:
`s3://<bucket-name>/raw/year=YYYY/month=MM/day=DD/hour=HH/`

### Step 2: Aggregation & Anomaly Rollup (`batch_analytics.py`)
A PySpark application starts, reads the exported Parquet partition from S3, and executes:
- **Averages & Rollups:** Computes mean temperature, humidity, and vibration RMS for each active `device_id`.
- **Vibration Anomaly Detection:** Identifies spikes where the standard deviation of vibration exceeds historical thresholds.
- **Database Sync:** Writes processed aggregates back to the database primary (`datalayer-1`) tables: `analytics_results` and `anomaly_events`.

---

## 2. Distributed Computing Model

For large datasets, the master node coordinates tasks across worker executors:

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

- **Lazy evaluation:** Spark builds a Directed Acyclic Graph (DAG) of transformations and only executes them when an action is called.
- **In-memory caching:** `df.cache()` stores data in executor RAM, avoiding repeated S3 reads.
- **Partitioning:** Data is split into N partitions. Each partition represents 1 task and 1 unit of parallelism.

### Spark Job DAG Steps
1. **Stage 0 (Read):** Reads Parquet from S3 into 1 initial partition.
2. **Stage 1 (Repartition Shuffle):** Redistributes data into N partitions where N equals double the worker core count.
3. **Stage 2 (Cache Materialization):** Triggered by an action to materialize and store the cached dataframe in memory.
4. **Stage 3 (Aggregation):** Executes `groupBy` aggregations and collects results back to the driver.
5. **Stage 4 (JDBC write):** Filters anomalies, merges data paths, and writes directly to database target tables in parallel.

---

## 3. Ephemeral AWS Spark Workers

To minimize AWS infrastructure costs, worker nodes are launched dynamically only when a job runs:

### Orchestration Script (`run_with_worker.sh`)
Running on `applayer-1`, this script automates the cluster lifecycle:
1. **Launch:** Spins up N ephemeral EC2 worker instances (`t3.small`) using a custom AMI containing Java 21 and Apache Spark. These are launched in the private subnet.
2. **Attach:** Workers boot up, launch the Spark worker service, and register with the Spark Master running on `applayer-1`.
3. **Execute:** The script submits the PySpark job to the Master coordinator.
4. **Tear-down:** Once the job completes, the orchestrator issues a `terminate-instances` AWS API call, reducing idle compute costs to zero.

---

## 4. Setup Spark Master on `applayer-1`

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

### 3. Configure Directories and Permissions
Create logs and work directories and assign permissions:
```bash
sudo mkdir -p /opt/spark/logs /opt/spark/work
sudo chown -R ec2-user:ec2-user /opt/spark/logs /opt/spark/work
```

### 4. Set Environment Variables
Append paths to `/etc/profile.d/spark.sh`:
```bash
echo 'export SPARK_HOME=/opt/spark' | sudo tee /etc/profile.d/spark.sh
echo 'export PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin' | sudo tee -a /etc/profile.d/spark.sh
source /etc/profile.d/spark.sh
```

### 5. Start Spark Master
```bash
SPARK_LOCAL_IP=$(hostname -I | awk '{print $1}')
$SPARK_HOME/sbin/start-master.sh --host $SPARK_LOCAL_IP
```

---

## 5. Setup Systemd Timer Automation

To automate the hourly Spark pipeline, configure a systemd timer on `applayer-1`.

### 1. Script: `run_hourly_pipeline.sh`
The coordinator script located at `spark-jobs/run_hourly_pipeline.sh`:
- Loads environments from `infra/.env`.
- Runs `export_to_parquet.py` under the virtual environment.
- Checks if new telemetry exists. If none, exits gracefully (`exit 0`).
- If telemetry is present, runs `spark-submit` in local mode (`local[*]`) to process aggregations.

### 2. Register Service and Timer
Copy configuration files:
```bash
chmod +x ~/factory-telemetry/spark-jobs/run_hourly_pipeline.sh
sudo cp ~/factory-telemetry/infra/systemd/iot-analytics.service /etc/systemd/system/
sudo cp ~/factory-telemetry/infra/systemd/iot-analytics.timer /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl start iot-analytics.service
sudo systemctl enable --now iot-analytics.timer
```

---

## 6. Scaling Benchmarks & Amdahl's Law Validation

To evaluate the efficiency of the ephemeral scaling model, we ran benchmarks on `t3.small` nodes (1 vCPU, 2GB RAM, 30GB EBS) with two dataset sizes:

### Results Matrix: 1,000,000 Records (~64MB)
| Scenario | Active Workers | Min Duration | Avg Duration | Max Duration |
|:---|:---|:---|:---|:---|
| **Local Mode** | 0 | 27.45 s | 28.56 s | 30.33 s |
| **1 Worker** | 1 | 42.30 s | 42.47 s | 42.63 s |
| **2 Workers** | 2 | 44.13 s | 44.13 s | 44.13 s * |

*\* High variance due to memory starvation and GC pauses prior to tuning.*

### Results Matrix: 5,000,000 Records (~320MB)
*With optimized partitioning (20 partitions) and physical disk spilling (`SPARK_LOCAL_DIRS`).*

| Scenario | Active Workers | Duration | Network/Read Time | DB Write Time |
|:---|:---|:---|:---|:---|
| **1 Worker** | 1 | **155.77 s** | 38 s | 94 s |
| **2 Workers** | 2 | **211.29 s** | 68 s | 116 s |

### Analysis: Negative Scaling
This experiment demonstrated **negative scaling** (distributed cluster runs slower than local single-node runs). This is explained by two systems engineering constraints:

#### 1. Network & JVM Coordination Overhead
For small datasets (<100MB), the serialization, network transfer (over S3/internal network), JVM executor startup, and partition coordination overhead outweigh the benefits of parallel compute. S3 read throughput and network socket latency become the main bottlenecks.

#### 2. Amdahl's Law & Hardware Constraints
Amdahl's Law dictates that the maximum speedup of a program is limited by the time needed for its sequential components:
$$\text{Speedup}(S) = \frac{1}{(1 - P) + \frac{P}{N}}$$
Where:
- $P$ is the parallel proportion of the job.
- $N$ is the number of processors.

In our pipeline, database writes (JDBC connection overhead to a single database primary) and S3 API call latency represent massive sequential portions ($1 - P$). Adding worker nodes ($N$) only reduces the tiny parallel portion (in-memory aggregation of 64MB data), which takes less than a second anyway, while increasing scheduling and coordination costs.

### Stress Test: 5,000,000 Records in Local Mode (Fatal Crash)
To validate the absolute necessity of the Ephemeral Worker architecture, we attempted to process the 5,000,000 record (~320MB) dataset entirely on the `applayer-1` master node using `local[*]` mode (0 workers).

**The result was a catastrophic host failure.** 

1. **Partition Trap:** In local mode (`worker_count == 0`), the dynamic `df.repartition()` logic is bypassed. Spark read the massive dataset into a single giant partition.
2. **Memory Exhaustion:** The `run_hourly_pipeline.sh` script restricts `local[*]` mode to `512m` of JVM heap. The uncompressed Parquet objects instantly overwhelmed this limit.
3. **RAM Disk Spill (OOM Panic):** Out of memory, Spark attempted to persist data to disk (`BlockManager: Persisting block rdd_6_0 to disk instead`). However, because `SPARK_LOCAL_DIRS` was not explicitly set for the master, it spilled to the OS default `/tmp` directory. On Amazon Linux 2023, `/tmp` is a `tmpfs` (RAM disk). This instantly exhausted the remaining physical RAM on the `t3.small` instance, starving the OS, FastAPI, and Grafana.
4. **Conclusion:** The kernel triggered an OOM panic and the instance completely locked up, requiring a total `terraform apply` rebuild of the `applayer` node.

**Final Conclusion:** Ephemeral distributed scaling is mathematically slower for small datasets (due to Amdahl's Law), but it is **architecturally mandatory** for large datasets. Offloading heavy compute to worker nodes is the only way to protect the Master node from fatal Out-Of-Memory crashes.

---

## 7. Troubleshooting & Diagnostics

### Worker fails with `createDirectory permission denied`
- **Cause:** `/opt/spark` is owned by root, but the worker process runs as `ec2-user`.
- **Solution:** Run `sudo chown -R ec2-user:ec2-user /opt/spark/logs /opt/spark/work`.

### `Initial job has not accepted any resources`
- **Cause:** Spark Master cannot register workers, or executor memory parameters are misconfigured, or security groups are blocking communication.
- **Solution:** Check the Master web portal (`http://<master-ip>:8080`). Set `--executor-memory 1g` if workers lack capacity. Ensure security groups allow inbound communication between the Master and workers.

### Driver binds to Tailscale IP instead of VPC IP
- **Cause:** The host has multiple active network interfaces, and Spark default routing chooses the Tailscale address.
- **Solution:** Add explicit driver binding parameters during `spark-submit`:
  ```bash
  --conf spark.driver.host=<vpc_ip>
  --conf spark.driver.bindAddress=<vpc_ip>
  ```

### Worker cannot access S3 (Stage 0 hangs)
- **Cause:** Private subnet nodes cannot reach public endpoints.
- **Solution:** Configure a VPC Gateway Endpoint for S3 in the private subnet route tables.

### Executor Heartbeat Timeout / Worker Lost
- **Cause:** Executor GC pause takes too long due to memory pressure on small nodes.
- **Solution:** Upgrade worker instances to `t3.medium` (4GB RAM) or larger, increase `--executor-memory`, and run JVM garbage collection tuning options.
