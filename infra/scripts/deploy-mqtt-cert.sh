#!/usr/bin/env bash
# ============================================================
# deploy-mqtt-cert.sh
# Copy Let's Encrypt certificate to Mosquitto directory with
# correct ownership (UID 1883 = mosquitto user in container).
#
# Used for:
#   1. Initial TLS setup
#   2. Deploy-hook for certbot renewal (auto-update every 90 days)
#
# Usage:
#   sudo ./deploy-mqtt-cert.sh [domain_name]
#   (defaults to mqtt.chescloud.my.id if no argument is provided)
# ============================================================
set -euo pipefail

# Use first parameter if supplied (for staging/custom env),
# fallback to production domain for backward compatibility.
DOMAIN="${1:-mqtt.chescloud.my.id}"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
# Mosquitto certs directory (relative to script: infra/scripts/ -> infra/mosquitto/certs)
CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/mosquitto/certs"
MOSQUITTO_UID=1883
CONTAINER="iot_mosquitto"

echo "=== Deploying MQTT cert from Let's Encrypt ==="

mkdir -p "$CERT_DIR"

# Copy certs (dereference symlinks with -L)
cp -L "${LE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
cp -L "${LE_DIR}/privkey.pem"   "${CERT_DIR}/privkey.pem"

# Set ownership to mosquitto container user (UID 1883)
chown ${MOSQUITTO_UID}:${MOSQUITTO_UID} "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"

# Permissions: fullchain readable, privkey restricted
chmod 644 "${CERT_DIR}/fullchain.pem"
chmod 600 "${CERT_DIR}/privkey.pem"

echo "Certificates copied to ${CERT_DIR}"
ls -la "${CERT_DIR}"

# Restart Mosquitto container to reload updated certificate
# (Mosquitto does not auto-reload cert files on disk)
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    docker restart "${CONTAINER}"
    echo "Container ${CONTAINER} restarted."
else
    echo "WARNING: Container ${CONTAINER} is not running. Start manually: docker compose up -d"
fi

echo "=== DONE ==="
