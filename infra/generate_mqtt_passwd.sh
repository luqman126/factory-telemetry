#!/bin/bash
# Generate Mosquitto password file
# Usage: ./generate_mqtt_passwd.sh <username> <password>

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <username> <password>"
    exit 1
fi

PASSWD_FILE="$(dirname "$0")/mosquitto/passwd"

# Create or append to password file
docker run --rm -v "$(dirname "$0")/mosquitto:/mosquitto/config" \
    eclipse-mosquitto:2 \
    mosquitto_passwd -b /mosquitto/config/passwd "$1" "$2"

echo "Password file updated: $PASSWD_FILE"
