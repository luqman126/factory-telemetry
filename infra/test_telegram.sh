#!/bin/bash
# test_telegram.sh

# Load .env file
if [ -f .env ]; then
  echo "Loading .env..."
  export $(grep -v '^#' .env | xargs)
else
  echo ".env file not found!"
  exit 1
fi

echo "=============================================="
echo "Checking environment variables (masked):"
echo "TELEGRAM_BOT_TOKEN: ${TELEGRAM_BOT_TOKEN:0:6}... (length: ${#TELEGRAM_BOT_TOKEN})"
echo "TELEGRAM_CHAT_ID: ${TELEGRAM_CHAT_ID}"
echo "TELEGRAM_BOT_TOKEN_IOT: ${TELEGRAM_BOT_TOKEN_IOT:0:6}... (length: ${#TELEGRAM_BOT_TOKEN_IOT})"
echo "TELEGRAM_CHAT_ID_IOT: ${TELEGRAM_CHAT_ID_IOT}"
echo "TELEGRAM_BOT_TOKEN_SERVER: ${TELEGRAM_BOT_TOKEN_SERVER:0:6}... (length: ${#TELEGRAM_BOT_TOKEN_SERVER})"
echo "TELEGRAM_CHAT_ID_SERVER: ${TELEGRAM_CHAT_ID_SERVER}"
echo "=============================================="

test_send() {
  local token=$1
  local chat_id=$2
  local name=$3

  if [ -z "$token" ] || [ -z "$chat_id" ]; then
    echo "Skipping $name: Token or Chat ID is empty."
    return
  fi

  echo "Testing $name..."
  # Clean quotes if any
  local clean_chat_id=$(echo "$chat_id" | sed 's/["'\'']//g')
  echo "Original Chat ID: '$chat_id' -> Cleaned Chat ID: '$clean_chat_id'"

  echo "1. Sending with original Chat ID..."
  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${chat_id}\", \"text\": \"Test message from ${name} (original chat_id)\"}" | jq .

  echo "2. Sending with cleaned Chat ID (no quotes/spaces)..."
  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": ${clean_chat_id}, \"text\": \"Test message from ${name} (cleaned chat_id)\"}" | jq .
  
  echo "----------------------------------------------"
}

test_send "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "DEFAULT"
test_send "$TELEGRAM_BOT_TOKEN_IOT" "$TELEGRAM_CHAT_ID_IOT" "IOT"
test_send "$TELEGRAM_BOT_TOKEN_SERVER" "$TELEGRAM_CHAT_ID_SERVER" "SERVER"
