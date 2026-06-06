# ARCH-001 — Refactor Infrastructure Topology for Database High Availability

## Objective

Memisahkan application layer dan database layer untuk meningkatkan availability, memperjelas separation of concerns, dan mendukung manual database failover menggunakan PostgreSQL streaming replication.

---

## Current Architecture

```
Node 1 (c7i-flex.large)
├── FastAPI Backend
├── MQTT Broker
├── Grafana
├── PostgreSQL Primary
└── Spark-related services

Node 2 (t3.small)
├── PostgreSQL Replica
└── Spark Master
```

## Proposed Architecture

```
iot-bigdata-applayer-1 — Application Layer (c7i-flex.large)
├── FastAPI Backend
├── MQTT Broker
├── Grafana
└── Spark Master

iot-bigdata-datalayer-1 — Database Primary (t3.small)
└── PostgreSQL Primary (TimescaleDB)

iot-bigdata-datalayer-2 — Database Replica (t3.small)
└── PostgreSQL Standby Replica

iot-bigdata-worker-x — Ephemeral (t3.small)
└── Spark Workers / Executors
```

> Naming convention: `iot-bigdata-{layer}-{index}`. Disiapkan untuk horizontal scaling.

---

## Architectural Reasoning

### Why separate database nodes?

- Database adalah stateful component kritikal.
- Memungkinkan failover manual ketika primary database gagal.
- Mengurangi coupling antara analytics workload dan transactional database workload.
- Demonstrasi database cluster / HA topology.

### Why Spark Master moved to App Node?

- Spark Master relatif ringan (scheduler only).
- Menghindari role conflict saat database replica dipromosikan menjadi primary.
- Menjaga database cluster tetap fokus pada database responsibility.
- Memisahkan analytics orchestration dari database failover lifecycle.

### Why manual failover instead of automatic failover?

- Mengurangi operational complexity.
- Menghindari split-brain risk.
- Fokus memahami PostgreSQL replication fundamentals.
- Realistis untuk small-scale deployment dan project akademik.

---

## Connection Management

Semua service yang connect ke database menggunakan **satu file**: `infra/.env` di applayer-1.

| Service | Mechanism | Variable |
|---------|-----------|----------|
| FastAPI Backend | Source `infra/.env` saat startup | `POSTGRES_HOST`, `POSTGRES_PORT` |
| Grafana | Docker Compose env injection → datasource provisioning (`${POSTGRES_HOST}`) | `POSTGRES_HOST`, `POSTGRES_PORT` |
| Spark Jobs | Source `infra/.env` sebelum `spark-submit` | `POSTGRES_HOST`, `POSTGRES_PORT` |

### Failover connection update procedure:

1. Update `POSTGRES_HOST` di `infra/.env` → arahkan ke datalayer-2 (primary baru).
2. Restart services: `docker compose restart grafana && pkill -HUP uvicorn` (atau restart backend).
3. Spark job otomatis pakai value baru pada submit berikutnya.

> Satu file, satu update. Tidak ada hardcoded IP di application code maupun config file lain.

---

## Replication Configuration

### Requirements:

- **Replication slot** wajib digunakan agar WAL tidak di-recycle sebelum replica consume.
- Slot name convention: `node3_replica_slot`.
- Monitor slot lag via `pg_stat_replication` dan `pg_replication_slots`.

### Key PostgreSQL settings (Primary):

```
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
```

### Key PostgreSQL settings (Replica):

```
primary_conninfo = 'host=<datalayer-1-ip> port=5432 user=replicator'
primary_slot_name = 'node3_replica_slot'
```

---

## Failover Strategy

### Normal State

```
iot-bigdata-datalayer-1 → PRIMARY (read/write)
iot-bigdata-datalayer-2 → REPLICA (read-only, streaming replication)
```

### Failure Scenario — datalayer-1 down

| Step | Action | Verification |
|------|--------|--------------|
| 1 | Verifikasi primary benar-benar down | SSH attempt, health check |
| 2 | Promote datalayer-2: `pg_ctl promote` atau `pg_promote()` | Check `pg_is_in_recovery()` returns false |
| 3 | Update `POSTGRES_HOST` di `infra/.env` pada applayer-1 | Test connection dari backend |
| 4 | Restart services di applayer-1 | Verify data flow end-to-end |
| 5 | Rebuild datalayer-1 sebagai replica baru (`pg_basebackup` dari datalayer-2) | Check `pg_stat_replication` |

### Services yang perlu di-update saat failover:

- FastAPI Backend → DB connection
- Spark Jobs → DB write target
- Grafana → datasource

---

## Migration Plan

### Phase 0 — Backup & Preservation

- [x] Create AMI for current app node.
- [x] Snapshot PostgreSQL EBS volume.
- [x] Backup configuration and compose files.

### Phase 1 — Provision New Infrastructure

- [x] Launch applayer-1 (fresh c7i-flex.large).
- [x] Launch datalayer-1 (DB Primary) — t3.small.
- [x] Launch datalayer-2 (DB Replica) — t3.small (same spec as datalayer-1).
- [x] Install PostgreSQL 16 + TimescaleDB di kedua DB node.
- [x] Configure replication slot di primary.
- [x] Setup streaming replication datalayer-1 → datalayer-2.
- [x] Validate replication: cek `pg_stat_replication`, test write propagation.

