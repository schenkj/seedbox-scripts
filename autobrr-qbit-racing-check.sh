#!/usr/bin/env bash
set -euo pipefail

# ----- load secrets -----
SECRETS_FILE="$HOME/.config/scripts/secrets.env"
[ -f "$SECRETS_FILE" ] || { echo "Missing $SECRETS_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$SECRETS_FILE"

: "${QBIT_BASE_URL:?QBIT_BASE_URL not set}"
: "${QBIT_USERNAME:?QBIT_USERNAME not set}"
: "${QBIT_PASSWORD:?QBIT_PASSWORD not set}"
# ------------------------

# ----- config -----
SCRIPT_NAME="autobrr-qbit-racing-check"
QBIT_CATEGORY="racing"
MAX_GB_LEFT=8
LOG_FILE="$HOME/logs/${SCRIPT_NAME}.log"
# ------------------

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

login_response="$(
  curl -fsS -k \
    -c "$COOKIE_JAR" \
    --data-urlencode "username=$QBIT_USERNAME" \
    --data-urlencode "password=$QBIT_PASSWORD" \
    "${QBIT_BASE_URL}/api/v2/auth/login"
)"

if [[ "$login_response" != "Ok." ]]; then
  echo "qBittorrent login failed"
  exit 2
fi

bytes_left="$(
  curl -fsS -k \
    -b "$COOKIE_JAR" \
    "${QBIT_BASE_URL}/api/v2/torrents/info?category=${QBIT_CATEGORY}" \
  | python3 -c '
import sys, json
wanted = {"downloading", "queuedDL", "metaDL"}
data = json.load(sys.stdin)
print(sum(t.get("amount_left", 0) for t in data if t.get("state") in wanted))
'
)"

gb_left=$((bytes_left / 1000000000))

echo "remaining=${gb_left}GB"

if (( gb_left >= MAX_GB_LEFT )); then
  echo "Backlog too large. Skipping."
  exit 1
fi

exit 0
