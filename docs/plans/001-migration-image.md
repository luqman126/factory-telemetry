# Implementation Plan 001: Dedicated Migration Image (`iot-migrations`)

**Status:** Draft v1 — awaiting review. **No code changes applied yet.**
**Scope:** small (~3 files) · **Risk:** low · **Rollback:** trivial (single revert)

---

## Objective

Split `backend/Dockerfile` into two named build stages so that database migrations
ship as an isolated artifact (`iot-migrations:latest`) containing zero application
code or application secrets, while the runtime backend image drops dbmate entirely.

This implements **Option B** from the migration-strategy discussion:
*dedicated migration image via multi-stage build — one source of truth, two artifacts.*

### Context (already landed in working tree, pre-plan)

| Change | File |
|---|---|
| Host `psql \|\| true` migration loop replaced with containerized dbmate | `deploy-staging.yml`, `deploy-production.yml` |
| Pinned dbmate v2.17.0 binary added to (currently single-stage) Dockerfile | `backend/Dockerfile` |
| Migration restructured into dbmate up/down blocks (idempotent statements) | `db/migrations/20260826000000_wide_column_analytics.sql` |
| In-container wrapper building URL-encoded `DATABASE_URL` | `db/run_migrations.sh` |

This plan refactors the *image packaging* only; migration behavior is unchanged.

---

## Non-Goals (explicitly out of scope)

