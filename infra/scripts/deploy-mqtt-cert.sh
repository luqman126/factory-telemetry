#!/usr/bin/env bash
# ============================================================
# deploy-mqtt-cert.sh
# Copy Let's Encrypt cert ke direktori Mosquitto dengan
# ownership yang benar (UID 1883 = user mosquitto di container).
#
# Dipakai untuk:
#   1. Initial setup TLS
#   2. Deploy-hook certbot renewal (cert auto-update tiap 90 hari)
#
# Usage:
#   sudo ./deploy-mqtt-cert.sh [domain_name]
#   (defaults to mqtt.chescloud.my.id if no argument is provided)
# ============================================================
set -euo pipefail

# Gunakan parameter pertama jika ada (untuk staging/custom env),
# fallback ke domain production default untuk backward compatibility.
DOMAIN="${1:-mqtt.chescloud.my.id}"
LE_DIR="/etc/letsencrypt/live/${DOMAIN}"
# Direktori cert Mosquitto (relatif terhadap lokasi script: infra/scripts/ -> infra/mosquitto/certs)
CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/mosquitto/certs"
MOSQUITTO_UID=1883
CONTAINER="iot_mosquitto"

echo "=== Deploy MQTT cert dari Let's Encrypt ==="

mkdir -p "$CERT_DIR"

# Copy cert (follow symlink dengan -L)
cp -L "${LE_DIR}/fullchain.pem" "${CERT_DIR}/fullchain.pem"
cp -L "${LE_DIR}/privkey.pem"   "${CERT_DIR}/privkey.pem"

# Ownership ke user mosquitto di container (UID 1883)
chown ${MOSQUITTO_UID}:${MOSQUITTO_UID} "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/privkey.pem"

# Permission: fullchain readable, privkey ketat
chmod 644 "${CERT_DIR}/fullchain.pem"
chmod 600 "${CERT_DIR}/privkey.pem"

echo "Cert di-copy ke ${CERT_DIR}"
ls -la "${CERT_DIR}"

# Restart Mosquitto container supaya load cert baru
# (Mosquitto tidak auto-reload cert file)
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    docker restart "${CONTAINER}"
    echo "Container ${CONTAINER} di-restart."
else
    echo "WARNING: container ${CONTAINER} tidak running. Start manual: docker compose up -d"
fi

echo "=== DONE ==="
