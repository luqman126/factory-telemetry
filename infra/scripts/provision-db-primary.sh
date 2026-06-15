#!/usr/bin/env bash
# ============================================================
# provision-db-primary.sh
# Provisioning script for datalayer-1 — DB Primary
# OS: Amazon Linux 2023
# Installs: PostgreSQL 16 + TimescaleDB
# Configures: primary role with replication support
#
# Usage: ssh ke datalayer-1, lalu:
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

echo "=== [1/7] Installing PostgreSQL 16 ==="
rm -f /etc/yum.repos.d/timescaledb.repo
dnf install -y postgresql16-server postgresql16-contrib postgresql16-server-devel
PGDATA="/var/lib/pgsql/data"
if [ -d "$PGDATA" ] && [ "$(ls -A "$PGDATA")" ]; then
    echo "WARNING: $PGDATA is not empty. Cleaning it up for fresh initialization..."
    rm -rf "${PGDATA:?}"/*
fi
postgresql-setup --initdb

echo "=== [2/7] Installing TimescaleDB ==="
if rpm -q timescaledb-2-postgresql-16 >/dev/null 2>&1; then
    echo "TimescaleDB is already installed."
elif ls /home/ec2-user/timescaledb-*.rpm >/dev/null 2>&1; then
    echo "Installing TimescaleDB from local RPMs..."
    dnf localinstall -y /home/ec2-user/timescaledb-*.rpm
else
    echo "ERROR: Local TimescaleDB RPM not found at /home/ec2-user/." >&2
    echo "Please download the RPM on bastion and copy it here first." >&2
    exit 1
fi

echo "=== [3/7] Fixing TimescaleDB paths (Amazon Linux 2023 compatibility) ==="
# Amazon Linux repo installs PostgreSQL libs/extensions to different paths than PGDG.
# TimescaleDB package (built for el9/PGDG) puts files in non-standard locations.
# Fix: symlink to where Amazon Linux PostgreSQL expects them.

# Extension .so files
ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
ln -sf /usr/lib64/timescaledb-pg16/timescaledb-*.so /usr/lib64/pgsql/

# Extension control file
ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/

# Extension SQL files
ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/

echo "=== [4/7] Configuring PostgreSQL ==="
PGDATA="/var/lib/pgsql/data"

cat >> "$PGDATA/postgresql.conf" <<EOF

# --- TimescaleDB ---
shared_preload_libraries = 'timescaledb'

# --- Replication (Primary) ---
wal_level = replica
max_wal_senders = 3
max_replication_slots = 3
wal_keep_size = 256MB
listen_addresses = '*'
EOF

LOCAL_PREFIX=$(hostname -I | awk '{print $1}' | cut -d. -f1,2)

cat >> "$PGDATA/pg_hba.conf" <<EOF

# App node (applayer-1) — password auth
host    all             ${DB_USER}       ${LOCAL_PREFIX}.1.0/24       scram-sha-256

# App + services (dari private subnet — Spark Worker, etc.)
host    all             ${DB_USER}       ${LOCAL_PREFIX}.2.0/24       scram-sha-256

# Replication from replica (datalayer-2)
host    replication     replicator       ${REPLICA_IP}/32   scram-sha-256
EOF

echo "=== [5/7] Starting PostgreSQL ==="
systemctl enable postgresql
systemctl start postgresql

echo "=== [6/7] Creating database, user, and replication role ==="
sudo -u postgres psql <<EOF
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
GRANT pg_monitor TO ${DB_USER};
CREATE USER replicator WITH REPLICATION PASSWORD '${DB_PASSWORD}';
SELECT pg_create_physical_replication_slot('node3_replica_slot');
EOF

echo "=== [7/7] Initializing schema ==="
sudo -u postgres psql -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

if [ -f /tmp/init.sql ]; then
    sudo -u postgres psql -d "$DB_NAME" -f /tmp/init.sql
    # Fix ownership
    sudo -u postgres psql -d "$DB_NAME" -c "
        ALTER TABLE sensor_readings OWNER TO ${DB_USER};
        ALTER TABLE devices OWNER TO ${DB_USER};
        ALTER TABLE analytics_results OWNER TO ${DB_USER};
        ALTER TABLE anomaly_events OWNER TO ${DB_USER};
        ALTER TABLE spark_job_log OWNER TO ${DB_USER};
    "
    echo "Schema initialized and ownership set to ${DB_USER}"
else
    echo "WARNING: /tmp/init.sql not found. Copy db/init.sql to /tmp/init.sql and run:"
    echo "  sudo -u postgres psql -d $DB_NAME -f /tmp/init.sql"
fi

echo ""
echo "=== DONE ==="
echo "Primary is running. Next: run provision-db-replica.sh on datalayer-2."