### Phase 2 — Setup App Layer

- [x] Install Docker, Python, Java, Spark di applayer-1.
- [x] Setup `.env` dengan `POSTGRES_HOST` ke datalayer-1.
- [x] Run docker compose (Mosquitto + Grafana).
- [x] Start backend FastAPI + simulator.
- [x] Validate: data masuk ke datalayer-1, replicated ke datalayer-2.

### Phase 3 — Setup Spark Master di applayer-1

- [x] Install Spark di applayer-1.
- [x] Start Spark Master.
- [x] Configure ephemeral worker pipeline (`run_with_worker.sh`).
- [x] Validate: Spark job berjalan normal dengan ephemeral workers.

### Phase 4 — Failover Simulation (Backlog)

- [x] Simulate: stop PostgreSQL di datalayer-1.
- [x] Execute failover SOP (promote datalayer-2).
- [x] Verify semua services reconnect ke primary baru.
- [x] Rebuild datalayer-1 sebagai replica dari datalayer-2.
- [x] Verify replication kembali normal.
- [x] Rollback ke state awal (datalayer-1 = primary).

---

## Monitoring & Health Checks

| Metric | Query / Method | Alert Threshold |
|--------|---------------|-----------------|
| Replication lag (bytes) | `pg_stat_replication.sent_lsn - replay_lsn` | > 10MB |
| Replication slot active | `pg_replication_slots.active` | = false |
| Replica connected | `pg_stat_replication` row count | = 0 |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Replication lag | Monitor via `pg_stat_replication`, alert jika lag > threshold |
| Misconfigured failover | Documented SOP, test di Phase 4 |
| Spark resource contention on app node | Batch-based, low concurrency, Spark Master ringan |
| WAL bloat dari inactive slot | Monitor slot size, drop slot jika replica permanently down |
| Connection not updated after failover | Checklist di SOP, single config point (`.env`) |
| Migration rollback | AMI + EBS snapshot tersedia untuk restore |

---

## Expected Outcome

- Cleaner infrastructure separation (app vs data layer).
- Database HA dengan manual failover yang terdokumentasi.
- Simpler operational reasoning per-node.
- Demonstrasi distributed database topology untuk justifikasi akademik.
- Minimal increase in infrastructure cost (1 additional t3.small).

---

## Rollback Plan

Jika migrasi gagal di phase manapun:

1. Restore node lama dari AMI backup.
2. Terminate node baru (applayer-1, datalayer-1, datalayer-2).
3. Kembali ke arsitektur semula.

---

## Implementation Artifacts

| File | Purpose |
|------|---------|
| `infra/scripts/provision-db-primary.sh` | Setup datalayer-1: PostgreSQL 16 + TimescaleDB + replication config |
| `infra/scripts/provision-db-replica.sh` | Setup datalayer-2: pg_basebackup + streaming replication |
| `infra/docker-compose.yml` | Mosquitto + Grafana saja (timescaledb removed) |
| `infra/.env.example` | `POSTGRES_HOST` sebagai single source of truth |
| `grafana/provisioning/datasources/timescaledb.yml` | URL pakai `${POSTGRES_HOST}:${POSTGRES_PORT}` |
| `docs/runbook-db-setup.md` | Step-by-step + troubleshooting DB |
| `docs/runbook-spark-setup.md` | Step-by-step + arsitektur big data + troubleshooting Spark |

### Execution Order

```
1. SSH datalayer-1  → sudo ./provision-db-primary.sh <db> <user> <pass> <datalayer-2_ip>
2. SSH datalayer-2  → sudo ./provision-db-replica.sh <datalayer-1_ip> <pass>
3. SSH applayer-1   → Setup .env (POSTGRES_HOST=<datalayer-1_ip>), docker compose up -d
4. Validate         → Grafana connects, backend writes, replication active
```

---

## Post-ARCH-001: Private Subnet Migration

Setelah ARCH-001 selesai, dilakukan optimasi keamanan lanjutan: **memindahkan database nodes dan Spark Worker ke private subnet** (`10.0.2.0/24`).

### Perubahan dari ARCH-001

| Aspek | ARCH-001 (Awal) | Post-ARCH-001 (Saat ini) |
|-------|-----------------|--------------------------|
| Subnet DB | Public (`10.0.1.0/24`) | Private (`10.0.2.0/24`) |
| IP datalayer-1 | `10.0.1.247` | `10.0.2.10` |
| IP datalayer-2 | `10.0.1.78` | `10.0.2.20` |
| Akses SSH ke DB | Tailscale langsung | Bastion via applayer-1 (`ssh -A`) |
| Tailscale di DB | Aktif | Dinonaktifkan |
| S3 dari Worker | Via internet publik | Via VPC Gateway Endpoint (gratis) |
| Biaya tambahan | — | $0 (tanpa NAT Gateway) |

### Motivasi

- Database tidak memiliki alasan untuk berada di public subnet — hanya berkomunikasi dengan applayer-1 dan antar database nodes.
- Mengurangi *attack surface* dengan menghilangkan eksposur jaringan publik dari komponen stateful.
- VPC Gateway Endpoint untuk S3 menghilangkan kebutuhan NAT Gateway yang mahal (~$43/bulan).

Lihat `docs/aws-infrastructure.md` untuk detail konfigurasi subnet, route table, dan VPC Endpoint.

