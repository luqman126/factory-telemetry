# Runbook: PostgreSQL 16 + TimescaleDB Setup

> Step-by-step setup DB Primary + Replica di Amazon Linux 2023 (EC2). Tested working — semua issue yang ditemui terdokumentasi di [Troubleshooting](#troubleshooting--common-issues).

---

## Topology

```
iot-bigdata-applayer-1 (App Layer, Public Subnet)
    │
    │  TCP 5432 (internal VPC)
    ▼
iot-bigdata-datalayer-1 (DB Primary)  ───── streaming replication ─────►  iot-bigdata-datalayer-2 (DB Replica)
    10.0.2.10 (Private Subnet)                                                      10.0.2.20 (Private Subnet)
```

**Naming convention:** `iot-bigdata-{layer}-{index}` (disiapkan untuk horizontal scaling).

| Pattern | Contoh | Role |
|---------|--------|------|
| `iot-bigdata-applayer-x` | `iot-bigdata-applayer-1` | FastAPI, MQTT, Grafana, Spark Master |
| `iot-bigdata-datalayer-x` | `iot-bigdata-datalayer-1` | PostgreSQL Primary/Replica |
| `iot-bigdata-worker-x` | `iot-bigdata-worker-1` | Ephemeral Spark workers |

---

## Setup datalayer-1 — Primary

### Prerequisites

- Amazon Linux 2023 (EC2 t3.small, di private subnet `10.0.2.0/24`)
- Security Group: inbound TCP 5432 dari `applayer-sg` dan `10.0.2.0/24`, inbound TCP 22 dari `applayer-sg`
- Akses SSH via applayer-1 (Bastion Host)

### 1. Install PostgreSQL 16

```bash
sudo dnf install -y postgresql16-server postgresql16-contrib postgresql16-private-devel
sudo postgresql-setup --initdb
```

### 2. Install TimescaleDB

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

### 3. Fix TimescaleDB paths (Amazon Linux 2023 compatibility)

Package TimescaleDB built for PGDG path layout, sedangkan PostgreSQL Amazon Linux pakai layout berbeda. Perlu symlink manual:

```bash
# .so files
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-tsl-2.27.1.so /usr/lib64/pgsql/

# Extension files
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/
```

### 4. Configure PostgreSQL

`postgresql.conf`:

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

`pg_hba.conf` (ganti `<db_user>` dan `<datalayer-2_ip>` dengan value actual):

```bash
sudo bash -c 'cat >> /var/lib/pgsql/data/pg_hba.conf <<EOF

# App + services (dari applayer-1 di public subnet)
host    all             <db_user>        10.0.1.0/24       scram-sha-256

# App + services (dari private subnet — Spark Worker, Grafana Alloy)
host    all             <db_user>        10.0.2.0/24       scram-sha-256

# Localhost (untuk Grafana Alloy Postgres exporter)
host    all             <db_user>        127.0.0.1/32      scram-sha-256

# Replication from datalayer-2 (private subnet)
host    replication     replicator       <datalayer-2_ip>/32   scram-sha-256
EOF'
```

### 5. Start PostgreSQL

```bash
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

### 6. Create users, database, replication slot

```bash
sudo -u postgres psql <<EOF
CREATE USER <db_user> WITH PASSWORD '<db_password>';
CREATE DATABASE <db_name> OWNER <db_user>;
GRANT ALL PRIVILEGES ON DATABASE <db_name> TO <db_user>;
CREATE USER replicator WITH REPLICATION PASSWORD '<db_password>';
SELECT pg_create_physical_replication_slot('replica_datalayer2_slot');

-- Grant monitoring permissions (untuk Grafana Alloy Postgres exporter)
GRANT pg_monitor TO <db_user>;
EOF
```

### 7. Initialize schema

```bash
# Copy init.sql ke node terlebih dahulu (scp db/init.sql <node>:/tmp/)
sudo -u postgres psql -d <db_name> -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
sudo -u postgres psql -d <db_name> -f /tmp/init.sql

# Fix table ownership
sudo -u postgres psql -d <db_name> -c "
ALTER TABLE sensor_readings OWNER TO <db_user>;
ALTER TABLE devices OWNER TO <db_user>;
ALTER TABLE analytics_results OWNER TO <db_user>;
ALTER TABLE anomaly_events OWNER TO <db_user>;
ALTER TABLE spark_job_log OWNER TO <db_user>;
"
```

### Verifikasi Primary

```bash
sudo systemctl status postgresql | head -5
sudo -u postgres psql -d <db_name> -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';"
sudo -u postgres psql -d <db_name> -c "\dt"
sudo -u postgres psql -d <db_name> -c "SELECT hypertable_name FROM timescaledb_information.hypertables;"
sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
sudo -u postgres psql -c "SHOW listen_addresses;"
sudo -u postgres psql -c "SHOW wal_level;"
```

---

## Setup datalayer-2 — Replica

### Prerequisites

- Amazon Linux 2023 (EC2 t3.small, di private subnet `10.0.2.0/24`, same spec as datalayer-1)
- Security Group: inbound TCP 5432 dari `applayer-sg` dan `10.0.2.0/24`, inbound TCP 22 dari `applayer-sg`
- datalayer-1 (primary) sudah running dan replication slot sudah dibuat
- Akses SSH via applayer-1 (Bastion Host)

### 1. Install PostgreSQL 16

```bash
sudo dnf install -y postgresql16-server postgresql16-contrib postgresql16-private-devel
```

> **Jangan** jalankan `postgresql-setup --initdb` — data directory akan diisi oleh `pg_basebackup`.

### 2. Install TimescaleDB

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

### 3. Fix TimescaleDB paths

```bash
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-tsl-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/
```

### 4. Base backup from primary

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

> Flag `-R` otomatis membuat `standby.signal` dan `primary_conninfo` di `postgresql.auto.conf`.

### 5. Configure replica settings

```bash
sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

# --- Replica settings ---
hot_standby = on
primary_slot_name = '"'"'replica_datalayer2_slot'"'"'
EOF'
```

### 6. Start PostgreSQL (replica mode)

```bash
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

### Verifikasi Replica

```bash
# Di datalayer-2 — harus return 't'
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Di datalayer-1 — harus ada 1 row, state = 'streaming'
sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

---

## Test Replication End-to-End

```bash
# Di datalayer-1 (primary) — insert test data
sudo -u postgres psql -d <db_name> -c "
INSERT INTO devices (device_id, device_name, location)
VALUES ('test_repl', 'Replication Test', 'test_area');
"

# Di datalayer-2 (replica) — harus muncul (tunggu 1-2 detik)
sudo -u postgres psql -d <db_name> -c "
SELECT * FROM devices WHERE device_id = 'test_repl';
"

# Cleanup
sudo -u postgres psql -d <db_name> -c "DELETE FROM devices WHERE device_id = 'test_repl';"
```

---

## Read Replica Utilization

Replica tidak hanya jadi standby — dimanfaatkan untuk **distribusi load** workload read-only.

### Strategi

| Workload | Target | Alasan |
|----------|--------|--------|
| Grafana dashboard panel | Replica (default) | Banyak query, bisa toleransi lag <1s |
| Grafana alert evaluation | Primary | Butuh data real-time |
| Backend FastAPI (insert) | Primary | Write-only |
| Spark `batch_analytics.py` (write hasil) | Primary | INSERT analytics + anomaly events |
| Spark `export_to_parquet.py` (read raw) | Replica | Large read query, time-tolerant |

### Setup

**1. Pastikan replica reachable dari applayer-1:**

```bash
nc -zv <datalayer-2_ip> 5432 -w 5
```

**2. Apply pg_hba.conf fix di replica:**

PostgreSQL replication hanya menyalin data, **bukan file konfigurasi**. Apply fix yang sama seperti di primary:

```bash
# SSH ke datalayer-2 via Bastion (applayer-1)
ssh -A ec2-user@<applayer-1-tailscale-ip>
ssh ec2-user@10.0.2.20

sudo grep "10.0" /var/lib/pgsql/data/pg_hba.conf

# Kalau masih ada literal <db_user>:
sudo sed -i 's/<db_user>/<actual_username>/' /var/lib/pgsql/data/pg_hba.conf
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

**3. Update `infra/.env` di applayer-1:**

```
POSTGRES_HOST=10.0.2.10           # primary (private subnet)
POSTGRES_HOST_REPLICA=10.0.2.20   # replica (private subnet)
```

**4. Recreate Grafana container** (env baru tidak ke-load oleh `restart` biasa):

```bash
cd ~/iot-bigdata-project/infra
docker compose up -d --force-recreate grafana
```

**5. Verifikasi:**

- Grafana UI → **Configuration → Data sources** → harus ada 2 datasource
- `TimescaleDB-Replica` ditandai sebagai **default**
- Test connection keduanya → "Database Connection OK"

### Verifikasi Load Distribution

Saat dashboard di-buka, koneksi aktif di replica:

```bash
# Di datalayer-2
sudo -u postgres psql -c "
SELECT client_addr, query_start, state
FROM pg_stat_activity
WHERE state IS NOT NULL AND client_addr IS NOT NULL;"
```

Harus ada koneksi dari applayer (`10.0.1.x`) yang query `sensor_readings`.

> **Note:** Akses SSH ke database nodes dilakukan via applayer-1 (Bastion Host) menggunakan SSH Agent Forwarding (`ssh -A`).
> Database nodes berada di private subnet tanpa Tailscale.

### Trade-off

| Aspek | Konsekuensi |
|-------|-------------|
| Replication lag | Data di replica beberapa milidetik di belakang. Tidak masalah untuk dashboard, fatal untuk alert (alert tetap di primary). |
| Replica down | Dashboard down. Mitigasi: update `POSTGRES_HOST_REPLICA` ke primary IP, recreate Grafana. |
| Failover | Setelah promote replica jadi primary, `POSTGRES_HOST_REPLICA` perlu diupdate ke IP rebuilt-replica. |

---

## Troubleshooting & Common Issues

### Setup Issues

#### `timescaledb-tune`: fork/exec pg_config: no such file

**Penyebab:** `postgresql16-private-devel` belum terinstall.

**Solusi:** Skip `timescaledb-tune` (opsional). Manual config `shared_preload_libraries` di `postgresql.conf` (sudah dilakukan di Step 4).

#### `could not access file "timescaledb"` saat PostgreSQL start

**Penyebab:** TimescaleDB `.so` tidak ada di path yang Amazon Linux PostgreSQL cari.

**Solusi:** Symlink files (sudah ada di Step 3).

#### `extension "timescaledb" is not available` saat CREATE EXTENSION

**Penyebab:** `.control` dan `.sql` files tidak di `/usr/share/pgsql/extension/`.

**Solusi:** Symlink files (sudah ada di Step 3).

#### `pg_basebackup: connection timed out`

**Penyebab:** Security group belum allow inbound 5432 dari IP replica.

**Solusi:** Update SG datalayer — allow inbound TCP 5432 dari `10.0.1.0/24` atau dari SG worker spesifik.

#### `pg_hba.conf entry for host` (literal `<db_user>` di file)

**Penyebab:** Saat setup manual, placeholder `<db_user>` tidak di-replace.

**Solusi:**
```bash
sudo sed -i 's/<db_user>/<actual_username>/' /var/lib/pgsql/data/pg_hba.conf
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

> **Penting:** Replication tidak menyalin file konfigurasi. Apply manual di replica juga.

### Application Layer Issues

#### Grafana alert error `result-set has errors that can be retried`

**Penyebab:** Alert query `sensor_readings` yang masih kosong/belum cukup data dalam time range.

**Solusi:** Bukan error kritis — hilang sendiri setelah data terkumpul. Tidak perlu action.

#### Grafana gagal start: `cannot unmarshal number into Go struct field Config.chatid` atau error parsing lainnya

**Penyebab:** Variabel `TELEGRAM_CHAT_ID_IOT` atau `TELEGRAM_CHAT_ID_SERVER` di `.env` salah format (misalnya menggunakan tanda minus, tanda kutip literal, atau kosong).

**Solusi:**
1. Pastikan di `.env` nilai chat ID ditulis bersih (hanya angka positif tanpa tanda minus `-` dan tanpa tanda kutip `"` atau `'`), contoh:
   ```env
   TELEGRAM_CHAT_ID_IOT=6526551624
   ```
2. Pastikan file `contact-points.yaml` mendefinisikan field `chatid` menggunakan block scalar `|` agar tidak terkena type coercion otomatis dari parser Grafana:
   ```yaml
   chatid: |
     ${TELEGRAM_CHAT_ID_IOT}
   ```
3. Recreate kontainer Grafana:
   ```bash
   docker compose down && docker compose up -d
   ```

#### Mosquitto: `passwd is not a file`

**Penyebab:** Docker auto-create mount target sebagai directory ketika file belum ada.

**Solusi:**
```bash
rm -rf mosquitto/passwd
touch mosquitto/passwd
source .env
docker run --rm -v $(pwd)/mosquitto:/mosquitto/config eclipse-mosquitto:2 \
    mosquitto_passwd -b /mosquitto/config/passwd "$MQTT_USER" "$MQTT_PASSWORD"
sudo chown root:root mosquitto/passwd
sudo chmod 644 mosquitto/passwd
docker compose restart mosquitto
```

#### Docker Compose tidak load env baru setelah restart

**Penyebab:** `docker compose restart` hanya restart proses di container existing — tidak baca ulang env vars.

**Solusi:** Pakai `docker compose up -d --force-recreate <service>`.

### Diagnostic Commands

#### Service & Extension Status

```bash
sudo systemctl status postgresql | head -5
sudo -u postgres psql -d iot_db -c "SELECT version();"
sudo -u postgres psql -d iot_db -c "\dx"
sudo -u postgres psql -d iot_db -c "\dt"
sudo -u postgres psql -d iot_db -c "SELECT hypertable_name FROM timescaledb_information.hypertables;"
```

#### Replication Health

**Di primary:**
```bash
sudo -u postgres psql -c "
SELECT client_addr, state, sent_lsn, replay_lsn, write_lag, replay_lag
FROM pg_stat_replication;"

sudo -u postgres psql -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

**Di replica:**
```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # harus 't'
sudo -u postgres psql -c "SELECT * FROM pg_stat_wal_receiver;"
```

#### Active Connections

```bash
sudo -u postgres psql -c "
SELECT pid, usename, client_addr, state, LEFT(query, 50) as query_snippet
FROM pg_stat_activity
WHERE state IS NOT NULL
ORDER BY backend_start;"
```

#### Reload vs Restart

```bash
# Reload config tanpa restart (untuk pg_hba.conf, postgresql.conf)
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# Full restart (perlu untuk shared_preload_libraries)
sudo systemctl restart postgresql
```

### Recovery: Replica Out-of-Sync

Kalau replication slot inactive lama, WAL bisa di-recycle dan replica perlu rebuild:

```bash
# Di replica
sudo systemctl stop postgresql
sudo rm -rf /var/lib/pgsql/data
sudo PGPASSWORD='<password>' pg_basebackup \
    -h <primary_ip> -U replicator -D /var/lib/pgsql/data \
    -Fp -Xs -P -R -S node3_replica_slot
sudo chown -R postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data
sudo systemctl start postgresql
```
