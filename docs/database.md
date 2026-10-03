# PostgreSQL & TimescaleDB Database Cluster Reference

This document outlines the database schema design, automated and manual installation processes, streaming replication configuration, read-replica load distribution strategy, and disaster recovery failover runbooks for the TimescaleDB cluster.

---

## 1. Database Schema & Hypertable Layout

The system uses TimescaleDB to handle high-frequency sensor ingestion efficiently.

### Raw Telemetry Schema (`sensor_readings`)
The primary table is `sensor_readings`. It is automatically converted into a TimescaleDB **hypertable** partitioned by 1-day intervals:

```sql
CREATE TABLE sensor_readings (
    time            TIMESTAMPTZ      NOT NULL,
    device_id       VARCHAR(64)      NOT NULL,
    location        VARCHAR(128)     NOT NULL,

    -- Suhu dan kelembaban
    temperature     DOUBLE PRECISION CHECK (temperature BETWEEN -10 AND 100),  -- Celsius
    humidity        DOUBLE PRECISION CHECK (humidity BETWEEN 0 AND 100),       -- %RH

    -- Accelerometer
    accel_x         DOUBLE PRECISION,   -- m/s²
    accel_y         DOUBLE PRECISION,   -- m/s²
    accel_z         DOUBLE PRECISION,   -- m/s²
    vibration_rms   DOUBLE PRECISION CHECK (vibration_rms >= 0),              -- m/s²

    -- Uap flux solder
    flux_ppm        DOUBLE PRECISION CHECK (flux_ppm >= 0),                   -- ppm
    flux_aqi        INTEGER          CHECK (flux_aqi BETWEEN 0 AND 500),      -- AQI
    voc_level       VARCHAR(16)      CHECK (voc_level IN ('GOOD', 'MODERATE', 'UNHEALTHY', 'HAZARDOUS'))
);

-- Convert to hypertable, partitioned by 1-day intervals
SELECT create_hypertable(
    'sensor_readings',
    'time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

-- Index for time-range queries per device
CREATE INDEX IF NOT EXISTS idx_sensor_device_time
    ON sensor_readings (device_id, time DESC);
```

### Static Devices Metadata Table (`devices`)
Stores metadata about the physical microcontrollers:

```sql
CREATE TABLE devices (
    device_id       VARCHAR(64)  PRIMARY KEY,
    device_name     VARCHAR(128) NOT NULL,
    location        VARCHAR(128) NOT NULL,
    registered_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    active          BOOLEAN      NOT NULL DEFAULT TRUE
);
```

### Aggregated Analytics Tables (`analytics_results` & `anomaly_events`)
Target tables for Spark batch analytics writes:

```sql
-- One row = one metric, one device, one time window
CREATE TABLE analytics_results (
    id              SERIAL          PRIMARY KEY,
    computed_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    window_start    TIMESTAMPTZ     NOT NULL,
    window_end      TIMESTAMPTZ     NOT NULL,
    device_id       VARCHAR(64)     NOT NULL,
    location        VARCHAR(128),
    metric_name     VARCHAR(64)     NOT NULL,
    metric_value    DOUBLE PRECISION,
    job_id          VARCHAR(64)     -- references spark_job_log.job_id
);

CREATE INDEX IF NOT EXISTS idx_analytics_device_window
    ON analytics_results (device_id, window_start DESC);

CREATE TABLE anomaly_events (
    id              SERIAL          PRIMARY KEY,
    detected_at     TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    event_time      TIMESTAMPTZ     NOT NULL,
    device_id       VARCHAR(64)     NOT NULL,
    location        VARCHAR(128),
    sensor_type     VARCHAR(32)     NOT NULL,
    observed_value  DOUBLE PRECISION,
    threshold_value DOUBLE PRECISION,
    z_score         DOUBLE PRECISION,
    severity        VARCHAR(16)     CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL'))
);

CREATE INDEX IF NOT EXISTS idx_anomaly_device_time
    ON anomaly_events (device_id, event_time DESC);
```

### Spark Pipeline Audit Log (`spark_job_log`)
Monitors the performance and metadata of Spark batch job runs:

```sql
CREATE TABLE spark_job_log (
    id                  SERIAL          PRIMARY KEY,
    job_id              VARCHAR(64)     NOT NULL UNIQUE,
    started_at          TIMESTAMPTZ,
    finished_at         TIMESTAMPTZ,
    worker_count        INTEGER         NOT NULL DEFAULT 0,
    records_processed   BIGINT,
    execution_time_sec  DOUBLE PRECISION,
    status              VARCHAR(16)     CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    notes               TEXT
);
```

### Data Retention Policy
To prevent disk exhaustion on the database nodes, a **90-day** data retention policy is applied to the raw telemetry hypertable:

```sql
SELECT add_retention_policy(
    'sensor_readings',
    INTERVAL '90 days',
    if_not_exists => TRUE
);
```

Historical raw data older than 90 days is automatically dropped by a TimescaleDB background job, since it has already been archived to the S3 Data Lake as Parquet files.

### Compression Policy
To reduce storage on the primary node, chunks older than 7 days are automatically compressed. Older chunks are rarely written back, so compression is safe and transparent to read queries:

```sql
ALTER TABLE sensor_readings SET (
    timescaledb.compress,
    timescaledb.compress_orderby   = 'time DESC',
    timescaledb.compress_segmentby = 'device_id'
);

SELECT add_compression_policy(
    'sensor_readings',
    INTERVAL '7 days',
    if_not_exists => TRUE
);
```

---

## 2. Cluster Topology & Network Routing

The database nodes are deployed inside the private subnet (`10.x.2.0/24`) and have no public IPs or direct internet access.

```
applayer-1 (App Layer, Public Subnet)
    │
    │  TCP 5432 (internal VPC)
    ▼
datalayer-1 (DB Primary)  ───── streaming replication ─────►  datalayer-2 (DB Standby)
  10.x.2.10 (Private Subnet)                                   10.x.2.20 (Private Subnet)
```

- **Primary IP (Staging):** `10.1.2.10`
- **Standby IP (Staging):** `10.1.2.20`

---

## 3. Streaming Replication Architecture

To ensure high availability and prevent single points of failure, the cluster uses PostgreSQL physical streaming replication:

- **Slot-based Replication:** We use an active physical replication slot named `replica_datalayer2_slot` on the primary node. This prevents the primary from recycling Write-Ahead Logs (WAL) before they are consumed by the replica, protecting the standby from falling out of sync.
- **Settings configuration:**
  - **Primary (`datalayer-1`):** `wal_level = replica`, `max_wal_senders = 3`, `max_replication_slots = 3`.
  - **Standby (`datalayer-2`):** `hot_standby = on`, `primary_slot_name = 'replica_datalayer2_slot'`.

---

## 4. Database Provisioning & Installation

### Option A: Automated Offline Provisioning (Recommended)

For staging environments and automated rebuilds, database installation and configuration run 100% offline via S3 VPC Gateway Endpoint (as private nodes have no internet access):

1. **Synchronize Packages and Scripts from the Bastion (`applayer-1`):**
   Run the sync script on the Bastion Host:
   ```bash
   cd ~/factory-telemetry
   chmod +x infra/scripts/sync-packages-to-s3.sh
   ./infra/scripts/sync-packages-to-s3.sh
   ```
   This script:
   - Downloads PostgreSQL 16, TimescaleDB, and Grafana Alloy RPMs with dependencies locally.
   - Uploads RPM packages to `s3://<bucket-name>/packages/`.
   - Uploads provisioning scripts (`infra/scripts/*`) and schema SQL to `s3://<bucket-name>/scripts/`.
   - Fetches DB credentials from SSM and uploads them as temporary `s3://<bucket-name>/secrets/db-secrets.env`.
   - Creates a sentinel `packages/sync_complete.flag` file using `s3api put-object`.

