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
Node 1 — Application Layer (c7i-flex.large)
├── FastAPI Backend
├── MQTT Broker
├── Grafana
└── Spark Master

Node 2 — Database Primary (t3.small)
└── PostgreSQL Primary (TimescaleDB)

Node 3 — Database Replica (t3.small)
└── PostgreSQL Standby Replica

Ephemeral Worker Nodes (t3.small)
└── Spark Workers / Executors
```

> Node 3 menggunakan instance type yang sama dengan Node 2 agar dapat dipromote menjadi primary tanpa degradasi performa.

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

Semua service yang connect ke database menggunakan **satu file**: `infra/.env` di Node 1.

| Service | Mechanism | Variable |
|---------|-----------|----------|
| FastAPI Backend | Docker Compose env injection | `DB_HOST`, `DB_PORT` |
| Grafana | Docker Compose env injection → datasource provisioning (`${DB_HOST}`) | `DB_HOST`, `DB_PORT` |
| Spark Jobs | Source `infra/.env` sebelum `spark-submit` | `DB_HOST`, `DB_PORT` |

### Failover connection update procedure:

1. Update `DB_HOST` di `infra/.env` → arahkan ke Node 3 (primary baru).
2. Restart services: `docker compose restart backend grafana`.
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
primary_conninfo = 'host=<node2-ip> port=5432 user=replicator'
primary_slot_name = 'node3_replica_slot'
```

---

## Failover Strategy

### Normal State

```
Node 2 → PRIMARY (read/write)
Node 3 → REPLICA (read-only, streaming replication)
```

### Failure Scenario — Node 2 down

| Step | Action | Verification |
|------|--------|--------------|
| 1 | Verifikasi primary benar-benar down | SSH attempt, health check |
| 2 | Promote Node 3: `pg_ctl promote` atau `pg_promote()` | Check `pg_is_in_recovery()` returns false |
| 3 | Update connection config di Node 1 (`.env` files) | Test connection dari backend |
| 4 | Restart services di Node 1 | Verify data flow end-to-end |
| 5 | Rebuild Node 2 sebagai replica baru (`pg_basebackup` dari Node 3) | Check `pg_stat_replication` |

### Services yang perlu di-update saat failover:

- FastAPI Backend → DB connection
- Spark Jobs → DB write target
- Grafana → datasource

---

## Migration Plan

### Phase 0 — Backup & Preservation

- [ ] Create AMI for current Node 1 (app + DB).
- [ ] Snapshot PostgreSQL EBS volume.
- [ ] Backup semua `.env` dan compose files.

### Phase 1 — Provision Database Nodes

- [ ] Launch Node 2 (DB Primary) — t3.small.
- [ ] Launch Node 3 (DB Replica) — t3.small (same spec as Node 2).
- [ ] Install PostgreSQL 16 + TimescaleDB di kedua node.
- [ ] Configure replication slot di primary.
- [ ] Setup streaming replication Node 2 → Node 3.
- [ ] Validate replication: cek `pg_stat_replication`, test write propagation.

### Phase 2 — Migrate PostgreSQL Primary

- [ ] Export data dari Node 1 PostgreSQL.
- [ ] Import ke Node 2 PostgreSQL.
- [ ] Update connection config di Node 1 `.env`.
- [ ] Remove PostgreSQL container dari Node 1 compose.
- [ ] Validate: backend bisa read/write ke Node 2.

### Phase 3 — Relocate Spark Master

- [ ] Install Spark Master di Node 1.
- [ ] Remove Spark Master dari Node 2.
- [ ] Update Spark job DB write target ke Node 2.
- [ ] Validate: `run_with_worker.sh` berjalan normal dengan ephemeral workers.

### Phase 4 — Failover Simulation

- [ ] Simulate: stop PostgreSQL di Node 2.
- [ ] Execute failover SOP (promote Node 3).
- [ ] Verify semua services reconnect ke primary baru.
- [ ] Rebuild Node 2 sebagai replica dari Node 3.
- [ ] Verify replication kembali normal.

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

1. Restore Node 1 dari AMI backup.
2. Terminate Node 2 dan Node 3.
3. Kembali ke arsitektur semula.

---

## Implementation Artifacts

| File | Purpose |
|------|---------|
| `infra/scripts/provision-db-primary.sh` | Setup Node 2: PostgreSQL 16 + TimescaleDB + replication config |
| `infra/scripts/provision-db-replica.sh` | Setup Node 3: pg_basebackup + streaming replication |
| `infra/scripts/migrate-data.sh` | Export data dari old container → import ke Node 2 |
| `infra/docker-compose.yml` | Removed timescaledb service, Grafana uses DB_HOST env |
| `infra/.env.example` | Added DB_HOST, DB_PORT as single source of truth |
| `grafana/provisioning/datasources/timescaledb.yml` | URL changed to `${DB_HOST}:${DB_PORT}` |

### Execution Order

```
1. SSH Node 2 → sudo ./provision-db-primary.sh <db> <user> <pass> <node3_ip>
2. SSH Node 1 → ./migrate-data.sh iot_timescaledb <db> <user> <node2_ip>
3. SSH Node 3 → sudo ./provision-db-replica.sh <node2_ip> <pass>
4. Node 1     → Update .env (DB_HOST=<node2_ip>), docker compose up -d
5. Validate   → Grafana connects, backend writes, replication active
```
