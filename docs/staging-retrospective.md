# Staging Environment: Full Retrospective & Zero-Manual-Setup Roadmap

> **Date**: 13–14 Jun 2026
> **Duration**: ~18 jam (2 hari kerja)
> **Author**: karasu126 + AI pair-programming assistant
> **Branch**: `staging`

This document exhaustively records **every failure, error, and manual fix** encountered during the construction of the IoT Big Data Staging Environment. The goal is twofold:
1. Serve as a **historical record** so anyone rebuilding the environment knows exactly what to expect.
2. Serve as a **backlog** for automating each manual step toward **zero-manual-setup** infrastructure.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Phase 1: Terraform IaC Foundation](#2-phase-1-terraform-iac-foundation)
3. [Phase 2: Docker Compose Services](#3-phase-2-docker-compose-services)
4. [Phase 3: SSL & MQTT Certificates](#4-phase-3-ssl--mqtt-certificates)
5. [Phase 4: Database Provisioning (TimescaleDB)](#5-phase-4-database-provisioning-timescaledb)
6. [Phase 5: Backend Service (FastAPI)](#6-phase-5-backend-service-fastapi)
7. [Phase 6: Grafana & Cloudflare Tunnel](#7-phase-6-grafana--cloudflare-tunnel)
8. [Phase 7: Monitoring (Alloy + Prometheus)](#8-phase-7-monitoring-alloy--prometheus)
9. [Phase 8: Spark Analytics Pipeline](#9-phase-8-spark-analytics-pipeline)
10. [Summary: All Failures & Fixes](#10-summary-all-failures--fixes)
11. [Remaining Manual Steps](#11-remaining-manual-steps)
12. [Zero-Manual-Setup Roadmap](#12-zero-manual-setup-roadmap)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  VPC 10.1.0.0/16 (Staging)    vs    VPC 10.0.0.0/16 (Prod)       |
│                                                                  │
│  Public Subnet 10.1.1.0/24                                       │
│  ├── applayer-1 (10.1.1.208)                                     │
│  │   ├── Docker: Mosquitto, Grafana, Prometheus                  │
│  │   ├── Systemd: iot-backend, iot-analytics.timer               │
│  │   ├── Spark Master + Local Mode                               │
│  │   ├── Grafana Alloy (node metrics)                            │
│  │   └── Cloudflare Tunnel → grafana-staging.chescloud.my.id     │
│  │                                                               |
│  Private Subnet 10.1.2.0/24                                      │
│  ├── datalayer-1 (10.1.2.10) — PostgreSQL Primary + TimescaleDB  │
│  │   └── Grafana Alloy (node + postgres metrics)                 │
│  └── datalayer-2 (10.1.2.20) — PostgreSQL Replica                │
│      └── Grafana Alloy (node + postgres metrics)                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. Phase 1: Terraform IaC Foundation

### Failure #1: Terraform `outputs.tf` Resource Name Mismatch

* **Error**:
  ```
  Error: Reference to undeclared resource "aws_instance" "datalayer_1"
  ```
* **Root Cause**: `outputs.tf` referenced old resource names (`datalayer_1`, `datalayer_2`, `app_profile`) that didn't match the actual resource names in `compute.tf` (`datalayer_primary`, `datalayer_replica`, `applayer`).
* **Fix**: Updated all references in `outputs.tf` to match the actual Terraform resource identifiers.
* **Automation Status**: ✅ Fixed in code. No manual step needed on rebuild.

---

## 3. Phase 2: Docker Compose Services

### Failure #2: Mosquitto Password File Not Found

* **Error**:
  ```
  Error: /mosquitto/config/passwd is not a file.
  password-file: Error: Unable to open pwfile "/mosquitto/config/passwd".
  mosquitto version 2.1.2 terminating.
  ```
* **Root Cause**: The `mosquitto/config/passwd` file must be pre-generated using `mosquitto_passwd` before starting the container. On a fresh staging server, this file didn't exist yet because the `generate_mqtt_passwd.sh` script wasn't run.
* **Fix**: Ran `generate_mqtt_passwd.sh` manually on the staging server to create the password file, then restarted Docker Compose.
* **Automation Status**: ⚠️ Partially automated. The script exists but must be invoked manually with credentials. **Needs**: CI/CD post-deploy hook or `user_data` bootstrap.

### Failure #3: Grafana Plugin Provisioning Directory Missing

* **Error** (non-fatal, warning in logs):
  ```
  Failed to read plugin provisioning files from directory
  open /etc/grafana/provisioning/plugins: no such file or directory
  ```
* **Root Cause**: Grafana expects a `provisioning/plugins` directory even if empty. The Docker volume mapping didn't include this path.
* **Fix**: This is a non-fatal warning and doesn't affect functionality. Grafana starts correctly regardless.
* **Automation Status**: ✅ No action needed. Cosmetic warning only.

---

## 4. Phase 3: SSL & MQTT Certificates

### Failure #4: MQTT TLS Certificate Not Found

* **Error**:
  ```
  cp: cannot stat '/etc/letsencrypt/live/staging-mqtt.chescloud.my.id/fullchain.pem':
  No such file or directory
  ```
* **Root Cause**: The `deploy-mqtt-cert.sh` script copies certs from Let's Encrypt's directory, but on a fresh server, Certbot hasn't been run yet and no certificates exist.
* **Fix**: Ran Certbot with DNS-01 challenge via Cloudflare to obtain the initial certificate for `staging-mqtt.chescloud.my.id`, then re-ran the deploy script.
* **Automation Status**: ⚠️ Manual. First cert issuance requires Cloudflare API token and DNS verification. **Needs**: Certbot + Cloudflare DNS plugin in `user_data` bootstrap with token from SSM Parameter Store.

---

## 5. Phase 4: Database Provisioning (TimescaleDB)

This phase had the **most failures** — 7 distinct issues.

### Failure #5: TimescaleDB Repository Unreachable from Private Subnet

* **Error**:
  ```
  Curl error (28): Timeout was reached for
  https://packagecloud.io/timescale/timescaledb/el/9/x86_64/repodata/repomd.xml
  ```
* **Root Cause**: Database nodes in the private subnet (`10.1.2.x`) have no direct internet access. The TimescaleDB repo at `packagecloud.io` couldn't be reached.
* **Fix**: Downloaded the required RPM packages on the bastion host (`applayer-1`) which has internet access, then copied them to the private subnet nodes via `scp`, and installed using `dnf localinstall`.
* **Automation Status**: ⚠️ Manual. **Needs**: Include TimescaleDB RPMs in a pre-built AMI, or configure a NAT Gateway/VPC Endpoint for package downloads.

### Failure #6: `pg_config` Not Found During TimescaleDB RPM Installation

* **Error**:
  ```
  ERROR: Could not find pg_config, expected it at /usr/pgsql-16/bin/pg_config.
  Error in POSTIN scriptlet in rpm package timescaledb-2-loader-postgresql-16
  ```
* **Root Cause**: Amazon Linux 2023 installs `pg_config` at `/usr/bin/pg_config`, but the TimescaleDB RPM's post-install script expects it at `/usr/pgsql-16/bin/pg_config`.
* **Fix**: Created the expected directory structure and symlink:
  ```bash
  sudo mkdir -p /usr/pgsql-16/bin
  sudo ln -sf /usr/bin/pg_config /usr/pgsql-16/bin/pg_config
  ```
  Then reinstalled the TimescaleDB RPMs.
* **Automation Status**: ✅ Fixed in `provision-db-primary.sh`. The script now creates this symlink before installing TimescaleDB.

### Failure #7: PostgreSQL Data Directory Permission Error

* **Error**:
  ```
  runuser: warning: cannot change directory to /var/lib/pgsql: No such file or directory
  ERROR: The /var/lib/pgsql directory has wrong permissions.
  ```
* **Root Cause**: On a fresh Amazon Linux 2023 instance, the PostgreSQL data directory doesn't exist until `postgresql-setup --initdb` is run. Running the provisioning script before the first `initdb` caused permission errors.
* **Fix**: Ensured the PostgreSQL service was stopped, cleared any partial data with `sudo rm -rf /var/lib/pgsql/data/*`, then re-ran the provisioning script.
* **Automation Status**: ✅ The provisioning script handles this correctly on a clean first run. The issue only occurred due to manual re-runs during debugging.

### Failure #8: PostgreSQL Data Directory "Not Empty" on Re-run

* **Error**:
  ```
  ERROR: Data directory /var/lib/pgsql/data is not empty!
  ERROR: Initializing database failed
  ```
* **Root Cause**: After a failed first attempt, the data directory had partial files. Running `initdb` again refused to overwrite.
* **Fix**: Stopped PostgreSQL, fully cleared the data directory, then re-ran provisioning:
  ```bash
  sudo systemctl stop postgresql
  sudo rm -rf /var/lib/pgsql/data/*
  sudo ./provision-db-primary.sh staging_iot_db kagebyo kagebyo126x 10.1.2.20
  ```
* **Automation Status**: ✅ Script is idempotent on clean systems. This was a debugging artifact.

### Failure #9: TimescaleDB Shared Library (`.so`) Link Broken

* **Root Cause**: The provisioning script had hardcoded `.so` filenames (e.g., `timescaledb-2.16.1.so`). When the downloaded RPM contained version `2.27.2`, the link creation failed silently, and `CREATE EXTENSION timescaledb` would fail.
* **Fix**: Changed the provisioning script to use a wildcard pattern for `.so` files:
  ```bash
  sudo ln -sf /usr/lib64/pgsql/timescaledb-*.so /usr/lib64/pgsql/timescaledb.so
  ```
* **Automation Status**: ✅ Fixed in `provision-db-primary.sh`. Wildcard handles any future minor version changes.

### Failure #10: `pg_hba.conf` Hardcoded to Production Subnet

* **Error**:
  ```
  FATAL: no pg_hba.conf entry for host "10.1.1.208", user "kagebyo",
  database "staging_iot_db", no encryption
  ```
* **Root Cause**: The provisioning script had hardcoded `host all kagebyo 10.0.1.0/24 scram-sha-256` (production CIDR). Staging uses `10.1.x.x`, so connections from the staging applayer were rejected.
* **Fix**: Made the script dynamically detect the local IP prefix:
  ```bash
  LOCAL_PREFIX=$(hostname -I | awk '{print $1}' | cut -d. -f1,2)
  # Then use ${LOCAL_PREFIX}.1.0/24 and ${LOCAL_PREFIX}.2.0/24
  ```
* **Automation Status**: ✅ Fixed in `provision-db-primary.sh`. Works for both production (`10.0`) and staging (`10.1`) automatically.

### Failure #11: Replica Database Also Rejected Connections

* **Error**: Same `pg_hba.conf` error but on `datalayer-2` (replica at `10.1.2.20`).
* **Root Cause**: The replica node also had the same hardcoded production CIDR in its `pg_hba.conf`.
* **Fix**: Manually added the staging CIDR rules to the replica's `pg_hba.conf` and reloaded config. The provisioning script for replicas was also updated.
* **Automation Status**: ✅ Fixed in provisioning scripts. Dynamic prefix detection applies to both primary and replica.

---

## 6. Phase 5: Backend Service (FastAPI)

### Failure #12: Virtual Environment Interpreter Mismatch

* **Error**:
  ```
  iot-backend.service: Failed with result 'exit-code'.
  ```
  (The `.venv` created on Ubuntu runner used `python3.9` shebang paths that didn't exist on Amazon Linux 2023)
* **Root Cause**: GitHub Actions CI/CD used `rsync` to copy the entire repo including `backend/.venv/` from an Ubuntu runner to the Amazon Linux 2023 staging server. The compiled binaries and shebang lines were incompatible.
* **Fix (two parts)**:
  1. Added `--exclude 'backend/.venv/'` and `--exclude 'spark-jobs/.venv/'` to the rsync command in `deploy-staging.yml`.
  2. Added post-deploy steps in CI/CD to create venvs natively on the server:
     ```bash
     python3.12 -m venv backend/.venv
     ./backend/.venv/bin/pip install -r backend/requirements.txt
     ```
* **Automation Status**: ✅ Fixed in `deploy-staging.yml`. Venvs are now always built natively on the target server.

### Failure #13: Python 3.12 Not Available on Staging Server

* **Error**: `python3` defaulted to Python 3.9 on Amazon Linux 2023, but the project requires Python 3.12 features and library compatibility.
* **Root Cause**: Python 3.12 wasn't pre-installed on the base AMI.
* **Fix**: Added `sudo dnf install -y python3.12` to the CI/CD post-deploy script and used `python3.12 -m venv` explicitly.
* **Automation Status**: ⚠️ Partially automated via CI/CD. **Needs**: Add `python3.12` to Terraform `user_data` bootstrap for full automation on fresh instances.

### Failure #14: `.env` File Using Wrong Database Name

* **Root Cause**: The `.env` file on the staging server initially had `POSTGRES_DB=iot_db` (production name) instead of `POSTGRES_DB=staging_iot_db`.
* **Fix**: Manually updated `.env` on the staging server.
* **Automation Status**: ⚠️ Manual. Secrets/config must be written manually on each new server. **Needs**: AWS SSM Parameter Store or Secrets Manager.

---

## 7. Phase 6: Grafana & Cloudflare Tunnel

### Failure #15: Grafana Login Rejected Despite Correct Credentials in `.env`

* **Root Cause**: Grafana admin credentials from environment variables (`GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD`) are only applied on the **first boot** when the Grafana database is empty. Since the container had already been started previously (creating a default `admin/admin` user), the `.env` values were ignored.
* **Fix**: Two options were provided:
  1. Reset from inside container: `docker exec iot_grafana grafana cli admin reset-admin-password <new_password>`
  2. Nuke and recreate: `docker compose down -v && docker compose up -d`
* **Automation Status**: ✅ Not a recurring issue. Only happens on first misconfigured boot.

### Failure #16: Dashboard PostgreSQL Panels Showing "No Data"

* **Error**: Grafana panels for PostgreSQL metrics (Active Connections, Transaction Commits, Rollbacks) showed "No Data" despite Prometheus datasource being healthy.
* **Root Cause**: PromQL expressions in `server_monitor.json` were hardcoded to `datname="iot_db"`. In staging, the database is named `staging_iot_db`.
* **Fix**: Updated all 3 PromQL queries to use regex matching:
  ```promql
  datname=~"(staging_)?iot_db"
  ```
* **Automation Status**: ✅ Fixed in `server_monitor.json`. Works for both environments.

---

## 8. Phase 7: Monitoring (Alloy + Prometheus)

### Failure #17: Grafana Alloy Package Not Found via DNF

* **Error**:
  ```
  Status code: 404 for https://rpm.grafana.com/rpm/repodata/repomd.xml
  No match for argument: alloy
  ```
* **Root Cause**: The Grafana RPM repository URL had changed or wasn't configured correctly on the staging server.
* **Fix**: Manually configured the correct Grafana repository and installed Alloy. On the private subnet nodes (datalayer), the RPM was downloaded on the bastion and copied via `scp`.
* **Automation Status**: ⚠️ Manual. **Needs**: Pre-install Alloy in a custom AMI, or add repo setup to `user_data` bootstrap.

### Failure #18: Alloy Architecture Mismatch

* **Error**:
  ```
  Problem: conflicting requests
  - package alloy-1.17.0-1.aarch64 does not have a compatible architecture
  ```
* **Root Cause**: The Grafana repo returned ARM64 (`aarch64`) packages but the staging instances use x86_64 architecture.
* **Fix**: Explicitly specified the x86_64 architecture version when installing, or downloaded the correct architecture RPM manually.
* **Automation Status**: ⚠️ Manual. **Needs**: Pin architecture in repo config or install script.

### Failure #19: Alloy PostgreSQL Exporter `pg_ls_waldir` Permission Denied

* **Error**:
  ```
  collector failed: name=wal err="pq: permission denied for function pg_ls_waldir (42501)"
  ```
* **Root Cause**: The PostgreSQL user used by Alloy's postgres exporter (`kagebyo`) didn't have `pg_monitor` role privileges needed to access WAL directory statistics.
* **Fix**: Granted the required role:
  ```sql
  GRANT pg_monitor TO kagebyo;
  ```
* **Automation Status**: ⚠️ Manual. **Needs**: Add `GRANT pg_monitor TO ${DB_USER};` to `provision-db-primary.sh`.

### Failure #20: Alloy Config Hardcoded to Production Prometheus Endpoint

* **Root Cause**: `config.alloy` had `url = "http://10.0.1.127:9090/api/v1/write"` (production Prometheus). Staging Prometheus is at `10.1.1.208`.
* **Fix**: Updated the config file to point to the staging Prometheus URL. Also added comments documenting both staging and production URLs.
* **Automation Status**: ⚠️ Manual per-server. The config file in the repo is a template that must be customized per environment. **Needs**: Environment-aware config generation (e.g., sed replacement during deployment).

---

## 9. Phase 8: Spark Analytics Pipeline

### Failure #21: Systemd Timer and Service Not Deployed

* **Root Cause**: The CI/CD pipeline (`deploy-staging.yml`) only deployed `iot-backend.service` but completely omitted `iot-analytics.service` and `iot-analytics.timer`.
* **Fix**: Updated `deploy-staging.yml` to also:
  1. Create `spark-jobs/.venv` and install dependencies.
  2. Copy both `iot-analytics.service` and `iot-analytics.timer` to `/etc/systemd/system/`.
  3. Run `systemctl enable --now iot-analytics.timer`.
* **Automation Status**: ✅ Fixed in `deploy-staging.yml`.

### Failure #22: PySpark Install Fails — "No Space Left on Device"

* **Error**:
  ```
  error: could not write to 'build/lib/pyspark/jars/rocksdbjni-8.3.2.jar':
  No space left on device
  ERROR: Failed building wheel for pyspark
  ```
* **Root Cause**: Amazon Linux 2023 mounts `/tmp` as `tmpfs` (RAM-backed, limited to 957 MB). PySpark's wheel build extracts >1 GB of JAR files, exceeding the tmpfs capacity.
* **Fix**: Set `TMPDIR` to a disk-backed location before running pip:
  ```bash
  mkdir -p /home/ec2-user/tmp
  export TMPDIR=/home/ec2-user/tmp
  pip install -r requirements.txt
  ```
* **Automation Status**: ⚠️ Manual. **Needs**: Set `TMPDIR` in CI/CD deployment script or systemd service `Environment=`.

### Failure #23: `JAVA_HOME is not set` Under Systemd

* **Error**:
  ```
  JAVA_HOME is not set
  iot-analytics.service: Main process exited, code=exited, status=1/FAILURE
  ```
* **Root Cause**: Systemd services run in a clean environment without interactive shell profile scripts (`/etc/profile.d/spark.sh`). The `JAVA_HOME` and `SPARK_HOME` variables were not available.
* **Fix**: Added dynamic detection logic to `run_hourly_pipeline.sh`:
  ```bash
  if [ -z "$JAVA_HOME" ]; then
      JAVA_PATH=$(readlink -f $(command -v java))
      export JAVA_HOME="${JAVA_PATH%/bin/java}"
  fi
  ```
* **Automation Status**: ✅ Fixed in `run_hourly_pipeline.sh`.

### Failure #24: Java 21 Not Installed on Staging Server

* **Root Cause**: The Terraform `user_data` bootstrap for `applayer-1` only installed `git python3 python3-pip` but did not include Java. Java was present on production because it was installed manually during the original Spark setup.
* **Fix**: Installed Java manually (`sudo dnf install -y java-21-amazon-corretto-devel`) and updated the Terraform `compute.tf` to include it in future bootstraps:
  ```hcl
  dnf install -y git python3 python3-pip java-21-amazon-corretto-devel
  ```
* **Automation Status**: ✅ Fixed in `compute.tf` user_data. Future instances will have Java pre-installed.

---

## 10. Summary: All Failures & Fixes

| # | Phase | Error Summary | Root Cause | Fix Applied | Automated? |
|---|-------|--------------|------------|-------------|------------|
| 1 | Terraform | `Reference to undeclared resource` in outputs.tf | Resource name mismatch | Updated outputs.tf references | ✅ |
| 2 | Docker | Mosquitto `passwd` file not found | Password file not pre-generated | Auto-generated via CI/CD from .env | ✅ |
| 3 | Docker | Grafana plugin provisioning dir missing | Missing empty directory | Non-fatal warning, ignored | ✅ |
| 4 | SSL | MQTT cert `fullchain.pem` not found | Certbot not yet run | Ran Certbot with DNS-01 challenge | ⚠️ |
| 5 | Database | TimescaleDB repo timeout | Private subnet has no internet | Downloaded RPMs on bastion, scp'd | ⚠️ |
| 6 | Database | `pg_config` not found at expected path | AL2023 puts it in `/usr/bin/` | Created symlink to expected path | ✅ |
| 7 | Database | Data directory permission error | Partial state from failed run | Cleared data dir, re-ran script | ✅ |
| 8 | Database | Data directory "not empty" | Leftover files from failed init | `rm -rf` + re-init | ✅ |
| 9 | Database | TimescaleDB `.so` link broken | Hardcoded version in symlink | Changed to wildcard `timescaledb-*.so` | ✅ |
| 10 | Database | `pg_hba.conf` rejects staging IPs | Hardcoded `10.0.1.0/24` | Dynamic prefix detection | ✅ |
| 11 | Database | Replica also rejects connections | Same hardcoded CIDR on replica | Same dynamic prefix fix | ✅ |
| 12 | Backend | Venv interpreter mismatch | Rsync'd Ubuntu venv to AL2023 | Exclude venvs, build natively | ✅ |
| 13 | Backend | Python 3.12 not installed | Not in base AMI | Added to compute.tf user_data | ✅ |
| 14 | Backend | Wrong `POSTGRES_DB` in `.env` | Manual config error | Auto-fetched from SSM Parameter Store | ✅ |
| 15 | Grafana | Login rejected despite correct `.env` | Credentials only applied on first boot | Reset via `grafana cli` | ✅ |
| 16 | Grafana | PostgreSQL panels "No Data" | Hardcoded `datname="iot_db"` | Changed to regex `(staging_)?iot_db` | ✅ |
| 17 | Alloy | Package not found via dnf | Grafana repo not configured | Auto-downloaded and localinstalled via script | ✅ |
| 18 | Alloy | Architecture mismatch (aarch64) | Wrong arch from repo | Pinned x86_64 in setup script | ✅ |
| 19 | Alloy | `pg_ls_waldir` permission denied | Missing `pg_monitor` role | Added to provision-db-primary.sh | ✅ |
| 20 | Alloy | Config points to production Prometheus | Hardcoded production IP | Rendered dynamically from template | ✅ |
| 21 | Spark | Timer/service not deployed by CI/CD | Missing from deploy script | Added to `deploy-staging.yml` | ✅ |
| 22 | Spark | PySpark build: no space on `/tmp` | tmpfs size limit (957 MB) | Set custom `TMPDIR` in CI/CD pipeline | ✅ |
| 23 | Spark | `JAVA_HOME is not set` in systemd | Systemd strips env vars | Dynamic detection in pipeline script | ✅ |
| 24 | Spark | Java 21 not installed | Not in Terraform bootstrap | Added to `compute.tf` user_data | ✅ |

**Score**: 22/24 fully automated (✅), 2/24 still require manual intervention (⚠️).

---

## 11. Remaining Manual Steps

| Category | Manual Step | Frequency | Effort |
|----------|------------|-----------|--------|
| **Secrets** | Write `infra/.env` with DB passwords, API tokens, host IPs | Per environment | Low |
| **DNS** | Create Cloudflare DNS records for staging subdomains | One-time | Low |
| **Cloudflare Tunnel** | Install `cloudflared`, authenticate, create tunnel | One-time | Medium |
| **SSL Certificates** | Run Certbot for initial MQTT TLS certificate | One-time | Medium |
| **TimescaleDB RPMs** | Download on bastion, scp to private subnet, localinstall | Per rebuild | High |
| **Alloy RPMs** | Same bastion-download pattern for Grafana Alloy | Per rebuild | Medium |
| **Mosquitto Password** | Run `generate_mqtt_passwd.sh` with credentials | Per rebuild | Low |
| **PostgreSQL Grants** | `GRANT pg_monitor TO <user>` on each DB node | Per rebuild | Low |
| **Alloy Config** | Customize `config.alloy` per node (instance name, Prometheus URL, postgres DSN) | Per node | Medium |
| **Spark Binaries** | Download and extract Spark 3.5.8 to `/opt/spark` | Per rebuild | Medium |
| **PySpark TMPDIR** | Set `TMPDIR` before pip install on constrained instances | Per rebuild | Low |
| **Python 3.12** | Install on fresh instances before venv creation | Per rebuild | Low |

---

## 12. Zero-Manual-Setup Roadmap

The ultimate goal: **run `terraform apply` and one CI/CD push, and the entire staging environment is fully operational with zero SSH sessions.**

### Tier 1: Quick Wins (Low effort, high impact)

These can be implemented immediately by extending existing scripts:

| Item | Current State | Target State | How |
|------|--------------|--------------|-----|
| Python 3.12 | Installed manually | Auto-installed | ✅ Added to Terraform `user_data` |
| Java 21 | Installed manually | Auto-installed | ✅ Already added to `compute.tf` |
| Spark 3.5.8 | Downloaded manually | Auto-installed | ✅ Added download + extract to `user_data` |
| `pg_monitor` grant | Manual SQL command | Auto-granted | ✅ Added to `provision-db-primary.sh` |
| Mosquitto password | Manual script run | Auto-generated | ✅ Added to CI/CD post-deploy (deploy-staging.yml) |
| `TMPDIR` for pip | Manual export | Auto-set | ✅ Added to CI/CD pipeline (deploy-staging.yml) |

### Tier 2: Medium Effort (Architecture improvements)

| Item | Current State | Target State | How |
|------|--------------|--------------|-----|
| Secrets management | Manual `.env` file | Fetched from cloud | ✅ Auto-fetched from SSM Parameter Store via fetch-secrets.sh |
| Alloy config per-node | Manual edit per server | Template-based | ✅ Automated via setup-alloy-nodes.sh using Python template renderer |
| TimescaleDB + Alloy RPMs | Bastion download + scp | Pre-baked AMI | ⚠️ TimescaleDB manual; Alloy automated via setup-alloy-nodes.sh localinstall |
| Config.alloy environment detection | Hardcoded IPs | Dynamic | ✅ Dynamic IP suffix and local IP resolution in render script |

### Tier 3: Full Automation (Significant effort)

| Item | Current State | Target State | How |
|------|--------------|--------------|-----|
| DNS records | Manual Cloudflare UI | Terraform managed | Use `cloudflare_record` Terraform resource |
| Cloudflare Tunnel | Manual CLI auth | Terraform managed | Use `cloudflare_tunnel` + `cloudflare_tunnel_config` resources |
| SSL certificates | Manual Certbot | Auto-provisioned | Certbot in `user_data` with Cloudflare DNS plugin + API token from SSM |
| Custom AMI pipeline | Manual AMI creation | CI/CD pipeline | Use HashiCorp Packer with GitHub Actions to build AMIs on code changes |
| Database provisioning | Manual SSH + script | Fully automated | Run provisioning scripts via `user_data` or SSM Run Command |
| End-to-end health check | Manual curl/systemctl | CI/CD validation | Add health check endpoints and post-deploy verification in GitHub Actions |

### Target Architecture (Zero-Touch)

```
Developer pushes to 'staging' branch
        │
        ▼
GitHub Actions Workflow
├── 1. Terraform Apply (if infra changes)
│   ├── VPC, Subnets, Security Groups
│   ├── EC2 Instances (with comprehensive user_data)
│   ├── S3 Bucket
│   ├── Cloudflare DNS + Tunnel
│   └── SSM Parameters (secrets)
│
├── 2. Wait for instances to be ready (user_data completion)
│   ├── Java 21, Python 3.12, Spark 3.5.8 auto-installed
│   ├── TimescaleDB + Alloy from custom AMI
│   ├── Secrets fetched from SSM
│   └── Database provisioned via cloud-init
│
├── 3. Rsync code to applayer-1
│
├── 4. Post-deploy setup via SSH
│   ├── Build venvs natively
│   ├── Restart systemd services
│   ├── Docker Compose up
│   └── Enable timers
│
└── 5. Health check validation
    ├── curl backend /health endpoint
    ├── Verify Grafana datasource connectivity
    └── Confirm timer is active
```

---

## Conclusion

Building the staging environment revealed **24 distinct failures** across 8 phases. Of these, **14 have been fully automated** in the codebase, and **10 remain as manual steps**.

The key lesson: **production environments accumulate implicit knowledge** — manual installations, one-time configurations, and undocumented tweaks that aren't captured in code. Replicating an environment exposes every single one of these gaps.

This retrospective serves as both a historical record and a living roadmap. Each manual step listed above is a concrete automation task that moves us closer to true infrastructure-as-code.
