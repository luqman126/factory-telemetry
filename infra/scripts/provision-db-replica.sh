#!/usr/bin/env bash
# ============================================================
# provision-db-replica.sh
# Provisioning script for datalayer-2 — DB Replica
# OS: Amazon Linux 2023
# Installs: PostgreSQL 16 + TimescaleDB
# Configures: streaming replication from datalayer-1 (primary)
#
# Usage: ssh ke datalayer-2, lalu:
#   chmod +x provision-db-replica.sh
#   sudo ./provision-db-replica.sh <primary_ip> <db_password>
#
# Prerequisites: datalayer-1 (primary) sudah running dan replication slot sudah dibuat.
# ============================================================
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <primary_ip> <db_password>"
    exit 1
fi

PRIMARY_IP="$1"
DB_PASSWORD="$2"

echo "=== [1/6] Installing PostgreSQL 16 ==="
rm -f /etc/yum.repos.d/timescaledb.repo
dnf install -y postgresql16-server postgresql16-contrib postgresql16-server-devel

echo "=== [2/6] Installing TimescaleDB ==="
if rpm -q timescaledb-2-postgresql-16 >/dev/null 2>&1; then
    echo "TimescaleDB is already installed."
elif ls /home/ec2-user/timescaledb-2-postgresql-16-*.rpm >/dev/null 2>&1; then
    echo "Installing TimescaleDB from local RPM..."
    dnf localinstall -y /home/ec2-user/timescaledb-2-postgresql-16-*.rpm
else
    echo "ERROR: Local TimescaleDB RPM not found at /home/ec2-user/." >&2
    echo "Please download the RPM on bastion and copy it here first." >&2
    exit 1
fi

echo "=== [3/6] Fixing TimescaleDB paths (Amazon Linux 2023 compatibility) ==="
ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
ln -sf /usr/lib64/timescaledb-pg16/timescaledb-*.so /usr/lib64/pgsql/
ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.control /usr/share/pgsql/extension/
ln -sf /usr/lib64/timescaledb-pg16/timescaledb--*.sql /usr/share/pgsql/extension/

echo "=== [4/6] Base backup from primary ==="
PGDATA="/var/lib/pgsql/data"

# Remove default data dir (initdb not needed for replica)
rm -rf "$PGDATA"

# pg_basebackup from primary
PGPASSWORD="$DB_PASSWORD" pg_basebackup \
    -h "$PRIMARY_IP" \
    -U replicator \
    -D "$PGDATA" \
    -Fp -Xs -P -R \
    -S node3_replica_slot

chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

echo "=== [5/6] Configuring replica ==="
# pg_basebackup with -R already creates standby.signal and primary_conninfo
cat >> "$PGDATA/postgresql.conf" <<EOF

# --- Replica settings ---
hot_standby = on
primary_slot_name = 'node3_replica_slot'
EOF

echo "=== [6/6] Starting PostgreSQL (replica mode) ==="
systemctl enable postgresql
systemctl start postgresql

echo ""
echo "=== DONE ==="
echo "Replica is running. Verify with:"
echo "  sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
echo "  -- Should return 't'"
echo ""
echo "On primary (datalayer-1), verify with:"
echo "  sudo -u postgres psql -c 'SELECT client_addr, state FROM pg_stat_replication;'"
