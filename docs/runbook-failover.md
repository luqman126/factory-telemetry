# Runbook: Manual Failover Simulation

> SOP untuk melakukan manual failover dari datalayer-1 (primary) ke datalayer-2 (replica) dan rollback ke state awal.
>
> **Use case:** Disaster recovery exercise, demonstrasi HA topology, validasi replication setup.

---

## Pre-flight Checklist

Sebelum mulai failover, pastikan:

- [ ] Replication healthy (cek dari datalayer-1):
  ```bash
  sudo -u postgres psql -c "SELECT client_addr, state, replay_lag FROM pg_stat_replication;"
  ```
  Expected: 1 row, state = `streaming`, replay_lag < 1 detik.

- [ ] Replication slot active:
  ```bash
  sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
  ```
  Expected: `replica_datalayer2_slot | t`.

- [ ] Read replica datasource working (Grafana UI test connection ke `TimescaleDB-Replica` returns OK).

- [ ] EBS snapshot datalayer-1 tersedia (untuk safety net rollback).

- [ ] Catat IP node:
  ```
  datalayer-1: 10.0.2.10   (current primary, private subnet)
  datalayer-2: 10.0.2.20   (current replica, private subnet)
  applayer-1:  10.0.1.x    (public subnet, Bastion Host)
  ```

### Akses ke Node

Semua command yang prefix-nya **"Di <node>"** asumsinya operator sudah SSH ke node tersebut. Untuk database nodes di private subnet, akses via applayer-1 sebagai Bastion Host:

```bash
# Dari local machine → applayer-1 (via Tailscale)
ssh -A ec2-user@<applayer-1-tailscale-ip>

# Dari applayer-1 → database node (via private IP)
ssh ec2-user@10.0.2.10   # datalayer-1
ssh ec2-user@10.0.2.20   # datalayer-2
```

### Naming Convention untuk Replication Slot

Untuk menghindari ambiguitas, penamaan slot replikasi disesuaikan dengan peran aktif node yang menjadi replica:

| Pattern | Lokasi | Konsumer |
|---------|--------|----------|
| `replica_datalayer1_slot` | Di primary (`datalayer-2`) saat `datalayer-1` menjadi replica | datalayer-1 |
| `replica_datalayer2_slot` | Di primary (`datalayer-1`) saat `datalayer-2` menjadi replica | datalayer-2 |

Penamaan legacy `node3_replica_slot` sudah sepenuhnya dihapus dari sistem otomasi provisioning kita dan digantikan langsung oleh `replica_datalayer2_slot` pada inisialisasi awal.

---

## Phase 1 — Simulate Primary Failure

Tujuan: Stop PostgreSQL di datalayer-1 untuk simulate down.

**Di datalayer-1:**

```bash
sudo systemctl stop postgresql
```

### Verifikasi dampak

**Backend FastAPI** (di applayer-1, jalan via systemd):

```bash
# Cek status service + log error
sudo systemctl status iot-backend
sudo journalctl -u iot-backend -n 30 --no-pager
```

Backend gagal insert sensor data — error connection refused atau timeout ke `10.0.2.10:5432`.

**Grafana dashboard** (buka di browser via Cloudflare Tunnel):
- Dashboard panel **masih jalan** karena baca dari replica (datalayer-2). ✓
- Alert evaluation **gagal** — Grafana log:
  ```bash
  docker logs iot_grafana --tail 30 2>&1 | grep -i "error\|connection refused"
  ```

**Simulator** (di applayer-1):
- MQTT message tetap di-consume oleh broker, backend buffer message tapi flush ke DB gagal.

### Catatan

Phase ini **simulate failure**, bukan testing graceful shutdown. Di scenario nyata (server crash, disk full, kernel panic), behavior bisa lebih dramatis (TCP timeout, ungraceful disconnect).

---

## Phase 2 — Promote Replica

Tujuan: Jadikan datalayer-2 sebagai primary baru.

**Di datalayer-2:**

```bash
# Cek state saat ini (harus 't' = in recovery)
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Promote
sudo -u postgres psql -c "SELECT pg_promote();"

# Verify
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Expected: 'f' (false) — sekarang sudah primary
```