2. **Automated Bootstrapping via Terraform User Data:**
   When provisioning database instances, the `user_data` script:
   - Polls S3 waiting for `sync_complete.flag`.
   - Downloads the RPMs, scripts, and secrets.
   - Executes [provision-db-primary.sh](file:///home/cheshire/factory-telemetry/infra/scripts/provision-db-primary.sh) (on `datalayer-1`) or [provision-db-replica.sh](file:///home/cheshire/factory-telemetry/infra/scripts/provision-db-replica.sh) (on `datalayer-2`) locally.

3. **Manual Trigger of Provisioning Scripts (if needed):**
   If you need to re-run the provisioning on running VMs:
   ```bash
   # On datalayer-1 (Primary)
   sudo ./provision-db-primary.sh <db_name> <db_user> <db_password> <replica_ip>

   # On datalayer-2 (Replica)
   sudo ./provision-db-replica.sh <primary_ip> <db_password>
   ```

---

### Option B: Manual Setup Step-by-Step (For Reference & Debugging)

#### 1. Install PostgreSQL 16
```bash
sudo dnf install -y postgresql16-server postgresql16-contrib postgresql16-private-devel
sudo postgresql-setup --initdb
```

#### 2. Install TimescaleDB
```bash
sudo bash -c 'cat > /etc/yum.repos.d/timescaledb.repo <<EOF
[timescaledb]
name=TimescaleDB
baseurl=https://packagecloud.io/timescale/timescaledb/el/9/\$basearch
gpgcheck=0
enabled=1
EOF'

sudo dnf install -y timescaledb-2-postgresql-16
```

#### 3. Fix TimescaleDB Paths (Amazon Linux 2023 Compatibility)
TimescaleDB builds assume the standard PGDG path layout, while Amazon Linux uses a custom PostgreSQL structure. Create symbolic links:
```bash
# .so files
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-tsl-2.27.1.so /usr/lib64/pgsql/

# Extension configuration and SQL files
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/
```

#### 4. Configure PostgreSQL Configuration Files
Append settings to `/var/lib/pgsql/data/postgresql.conf`:
```bash
sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

# --- TimescaleDB ---
shared_preload_libraries = '"'"'timescaledb'"'"'

# --- Replication (Primary) ---
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
listen_addresses = '"'"'*'"'"'
EOF'
```

Append host rules to `/var/lib/pgsql/data/pg_hba.conf` (replace `<db_user>` and `<datalayer-2_ip>` with your actual values):
```bash
sudo bash -c 'cat >> /var/lib/pgsql/data/pg_hba.conf <<EOF

# App layer (FastAPI backend on applayer-1 in public subnet)
host    all             <db_user>        10.0.1.0/24       scram-sha-256

# Private subnet (Spark workers, Grafana Alloy)
host    all             <db_user>        10.0.2.0/24       scram-sha-256

# Localhost (Alloy local scrapers)
host    all             <db_user>        127.0.0.1/32      scram-sha-256

# Replication traffic from datalayer-2
host    replication     replicator       <datalayer-2_ip>/32   scram-sha-256
EOF'
```

#### 5. Start PostgreSQL
```bash
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

#### 6. Create Users, Databases, and Replication Slots
```bash
sudo -u postgres psql <<EOF
CREATE USER <db_user> WITH PASSWORD '<db_password>';
CREATE DATABASE <db_name> OWNER <db_user>;
GRANT ALL PRIVILEGES ON DATABASE <db_name> TO <db_user>;
CREATE USER replicator WITH REPLICATION PASSWORD '<db_password>';
SELECT pg_create_physical_replication_slot('replica_datalayer2_slot');

-- Grant monitoring permissions for Grafana Alloy Exporter
GRANT pg_monitor TO <db_user>;
EOF
```

#### 7. Initialize Database Schema
```bash
# Copy init.sql to node (scp db/init.sql to /tmp/ first)
sudo -u postgres psql -d <db_name> -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
sudo -u postgres psql -d <db_name> -f /tmp/init.sql

# Set proper table ownerships
sudo -u postgres psql -d <db_name> -c "
ALTER TABLE sensor_readings OWNER TO <db_user>;
ALTER TABLE devices OWNER TO <db_user>;
ALTER TABLE analytics_results OWNER TO <db_user>;
ALTER TABLE anomaly_events OWNER TO <db_user>;
ALTER TABLE spark_job_log OWNER TO <db_user>;
"
```

#### 8. Verify Primary Settings
```bash
sudo systemctl status postgresql | head -5
sudo -u postgres psql -d <db_name> -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';"
sudo -u postgres psql -d <db_name> -c "\dt"
sudo -u postgres psql -d <db_name> -c "SELECT hypertable_name FROM timescaledb_information.hypertables;"
sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
```

---

### Standby Node (`datalayer-2`) Manual Setup

Install PostgreSQL and TimescaleDB following Steps 1-3. Do **not** run `postgresql-setup --initdb` as the data directory will be synchronized from the primary.

1. **Perform pg_basebackup:**
   ```bash
   sudo rm -rf /var/lib/pgsql/data
   sudo PGPASSWORD='<db_password>' pg_basebackup \
       -h <datalayer-1_ip> \
       -U replicator \
       -D /var/lib/pgsql/data \
       -Fp -Xs -P -R \
       -S replica_datalayer2_slot

   sudo chown -R postgres:postgres /var/lib/pgsql/data
   sudo chmod 700 /var/lib/pgsql/data
   ```
   The `-R` flag automatically creates `standby.signal` and configures connection parameters in `postgresql.auto.conf`.

2. **Configure Replica Settings:**
   Append parameters to `/var/lib/pgsql/data/postgresql.conf`:
   ```bash
   sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

   # --- Replica settings ---
   hot_standby = on
   primary_slot_name = '"'"'replica_datalayer2_slot'"'"'
   EOF'
   ```

3. **Start PostgreSQL in Replica Mode:**
   ```bash
   sudo systemctl enable postgresql
   sudo systemctl start postgresql
   ```

4. **Verify Replica Status:**
   ```bash
   # On datalayer-2: Must return 't'
   sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

   # On datalayer-1: Verify streaming status
   sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
   ```

---

## 5. Read Replica Utilization Strategy

To protect primary write operations, read-only workloads are offloaded to the standby replica:

| Workload | Target | Rationale |
|:---|:---|:---|
| FastAPI Backend writes (ingestion) | Primary | Dynamic sensor data writes |
| Grafana dashboard panel queries | Standby Replica | Can tolerate sub-second replication lag |
| Grafana alert evaluation rules | Primary | Must evaluate real-time data to prevent delays |
| Spark `export_to_parquet.py` reads | Standby Replica | Massive read query, execution can lag slightly |
| Spark `batch_analytics.py` writes | Primary | Writes analytical rollups and anomaly logs |

### Setup Configuration
1. **Apply pg_hba.conf configurations to both nodes.** Configuration changes are not replicated automatically. Use matching client connection rules on both primary and standby.
2. **Update Environment configuration** on `applayer-1`:
   ```env
   POSTGRES_HOST=10.x.2.10           # Primary IP
   POSTGRES_HOST_REPLICA=10.x.2.20   # Replica IP
   ```
3. **Recreate Grafana Container:**
   ```bash
   cd ~/factory-telemetry/infra
   docker compose up -d --force-recreate grafana
   ```

---

## 6. Disaster Recovery: Manual Failover SOP

If the primary database (`datalayer-1`) fails, follow this procedure to promote the standby replica (`datalayer-2`) to write mode and restore services.

### Phase 1: Verify Primary Failure
Confirm `datalayer-1` is down (check service status and SSH connectivity). 

### Phase 2: Promote Standby Database
On `datalayer-2` (standby), run:
```bash
sudo -u postgres psql -c "SELECT pg_promote();"
```
Verify the standby is now out of recovery:
```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Expected output: 'f'
```
The database will delete `standby.signal`, increment the timeline ID, and accept read-write traffic.

### Phase 3: Redirect Application Traffic
1. **On `applayer-1`:**
   Modify `infra/.env` to route traffic to the promoted primary:
   ```env
   POSTGRES_HOST=10.x.2.20
   POSTGRES_HOST_REPLICA=10.x.2.20 # Temporary fallback
   ```
2. **Restart Services:**
   ```bash
   cd ~/factory-telemetry/infra
   docker compose up -d --force-recreate grafana
   sudo systemctl restart iot-backend
   ```
3. **Verify Connection:**
   Run `curl localhost:8000/health` to confirm the backend connects successfully.

---

### Phase 4: Rebuild Old Primary (`datalayer-1`) as the Standby Replica
Once the failed node is online again, reconfigure it as the standby replica.

1. **On the new primary (`datalayer-2`), create a new replication slot:**
   ```bash
   sudo -u postgres psql -c "SELECT pg_create_physical_replication_slot('replica_datalayer1_slot');"
   ```
   Add replica configuration rules to `/var/lib/pgsql/data/pg_hba.conf`:
   ```
   host    replication     replicator       10.x.2.10/32     scram-sha-256
   ```
   Reload database configurations:
   ```bash
   sudo -u postgres psql -c "SELECT pg_reload_conf();"
   ```

2. **On the old primary (`datalayer-1`):**
   ```bash
   sudo systemctl stop postgresql
   sudo rm -rf /var/lib/pgsql/data

   # Perform pg_basebackup from new primary (10.x.2.20)
   sudo PGPASSWORD='<db_password>' pg_basebackup \
       -h 10.x.2.20 \
       -U replicator \
       -D /var/lib/pgsql/data \
       -Fp -Xs -P -R \
       -S replica_datalayer1_slot

   sudo chown -R postgres:postgres /var/lib/pgsql/data
   sudo chmod 700 /var/lib/pgsql/data
   ```

3. **Append replica configuration to `/var/lib/pgsql/data/postgresql.conf`:**
   ```bash
   sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

   # --- Replica settings ---
   hot_standby = on
   primary_slot_name = '"'"'replica_datalayer1_slot'"'"'
   EOF'
   ```

4. **Start PostgreSQL in replica mode:**
   ```bash
   sudo systemctl start postgresql
   ```

5. **Update replication host variables** on `applayer-1`:
   ```bash
   cd ~/factory-telemetry/infra
   sed -i 's/^POSTGRES_HOST_REPLICA=.*/POSTGRES_HOST_REPLICA=10.x.2.10/' .env
   docker compose up -d --force-recreate grafana
   ```

The database roles are now swapped. `datalayer-2` is the active Primary, and `datalayer-1` is the active Standby.

---

### Phase 5: Rollback to Initial State
To restore the original topology (with `datalayer-1` as Primary and `datalayer-2` as Standby), execute the failover procedure in reverse:

1. Stop PostgreSQL on `datalayer-2`.
2. Promote `datalayer-1` using `SELECT pg_promote();`.
3. Update `POSTGRES_HOST` and `POSTGRES_HOST_REPLICA` on `applayer-1` back to `10.x.2.10`. Restart backend services.
4. On `datalayer-1` (Primary), run `SELECT pg_create_physical_replication_slot('replica_datalayer2_slot');`.
5. Rebuild `datalayer-2` as standby using `pg_basebackup` from `10.x.2.10` with slot `replica_datalayer2_slot`. Ensure `pg_hba.conf` rules on both nodes are correctly configured.

---

## 7. Operational Troubleshooting

### Replication Slot WAL Bloat
If the standby replica goes offline permanently while its replication slot remains active on the primary, the primary will retain WAL segments indefinitely. This will eventually lead to database disk exhaustion.
- **Mitigation:** Monitor disk space on the primary. If the standby node cannot be recovered, drop the active slot from the primary node:
  ```sql
  SELECT pg_drop_replication_slot('replica_datalayer2_slot');
  ```

### Split-Brain Prevention
When promoting a standby, there is a risk that the failed primary node comes online again, resulting in two active write primary nodes.
- **Mitigation:** Ensure the failed node is fully offline or postgresql is stopped before promotion. Never start PostgreSQL on the failed primary until it has been completely wiped and rebuilt using `pg_basebackup`.

---

## 8. Database Schema Migrations (dbmate)

To maintain a strict, reproducible history of schema changes across environments, the project uses `dbmate` for database migrations.

### Migration Strategy
- `dbmate` is executed as a **one-shot CI/CD job** rather than a persistent background daemon. It applies the schema delta and exits immediately.
- Migrations are triggered manually or via automation using the wrapper script: `db/run_migrations.sh`.
- The tool maintains an internal `schema_migrations` table to track which migrations have already been applied, ensuring idempotency.

### Naming Conventions
Migrations strictly follow the **14-digit timestamp naming convention** (e.g., `20260829000000_wide_column_analytics.sql`) rather than sequential numbering (`001_migration.sql`). 
This prevents merge conflicts in version control when multiple developers are creating migrations simultaneously, aligning with industry best practices for schema management.
