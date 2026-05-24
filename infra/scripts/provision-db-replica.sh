#!/usr/bin/env bash
# ============================================================
# provision-db-replica.sh
# Provisioning script for Node 3 — DB Replica
# OS: Amazon Linux 2023
# Installs: PostgreSQL 16 + TimescaleDB
# Configures: streaming replication from Node 2 (primary)
#
# Usage: ssh ke Node 3, lalu:
#   chmod +x provision-db-replica.sh
#   sudo ./provision-db-replica.sh <primary_ip> <db_password>
#
# Prerequisites: Node 2 (primary) sudah running dan replication slot sudah dibuat.
# ============================================================
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <primary_ip> <db_password>"
    exit 1
fi

PRIMARY_IP="$1"
DB_PASSWORD="$2"

echo "=== [1/6] Installing PostgreSQL 16 ==="
dnf install -y postgresql16-server postgresql16-contrib postgresql16-private-devel

echo "=== [2/6] Installing TimescaleDB ==="
cat > /etc/yum.repos.d/timescaledb.repo <<'EOF'
[timescaledb]
name=TimescaleDB
baseurl=https://packagecloud.io/timescale/timescaledb/el/9/$basearch
gpgcheck=0
enabled=1
EOF
dnf install -y timescaledb-2-postgresql-16

echo "=== [3/6] Fixing TimescaleDB paths (Amazon Linux 2023 compatibility) ==="
ln -sf /usr/lib64/timescaledb-loader-pg16/timescaledb.so /usr/lib64/pgsql/
ln -sf /usr/lib64/timescaledb-pg16/timescaledb-2.27.1.so /usr/lib64/pgsql/
ln -sf /usr/lib64/timescaledb-pg16/timescaledb-tsl-2.27.1.so /usr/lib64/pgsql/
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
echo "On primary (Node 2), verify with:"
echo "  sudo -u postgres psql -c 'SELECT client_addr, state FROM pg_stat_replication;'"