Setelah `pg_promote()`:
- `standby.signal` di-hapus otomatis
- PostgreSQL switch ke read-write mode
- Timeline ID bertambah (`pg_walfile_name()` akan show timeline baru)
- WAL receiver dimatikan

### Verifikasi

```bash
# Pastikan write bisa dilakukan
sudo -u postgres psql -d iot_db -c "
INSERT INTO devices (device_id, device_name, location)
VALUES ('failover_test', 'Failover Test', 'test_area');
"

# Read kembali — harus ada
sudo -u postgres psql -d iot_db -c "
SELECT * FROM devices WHERE device_id = 'failover_test';
"

# Cleanup
sudo -u postgres psql -d iot_db -c "DELETE FROM devices WHERE device_id = 'failover_test';"
```

---

## Phase 3 — Update Application Connection

Tujuan: Arahkan semua service di applayer-1 ke primary baru (datalayer-2).

**Di applayer-1:**

```bash
cd ~/iot-bigdata-project/infra

# Backup .env saat ini
cp .env .env.bak

# Update POSTGRES_HOST → datalayer-2 IP (private subnet)
sed -i 's/^POSTGRES_HOST=.*/POSTGRES_HOST=10.0.2.20/' .env

# Update POSTGRES_HOST_REPLICA juga ke datalayer-2 (sementara, sampai rebuild replica baru)
sed -i 's/^POSTGRES_HOST_REPLICA=.*/POSTGRES_HOST_REPLICA=10.0.2.20/' .env

# Verify
grep POSTGRES_HOST .env
```

### Restart services

```bash
# Recreate Grafana container (force load env baru)
docker compose up -d --force-recreate grafana

# Restart Mosquitto (clean state, optional)
docker compose restart mosquitto

# Restart backend FastAPI (systemd)
sudo systemctl restart iot-backend

# Verify backend up
sudo systemctl status iot-backend --no-pager | head -10
```

---

## Phase 4 — Verify End-to-End

**1. Backend health:**
```bash
curl localhost:8000/health
# Expected: {"status":"ok","db":true,"mqtt":true}
```

**2. Grafana dashboard:**
- Buka di browser
- Panel data harus jalan (sekarang baca dari datalayer-2 yang jadi primary)
- Test connection di Configuration → Data sources → keduanya OK

**3. Simulator → DB flow:**
```bash
# Pastikan simulator running (di applayer-1)
ps aux | grep simulator.py | grep -v grep

# Cek data masuk di datalayer-2 (primary baru)
# SSH ke datalayer-2 dulu via Tailscale, lalu:
sudo -u postgres psql -d iot_db -c "SELECT COUNT(*), MAX(time) FROM sensor_readings;"
# Count harus terus bertambah, MAX(time) harus recent
```

**4. Spark job:**
```bash
cd ~/iot-bigdata-project/spark-jobs
source .venv/bin/activate
python export_to_parquet.py
# Harus berhasil — read dari datalayer-2 (sekarang primary)
```

Kalau semua pass, **failover berhasil**. Sistem operate normal dengan datalayer-2 sebagai primary.

---

## Phase 5 — Rebuild Old Primary as Replica (Optional)

Tujuan: Restore HA topology — datalayer-1 jadi replica baru dari datalayer-2.

**Di datalayer-2 (current primary), buat replication slot baru:**

```bash
sudo -u postgres psql -c "
SELECT pg_create_physical_replication_slot('replica_datalayer1_slot');
"

# Update pg_hba.conf untuk allow replication dari datalayer-1
sudo bash -c 'cat >> /var/lib/pgsql/data/pg_hba.conf <<EOF

# Replication from datalayer-1 (rebuilt as replica)
host    replication     replicator       10.0.2.10/32     scram-sha-256
EOF'

sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

**Di datalayer-1 (old primary, sekarang akan jadi replica):**

```bash
# Stop PostgreSQL kalau masih jalan
sudo systemctl stop postgresql

# Hapus data directory lama (untuk replikasi segar)
sudo rm -rf /var/lib/pgsql/data

# Base backup dari primary baru (datalayer-2)
sudo PGPASSWORD='<db_password>' pg_basebackup \
    -h 10.0.2.20 \
    -U replicator \
    -D /var/lib/pgsql/data \
    -Fp -Xs -P -R \
    -S replica_datalayer1_slot

