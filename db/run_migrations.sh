#!/bin/sh

set -eu

DATABASE_URL=$(python3 - <<'PYEOF'
import os
import urllib.parse as u

cfg = lambda key, default="": (os.getenv(key) or default).strip("\"'")
sslmode = cfg("POSTGRES_SSLMODE", "disable")

print("postgres://%s:%s@%s:%s/%s?sslmode=%s" % (
    u.quote(cfg("POSTGRES_USER"), safe=""),
    u.quote(cfg("POSTGRES_PASSWORD"), safe=""),
    cfg("POSTGRES_HOST", "localhost"),
    cfg("POSTGRES_PORT", "5432"),
    cfg("POSTGRES_DB"),
    sslmode,
))
PYEOF
)

export DATABASE_URL

exec dbmate --wait --no-dump-schema -d /migrations up