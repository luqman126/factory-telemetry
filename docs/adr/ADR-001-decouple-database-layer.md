# ADR-001: Decouple Database Layer for Database High Availability

## Objective
Separate the application layer and database layer to increase availability, enforce separation of concerns, and support manual database failover using PostgreSQL streaming replication.

---

## Current Architecture (V0)
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

## Proposed Architecture (V1)
```
iot-bigdata-applayer-1: Application Layer (c7i-flex.large)
├── FastAPI Backend
├── MQTT Broker
├── Grafana
└── Spark Master

iot-bigdata-datalayer-1: Database Primary (t3.small)
└── PostgreSQL Primary (TimescaleDB)

iot-bigdata-datalayer-2: Database Replica (t3.small)
└── PostgreSQL Standby Replica

iot-bigdata-worker-x: Ephemeral (t3.small)
└── Spark Workers / Executors
```

> **Naming convention:** `iot-bigdata-{layer}-{index}`, prepared for horizontal scaling.

---

## Architectural Rationale

### Why separate database nodes?
- Databases are critical stateful components.
- Allows manual failover when the primary database fails.
- Reduces coupling between analytical workloads and transactional database workloads.
- Demonstrates database cluster and high-availability topologies.

### Why was the Spark Master moved to the Application Node?
- The Spark Master is relatively lightweight (scheduler only).
- Avoids role conflicts when the database replica is promoted to primary.
- Keeps database cluster nodes focused entirely on database responsibilities.
- Separates analytics orchestration from the database failover lifecycle.

### Why manual failover instead of automatic failover?
- Reduces operational complexity.
- Avoids split-brain risks.
- Focuses on understanding PostgreSQL replication fundamentals.
- Realistic for small-scale deployments and academic projects.

---

## Connection Management

All services connecting to the database use a single file: `infra/.env` on `applayer-1`.

| Service | Mechanism | Variable |
|:---|:---|:---|
| FastAPI Backend | Sourced from `infra/.env` at startup | `POSTGRES_HOST`, `POSTGRES_PORT` |
| Grafana | Docker Compose env injection -> datasource provisioning | `POSTGRES_HOST`, `POSTGRES_PORT` |
| Spark Jobs | Sourced from `infra/.env` before submission | `POSTGRES_HOST`, `POSTGRES_PORT` |

### Failover connection update procedure:
1. Update `POSTGRES_HOST` in `infra/.env` to point to the new primary (`datalayer-2` IP).
2. Restart backend services: `docker compose restart grafana` and restart the backend.
3. Subsequent Spark submissions automatically pick up the new connection configurations.

> One file, one update. No hardcoded IPs exist in application code or configuration files.

---

## Replication Configuration

### Requirements:
- A replication slot is required to prevent the primary from recycling WAL segments before they are consumed by the standby.
- Slot name convention: `replica_datalayer2_slot`.
- Monitor slot lag via `pg_stat_replication` and `pg_replication_slots`.

### Key PostgreSQL settings (Primary):
```ini
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
```

### Key PostgreSQL settings (Replica):
```ini
primary_conninfo = 'host=<datalayer-1-ip> port=5432 user=replicator'
primary_slot_name = 'replica_datalayer2_slot'
```

---

## Failover Strategy

### Normal State
```
iot-bigdata-datalayer-1 -> PRIMARY (read/write)
iot-bigdata-datalayer-2 -> REPLICA (read-only, streaming replication)
```

### Failure Scenario: datalayer-1 down

| Step | Action | Verification |
|:---|:---|:---|
| 1 | Verify primary is fully down | SSH attempt, health check |
| 2 | Promote `datalayer-2` using `pg_promote()` | Confirm `pg_is_in_recovery()` returns false |
| 3 | Update `POSTGRES_HOST` in `infra/.env` on `applayer-1` | Test connection from backend |
| 4 | Restart services on `applayer-1` | Verify end-to-end data flow |
| 5 | Rebuild `datalayer-1` as new replica | Check `pg_stat_replication` |

---

## Migration Plan

### Phase 0: Backup & Preservation
- [x] Create AMI for current app node.
- [x] Snapshot PostgreSQL EBS volume.
- [x] Backup configuration and compose files.

### Phase 1: Provision New Infrastructure
- [x] Launch `applayer-1` (c7i-flex.large).
- [x] Launch `datalayer-1` (DB Primary) - t3.small.
- [x] Launch `datalayer-2` (DB Replica) - t3.small (same spec as datalayer-1).
- [x] Install PostgreSQL 16 + TimescaleDB on both DB nodes.
- [x] Configure replication slot on primary.
- [x] Setup streaming replication: datalayer-1 -> datalayer-2.
- [x] Validate replication: check `pg_stat_replication`, test write propagation.

### Phase 2: Setup App Layer
- [x] Install Docker, Python, Java, and Spark on `applayer-1`.
- [x] Setup `.env` with `POSTGRES_HOST` pointing to `datalayer-1`.
- [x] Run docker compose (Mosquitto + Grafana).
- [x] Start backend FastAPI + simulator.
- [x] Validate: data is written to `datalayer-1` and replicated to `datalayer-2`.

### Phase 3: Setup Spark Master on `applayer-1`
- [x] Install Spark on `applayer-1`.
- [x] Start Spark Master.
- [x] Configure ephemeral worker pipeline (`run_with_worker.sh`).
- [x] Validate: Spark job executes successfully using ephemeral workers.

### Phase 4: Failover Simulation
- [x] Simulate: stop PostgreSQL on `datalayer-1`.
- [x] Execute failover SOP (promote `datalayer-2`).
- [x] Verify all services reconnect to the new primary.
- [x] Rebuild `datalayer-1` as replica from `datalayer-2`.
- [x] Verify replication is healthy.
- [x] Rollback to initial state (datalayer-1 = primary).

---

## Risks & Mitigations

| Risk | Mitigation |
|:---|:---|
| Replication lag | Monitor via `pg_stat_replication`, alert if lag exceeds threshold |
| Misconfigured failover | Documented SOP, tested in Phase 4 simulation |
| Spark resource contention on app node | Batch-based execution, low concurrency, light master footprint |
| WAL bloat from inactive slot | Monitor slot size, drop slot if replica is permanently down |
| Connections not updated after failover | Single configuration point in `.env` |
| Migration rollback | AMI and EBS snapshot backups available for restore |

---

## Post-ARCH-001: Private Subnet Migration
After ARCH-001 was completed, a security migration was performed to move the database nodes and Spark workers to a private subnet (`10.x.2.0/24`).

| Aspect | ARCH-001 (Initial) | Post-ARCH-001 (Current) |
|:---|:---|:---|
| DB Subnet | Public (`10.0.1.0/24`) | Private (`10.x.2.0/24`) |
| datalayer-1 IP | `10.0.1.247` | `10.0.2.10` |
| datalayer-2 IP | `10.0.1.78` | `10.0.2.20` |
| SSH Access to DB | Direct Tailscale access | Bastion via `applayer-1` (`ssh -A`) |
| Tailscale on DB Nodes | Active | Disabled |
| S3 from Worker | Public internet | VPC Gateway Endpoint (Free) |
| Additional Cost | - | $0 (no NAT Gateway required) |

### Motivation
- Database nodes have no reason to reside in a public subnet, communicating only with `applayer-1` and each other.
- Wiping public exposure reduces the attack surface of critical stateful components.
- Using a VPC Gateway Endpoint for S3 avoids expensive NAT Gateway hourly processing fees.