sudo chown -R postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data

# Tambah konfigurasi replica
sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

# --- Replica settings ---
hot_standby = on
primary_slot_name = '"'"'replica_datalayer1_slot'"'"'
EOF'

# Start PostgreSQL
sudo systemctl start postgresql
```

### Verifikasi Phase 5

**Di datalayer-1 (sekarang replica):**
```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
# Expected: 't'
```

**Di datalayer-2 (current primary):**
```bash
sudo -u postgres psql -c "SELECT client_addr, state FROM pg_stat_replication;"
# Expected: 1 row dengan client_addr = 10.0.2.10, state = 'streaming'

sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
# Expected: replica_datalayer1_slot | t
```

### Update applayer untuk pakai replica baru

```bash
cd ~/iot-bigdata-project/infra
# Update POSTGRES_HOST_REPLICA point ke datalayer-1 (sekarang replica)
sed -i 's/^POSTGRES_HOST_REPLICA=.*/POSTGRES_HOST_REPLICA=10.0.2.10/' .env
docker compose up -d --force-recreate grafana
```

Sekarang state: **datalayer-2 = primary, datalayer-1 = replica**. Roles swapped.

---

## Phase 6 — Rollback ke State Awal (Optional)

Tujuan: Kembalikan datalayer-1 sebagai primary, datalayer-2 sebagai replica (state awal sebelum simulasi).

> Phase ini secara struktur **identik dengan Phase 1-5**, tapi dengan node terbalik (sekarang datalayer-2 = primary, datalayer-1 = replica).

### 6.1 Stop datalayer-2 (current primary)

```bash
# Di datalayer-2
sudo systemctl stop postgresql
```

### 6.2 Promote datalayer-1 (current replica → new primary)

```bash
# Di datalayer-1
sudo -u postgres psql -c "SELECT pg_promote();"
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # harus 'f'
```

### 6.3 Update connection di applayer-1

```bash
cd ~/iot-bigdata-project/infra
sed -i 's/^POSTGRES_HOST=.*/POSTGRES_HOST=10.0.2.10/' .env
sed -i 's/^POSTGRES_HOST_REPLICA=.*/POSTGRES_HOST_REPLICA=10.0.2.10/' .env  # sementara, belum ada replica

docker compose up -d --force-recreate grafana
sudo systemctl restart iot-backend
```

### 6.4 Verify e2e (sama dengan Phase 4)

Pastikan:
- Backend health OK
- Simulator data masuk
- Spark export berhasil
- Grafana dashboard jalan

### 6.5 Rebuild datalayer-2 sebagai replica

**Di datalayer-1 (sekarang primary):**

```bash
# Buat slot baru untuk datalayer-2
sudo -u postgres psql -c "
SELECT pg_create_physical_replication_slot('replica_datalayer2_slot');
"

# pg_hba.conf sudah ada entry untuk 10.0.2.20 dari setup awal, tidak perlu diubah
# Kalau hilang/perlu tambah, run:
# sudo bash -c 'echo "host replication replicator 10.0.2.20/32 scram-sha-256" >> /var/lib/pgsql/data/pg_hba.conf'
# sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

**Di datalayer-2 (akan jadi replica lagi):**

```bash
# PostgreSQL sudah stopped dari step 6.1
# Hapus data directory lama (termasuk slot replica_datalayer1_slot)
sudo rm -rf /var/lib/pgsql/data

# Base backup dari primary (datalayer-1)
sudo PGPASSWORD='<db_password>' pg_basebackup \
    -h 10.0.2.10 \
    -U replicator \
    -D /var/lib/pgsql/data \
    -Fp -Xs -P -R \
    -S replica_datalayer2_slot

sudo chown -R postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data

# Konfigurasi replica
sudo bash -c 'cat >> /var/lib/pgsql/data/postgresql.conf <<EOF

# --- Replica settings ---
hot_standby = on
primary_slot_name = '"'"'replica_datalayer2_slot'"'"'
EOF'

# Apply pg_hba.conf fix (replicate tidak menyalin config)
sudo sed -i 's/<db_user>/<actual_username>/' /var/lib/pgsql/data/pg_hba.conf

sudo systemctl start postgresql
```

