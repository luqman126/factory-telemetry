#!/usr/bin/env bash
# ============================================================
# provision-db-primary.sh
# Provisioning script for Node 2 — DB Primary
# OS: Amazon Linux 2023
# Installs: PostgreSQL 16 + TimescaleDB
# Configures: primary role with replication support
#
# Usage: ssh ke Node 2, lalu:
#   chmod +x provision-db-primary.sh
#   sudo ./provision-db-primary.sh <db_name> <db_user> <db_password> <replica_ip>
# ============================================================
set -euo pipefail

if [ $# -lt 4 ]; then
    echo "Usage: $0 <db_name> <db_user> <db_password> <replica_ip>"
    exit 1
fi

DB_NAME="$1"
DB_USER="$2"
DB_PASSWORD="$3"
REPLICA_IP="$4"

echo "=== [1/6] Installing PostgreSQL 16 ==="
dnf install -y postgresql16-server postgresql16-contrib
postgresql-setup --initdb

echo "=== [2/6] Installing TimescaleDB ==="
# TimescaleDB RPM repo for Amazon Linux 2023
cat > /etc/yum.repos.d/timescaledb.repo <<'EOF'
[timescaledb]
name=TimescaleDB
baseurl=https://packagecloud.io/timescale/timescaledb/el/9/$basearch
gpgcheck=0
enabled=1
EOF
dnf install -y timescaledb-2-postgresql-16

echo "=== [3/6] Configuring PostgreSQL ==="
PGDATA="/var/lib/pgsql/data"

# TimescaleDB tuning
timescaledb-tune --pg-config=/usr/bin/pg_config --yes --quiet

# Replication settings
cat >> "$PGDATA/postgresql.conf" <<EOF

# --- Replication (Primary) ---
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
listen_addresses = '*'
EOF

# pg_hba.conf — allow app node + replica
cat >> "$PGDATA/pg_hba.conf" <<EOF

# App node (Node 1) — password auth
host    all             ${DB_USER}       10.0.1.0/24       scram-sha-256

# Replication from replica (Node 3)
host    replication     replicator       ${REPLICA_IP}/32   scram-sha-256
EOF

echo "=== [4/6] Starting PostgreSQL ==="
systemctl enable postgresql
systemctl start postgresql

echo "=== [5/6] Creating database, user, and replication role ==="
sudo -u postgres psql <<EOF
-- App user
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Replication user
CREATE USER replicator WITH REPLICATION PASSWORD '${DB_PASSWORD}';

-- Replication slot
SELECT pg_create_physical_replication_slot('node3_replica_slot');
EOF

echo "=== [6/6] Initializing schema (TimescaleDB + tables) ==="
sudo -u postgres psql -d "$DB_NAME" <<'SCHEMA'
CREATE EXTENSION IF NOT EXISTS timescaledb;
SCHEMA

# Run init.sql (copy this file to the node first)
if [ -f /tmp/init.sql ]; then
    sudo -u postgres psql -d "$DB_NAME" -f /tmp/init.sql
    echo "Schema initialized from init.sql"
else
    echo "WARNING: /tmp/init.sql not found. Copy db/init.sql to /tmp/init.sql and run:"
    echo "  sudo -u postgres psql -d $DB_NAME -f /tmp/init.sql"
fi

echo ""
echo "=== DONE ==="
echo "Primary is running. Next steps:"
echo "  1. Copy db/init.sql to this node and run schema if not done above."
echo "  2. Migrate data (pg_dump from old → pg_restore here)."
echo "  3. Run provision-db-replica.sh on Node 3."
