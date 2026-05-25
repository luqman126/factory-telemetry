# Runbook: Setup PostgreSQL 16 + TimescaleDB on Amazon Linux 2023

> Dokumentasi step-by-step yang **benar-benar berhasil** untuk setup DB Primary + Replica
> di Amazon Linux 2023 (EC2). Berdasarkan pengalaman setup 24 Mei 2026.

---

## Known Issues & Lessons Learned

| Issue | Penyebab | Solusi |
|-------|----------|--------|
| `timescaledb-tune`: fork/exec pg_config: no such file or directory | Package `postgresql16-private-devel` belum terinstall saat `timescaledb-tune` dijalankan | Skip `timescaledb-tune`, manual config `shared_preload_libraries` di postgresql.conf |
| `could not access file "timescaledb": No such file or directory` saat PostgreSQL start | TimescaleDB package (el9/PGDG) install `.so` ke path berbeda dari Amazon Linux PostgreSQL | Symlink `.so` files ke `/usr/lib64/pgsql/` |
| `extension "timescaledb" is not available` saat CREATE EXTENSION | `.control` dan `.sql` files tidak ada di `/usr/share/pgsql/extension/` | Symlink `.control` dan `--*.sql` files ke `/usr/share/pgsql/extension/` |
| `pg_basebackup: connection timed out` | Security group belum allow inbound 5432 dari IP replica | Update SG: allow inbound TCP 5432 dari `10.0.1.0/24` |

**Root cause utama:** PostgreSQL dari Amazon Linux repo (`@amazonlinux`) dan TimescaleDB dari packagecloud (`@timescaledb`, built for PGDG el9) menggunakan directory layout yang berbeda. Perlu symlink manual.

---

## Node 2 — DB Primary (iot-bigdata-datalayer-1)

### Prerequisites
- Amazon Linux 2023 (EC2 t3.small)
- Security Group: inbound TCP 5432 dari `10.0.1.0/24`

### Step 1: Install PostgreSQL 16

```bash
sudo dnf install -y postgresql16-server postgresql16-contrib postgresql16-private-devel
sudo postgresql-setup --initdb
```

### Step 2: Install TimescaleDB

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

### Step 3: Fix TimescaleDB paths (Amazon Linux 2023 compatibility)

```bash
# .so files
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-tsl-2.27.1.so /usr/lib64/pgsql/

# Extension control file
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/

# Extension SQL files
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/
```

### Step 4: Configure PostgreSQL

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

```bash
sudo bash -c 'cat >> /var/lib/pgsql/data/pg_hba.conf <<EOF

# App node + services (subnet)
host    all             <db_user>        10.0.1.0/24       scram-sha-256

# Replication from Node 3
host    replication     replicator       <node3_ip>/32     scram-sha-256
EOF'
```

### Step 5: Start PostgreSQL

```bash
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

### Step 6: Create users, database, replication slot

```bash
sudo -u postgres psql <<EOF
CREATE USER <db_user> WITH PASSWORD '<db_password>';
CREATE DATABASE <db_name> OWNER <db_user>;
GRANT ALL PRIVILEGES ON DATABASE <db_name> TO <db_user>;
CREATE USER replicator WITH REPLICATION PASSWORD '<db_password>';
SELECT pg_create_physical_replication_slot('node3_replica_slot');
EOF
```

### Step 7: Initialize schema

```bash
# Copy init.sql ke node terlebih dahulu (scp db/init.sql <node>:/tmp/)
sudo -u postgres psql -d <db_name> -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
sudo -u postgres psql -d <db_name> -f /tmp/init.sql

# Fix ownership
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
sudo -u postgres psql -c "\du"
sudo -u postgres psql -c "SHOW listen_addresses;"
sudo -u postgres psql -c "SHOW wal_level;"
```

---

## Node 3 — DB Replica (iot-bigdata-datalayer-2)

### Prerequisites
- Amazon Linux 2023 (EC2 t3.small, same spec as Node 2)
- Security Group: inbound TCP 5432 dari `10.0.1.0/24`
- Node 2 (primary) sudah running dan replication slot sudah dibuat

### Step 1: Install PostgreSQL 16

```bash
sudo dnf install -y postgresql16-server postgresql16-contrib postgresql16-private-devel
```

> **Jangan** jalankan `postgresql-setup --initdb` — data directory akan diisi oleh `pg_basebackup`.

### Step 2: Install TimescaleDB

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

### Step 3: Fix TimescaleDB paths

```bash
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb-tsl-2.27.1.so /usr/lib64/pgsql/
sudo ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/
sudo ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/
```

### Step 4: Base backup from primary

```bash
sudo rm -rf /var/lib/pgsql/data

sudo PGPASSWORD='<db_password>' pg_basebackup \
    -h <node2_private_ip> \
    -U replicator \
    -D /var/lib/pgsql/data \
    -Fp -Xs -P -R \
    -S node3_replica_slot

sudo chown -R postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data
```

> Flag `-R` otomatis membuat `standby.signal` dan `primary_conninfo` di `postgresql.auto.conf`.

### Step 5: Configure replica settings

```bash
sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

# --- Replica settings ---
hot_standby = on
primary_slot_name = '"'"'node3_replica_slot'"'"'
EOF'
```

### Step 6: Start PostgreSQL (replica mode)

```bash
sudo systemctl enable postgresql
sudo systemctl start postgresql
```

### Verifikasi Replica

```bash
# Di Node 3 — harus return 't'
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Di Node 2 — harus ada 1 row, state = 'streaming'
sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, replay_lsn FROM pg_stat_replication;"
```

---

## Test Replication End-to-End

```bash
# Di Node 2 (primary) — insert test data
sudo -u postgres psql -d <db_name> -c "
INSERT INTO devices (device_id, device_name, location)
VALUES ('test_repl', 'Replication Test', 'test_area');
"