1. **Credential/role split** (`iot_migrator` DDL role vs `iot_app` DML role) —
   folded into the Patroni + etcd milestone (Improvement #7), which redesigns
   database accounts anyway; doing it twice is waste.
2. **Stale `iot-backend.service` blocks in `deploy-production.yml`** and the
   missing `docker-compose.override.yml` rsync exclusion — separate pending decision.
3. Any change to `infra/docker-compose.yml` / `infra/docker-compose.override.yml`.

---

## Baseline (current state)

| File | Relevant fact |
|---|---|
| `backend/Dockerfile` | Single-stage. The dbmate `ADD` line sits above `COPY ./app`, so dbmate pollutes the runtime image today. |
| `.github/workflows/deploy-staging.yml` | `docker build -t iot-backend:latest ./backend`, then one-shot `docker run … -v $PWD/db/migrations:/migrations:ro -v $PWD/db/run_migrations.sh:/run_migrations.sh:ro iot-backend:latest /bin/sh /run_migrations.sh` |
| `.github/workflows/deploy-production.yml` | Same pattern (added this session; production previously had no migration step). |
| Build context | `backend/` only. The `db/` tree lives **outside** the build context. |

---

## Design Decision D1 — where do the SQL files live? ⚠️ (review hardest here)

### Variant 1 — bake SQL into the image ("pure" separation)

Requires widening the Docker build context from `backend/` to the repo root,
which forces:

- `build.context` edits in **both** compose files (`context: ..`,
  `dockerfile: backend/Dockerfile`)
- Path-prefixing every `COPY` in the Dockerfile (`COPY backend/app ./app`, …)
- A new root `.dockerignore` — without it, every build uploads `.git`,
  all `.venv`s, `spark-jobs/data/`, docs, benchmarks to the daemon

Blast radius: ~6 files. Benefit: fully self-contained migration image
(registry-distributable, ideal for k8s Jobs later).

### Variant 2 — keep host-mounted SQL, isolate only the tooling ✅ RECOMMENDED

Context stays `backend/`. Migration image = dbmate binary only. SQL + wrapper
continue mounting read-only from the rsync'd deploy host, which already
guarantees their presence (rsync excludes nothing under `db/`).

Blast radius: **3 files.** Delivers the properties that justified Option B:

- no app code/secrets in the migration artifact,
- independent lifecycle (one-shot container vs long-running service),
- k8s Job/init-container shape for the future,

at a third of the change surface. Upgrade path to Variant 1 stays open and is
naturally bundled with the Patroni/k8s phase when registry distribution and
self-contained Jobs become relevant. Today's distribution mechanism is rsync,
not a registry — self-containment buys nothing yet.

---

## File-by-file changes (Variant 2)

### 5.1 `backend/Dockerfile`

Restructure into named stages. Final stage must remain the last stage
(compose builds the last stage by default → `iot-backend:latest` semantics
preserved with zero compose edits).

```dockerfile
# syntax=docker/dockerfile:1

########################################
# Stage: migrations — dbmate only, no app code
########################################
FROM python:3.12-slim AS migrations

ADD --chmod=0755 https://github.com/amacneil/dbmate/releases/download/v2.17.0/dbmate-linux-amd64 \
    /usr/local/bin/dbmate

# No ENTRYPOINT — invocation specified at docker run time
# (consistent with spark-jobs/Dockerfile convention)

########################################
# Stage: runtime — FastAPI backend (behavior unchanged)
########################################
FROM python:3.12-slim AS runtime

# Security run as non-root
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /backend

# Cache dependency layer separately from app code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY ./app ./app

USER appuser

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Notes:

- The dbmate layer leaves the runtime image entirely.
- Runtime stage layers/order otherwise untouched → layer cache preserved on
  deploy hosts, no behavioral diff for the backend service.
- The wrapper script `db/run_migrations.sh` continues to be volume-mounted;
  it does **not** get baked in (it needs `POSTGRES_*` env vars supplied at run
  time via `--env-file infra/.env` anyway).

### 5.2 `.github/workflows/deploy-staging.yml` and `deploy-production.yml`

Identical edit in both — replace the backend build step:

```yaml
            # 0b. Build migration runner image (dbmate only)
            echo "-> Building iot-migrations image..."
            docker build --target migrations -t iot-migrations:latest ./backend
```

and switch the migration `docker run` image to `iot-migrations:latest`
(volume mounts unchanged).

The existing subsequent `docker compose up -d --build` continues producing
`iot-backend:latest` from the `runtime` stage — no compose change required.

---

## Verification plan (execute before merge)

1. **Build both targets locally:**
   ```bash
   docker build --target migrations -t iot-migrations:local ./backend
   docker build --target runtime    -t iot-backend:local    ./backend
   ```
2. **Negativity checks** (isolation actually holds):
   ```bash
   docker run --rm iot-backend:local    which dbmate      # expect exit 1
   docker run --rm iot-migrations:local ls /backend       # expect exit 1 (no app code)
   ```
3. **Size delta recorded** (~200MB runtime vs ~130MB migrations expected).
4. **End-to-end dry run against local TimescaleDB** (from
   `docker-compose.override.yml`; real Postgres, zero AWS dependency):
   first run applies migration + writes ledger row; second run reports
   already-applied / up-to-date.
5. **Static checks:** `sh -n db/run_migrations.sh`; YAML parse both workflows.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `ADD --chmod=…` requires BuildKit on deploy hosts. **This line has never been built anywhere yet** (added this session). | Pre-check `docker buildx version` during verification step 1. Fallback (decide at review time, not mid-deploy): fetch via `python -c "urllib.request.urlretrieve(...)"` + `chmod`, since slim images lack curl/wget but ship Python. |
| Supply chain: pinned-by-URL binary (same accepted class as the pinned Spark JARs). | Version-pinned URL now; digest pinning available later if compliance requires. |
| Tag drift between `iot-migrations:latest` and `iot-backend:latest` built minutes apart. | Acceptable: migrations are forward-only and idempotent; ledger prevents replays. Digest pinning noted as future hardening. |

---

## Rollback

Single git revert restores the monolithic Dockerfile and prior workflow lines.
Deploys are declarative full-state (rsync + rebuild); the next deploy after a
rebuild converges regardless of leftover local tags.

---

## Open questions for reviewer

1. **D1:** accept Variant 2 (host-mounted SQL) over baked-SQL Variant 1?
2. If staging's Docker is pre-BuildKit, which fallback for the dbmate fetch:
   Python `urllib` download inside the build, or a vendored binary committed
   to the repo?
3. Should `iot-migrations:local` verification (step 4) become a permanent
   `make` target / script, or stay manual?

---

## Future linkage

- **Patroni milestone (Improvement #7):** adds `iot_migrator`/`iot_app` role
  split on top of this artifact separation; `db/run_migrations.sh` gains
  migrator-role env vars.
- **k8s/registry era:** promote Variant 1 (baked SQL) so the image becomes
  registry-distributable and usable directly as an init container / Job.