### 6.6 Restore load distribution di applayer

```bash
# Di applayer-1
cd ~/iot-bigdata-project/infra
sed -i 's/^POSTGRES_HOST_REPLICA=.*/POSTGRES_HOST_REPLICA=10.0.2.20/' .env
docker compose up -d --force-recreate grafana
```

### 6.7 Verify state akhir

**Di datalayer-1 (primary):**
```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # harus 'f'
sudo -u postgres psql -c "SELECT client_addr, state FROM pg_stat_replication;"
# Expected: 1 row, client_addr = 10.0.2.20, state = 'streaming'
sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
# Expected: replica_datalayer2_slot | t
```

**Di datalayer-2 (replica):**
```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # harus 't'
```

State akhir: ✓ datalayer-1 = primary, datalayer-2 = replica, naming slot konsisten dengan pattern baru.

---

## Common Issues During Failover

### `chown` vs `chmod` typo saat fix permission

**Gejala:** Setelah `pg_basebackup`, PostgreSQL gagal start. `journalctl` tidak jelas, atau bilang permission denied.

**Penyebab:** Salah ketik `sudo chown 700 /var/lib/pgsql/data` (seharusnya `chmod 700`). `chown 700` ubah ownership ke UID 700 — postgres tidak bisa akses lagi.

**Solusi:**
```bash
# Cek ownership
sudo ls -ld /var/lib/pgsql/data
# Kalau owner bukan postgres:postgres, fix:
sudo chown -R postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data
sudo systemctl start postgresql
```

### Backend tetap connect ke primary lama setelah update .env

**Penyebab:** Connection pool masih hold koneksi lama. Atau backend tidak baca .env setelah startup.

**Solusi:** Restart full backend process, bukan hanya reload. Connection pool akan re-init dengan host baru.

### Grafana tetap show error "connection refused" untuk replica

**Penyebab:** Datasource masih point ke IP lama yang sekarang down.

**Solusi:** Recreate Grafana container (`docker compose up -d --force-recreate grafana`). `restart` saja tidak cukup karena env var tidak di-reload.

### Replication tidak terbentuk setelah Phase 5

**Diagnosa:**
```bash
# Di replica baru
sudo -u postgres psql -c "SELECT * FROM pg_stat_wal_receiver;"
```

Kalau kosong/error:
- Cek `pg_hba.conf` di primary baru (allow IP replica?)
- Cek replication slot exist di primary
- Cek password replicator user benar

### Split-brain risk

**Skenario:** Old primary (datalayer-1) tiba-tiba "hidup" lagi setelah promote, dan masih punya `pg_is_in_recovery() = false`. Sekarang ada 2 primary → split-brain.

**Pencegahan:**
- Pastikan old primary **benar-benar mati** sebelum promote (cek SSH, PostgreSQL service status, network).
- Setelah failover, **jangan start PostgreSQL di old primary** sampai Phase 5 (rebuild as replica) dijalankan.

**Kalau sudah terjadi:**
1. Stop PostgreSQL di node yang seharusnya bukan primary.
2. Wipe data directory.
3. Rebuild as replica dari primary yang valid.

---

## SLA Target & Aktual

| Metrik | Target | Aktual (catat saat eksekusi) |
|--------|--------|------------------------------|
| Detection time (failure → operator aware) | < 5 min | _____ |
| Promote time (decision → replica promoted) | < 1 min | _____ |
| Connection update + restart services | < 5 min | _____ |
| **Total downtime untuk write workload** | **< 10 min** | **_____** |
| Read workload downtime | 0 (replica masih jalan) | _____ |
| Rebuild old primary as replica | < 15 min | _____ |

> Catat aktual time saat eksekusi untuk evaluasi.

---

## Post-Failover Checklist

- [ ] Replication active (`pg_stat_replication` shows streaming)
- [ ] Backend writes succeed
- [ ] Grafana dashboard shows recent data
- [ ] Spark job (export + analytics) jalan
- [ ] Alert rules evaluating (cek Grafana logs, tidak ada `connection refused`)
- [ ] `.env` updated dan committed (kalau IP berubah permanent)
- [ ] Document timing aktual di tabel SLA di atas