# Di Node 3 (replica) — harus muncul
sudo -u postgres psql -d <db_name> -c "
SELECT * FROM devices WHERE device_id = 'test_repl';
"

# Cleanup
sudo -u postgres psql -d <db_name> -c "DELETE FROM devices WHERE device_id = 'test_repl';"
```

---

## Topology Summary

```
iot-bigdata-applayer-1 (Node 1 — App Layer)
    │
    │  TCP 5432
    ▼
iot-bigdata-datalayer-1 (Node 2 — DB Primary) ─── streaming replication ───► iot-bigdata-datalayer-2 (Node 3 — DB Replica)
    10.0.1.247                                                                  10.0.1.78
```

### Naming Convention

```
iot-bigdata-{layer}-{index}
```

| Pattern | Contoh | Keterangan |
|---------|--------|------------|
| `iot-bigdata-applayer-x` | `iot-bigdata-applayer-1` | Application layer (FastAPI, MQTT, Grafana, Spark Master) |
| `iot-bigdata-datalayer-x` | `iot-bigdata-datalayer-1` | Database layer (PostgreSQL Primary/Replica) |
| `iot-bigdata-worker-x` | `iot-bigdata-worker-1` | Ephemeral Spark workers |

> Index dimulai dari 1. Naming disiapkan untuk horizontal scaling (pool) di masa depan.

---

## Post-Setup Issues & Fixes

### Grafana alert rule error setelah fresh deploy

**Gejala:** Log Grafana menampilkan `the result-set has errors that can be retried` berulang.

**Penyebab:** Alert rules query `sensor_readings` yang masih kosong atau belum punya data dalam time range yang di-evaluate. Grafana alert evaluator retry terus sampai data tersedia.

**Solusi:** Bukan error kritis — hilang sendiri setelah data cukup terkumpul (beberapa menit setelah simulator jalan). Tidak perlu action.

### Grafana contact-points.yaml missing

**Gejala:** Grafana gagal start dengan error `receiver 'telegram-alert' does not exist`.

**Penyebab:** `contact-points.yaml` tidak di-commit ke git (berisi credentials). Policies reference contact point yang belum ada.

**Solusi:**
```bash
cd grafana/provisioning/alerting/
cp contact-points.yaml.example contact-points.yaml
# Isi TELEGRAM_BOT_TOKEN dan TELEGRAM_CHAT_ID
docker compose restart grafana
```

### Mosquitto passwd file menjadi directory

**Gejala:** `Error: /mosquitto/config/passwd is not a file`

**Penyebab:** Docker auto-create mount target sebagai directory ketika file belum ada di host.

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

### pg_hba.conf entry literal `<db_user>` tidak ke-replace

**Gejala:** Backend connect gagal dengan `no pg_hba.conf entry for host`. Saat cek, ada entry `<db_user>` literal di pg_hba.conf.

**Penyebab:** Saat setup manual, placeholder `<db_user>` tidak diganti dengan nama user actual.

**Solusi:**
```bash
sudo sed -i 's/<db_user>/<actual_username>/' /var/lib/pgsql/data/pg_hba.conf
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

---

## Troubleshooting Cheatsheet

### Cek status PostgreSQL

```bash
# Service status
sudo systemctl status postgresql | head -5

# Cek versi + extension
sudo -u postgres psql -d iot_db -c "SELECT version();"
sudo -u postgres psql -d iot_db -c "\dx"

# Cek tabel + hypertable
sudo -u postgres psql -d iot_db -c "\dt"
sudo -u postgres psql -d iot_db -c "SELECT hypertable_name FROM timescaledb_information.hypertables;"

# Cek users
sudo -u postgres psql -c "\du"
```

### Cek status replikasi

**Di primary (datalayer-1):**
```bash
sudo -u postgres psql -c "
SELECT
    client_addr,
    state,
    sent_lsn,
    replay_lsn,
    write_lag,
    replay_lag
FROM pg_stat_replication;"

# Cek replication slot
sudo -u postgres psql -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

**Di replica (datalayer-2):**
```bash
# Konfirmasi replica mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # harus 't'

# Cek receiver status
sudo -u postgres psql -c "SELECT * FROM pg_stat_wal_receiver;"
```

### Test replication end-to-end

```bash
# Di primary
sudo -u postgres psql -d iot_db -c "INSERT INTO devices (device_id, device_name, location) VALUES ('test_repl', 'Test', 'test_area');"

# Di replica (tunggu 1-2 detik)
sudo -u postgres psql -d iot_db -c "SELECT * FROM devices WHERE device_id = 'test_repl';"
# Harus muncul

# Cleanup di primary
sudo -u postgres psql -d iot_db -c "DELETE FROM devices WHERE device_id = 'test_repl';"
```

### Cek koneksi aktif

```bash
sudo -u postgres psql -c "
SELECT
    pid,
    usename,
    client_addr,
    state,
    LEFT(query, 50) as query_snippet
FROM pg_stat_activity
WHERE state IS NOT NULL
ORDER BY backend_start;"
```

### Restart PostgreSQL safely

```bash
# Reload config tanpa restart (untuk pg_hba.conf, postgresql.conf changes)
sudo -u postgres psql -c "SELECT pg_reload_conf();"

# Full restart (perlu untuk shared_preload_libraries change)
sudo systemctl restart postgresql
```

### Replication recovery (kalau replica out-of-sync)

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
