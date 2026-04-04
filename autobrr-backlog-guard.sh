#!/usr/bin/env bash
set -euo pipefail

source "$HOME/.config/scripts/secrets.env"

# ----- config -----
SCRIPT_NAME="autobrr-backlog-guard"
: "${QBIT_BASE_URL:?QBIT_BASE_URL not set}"
: "${QBIT_USERNAME:?QBIT_USERNAME not set}"
: "${QBIT_PASSWORD:?QBIT_PASSWORD not set}"

QBIT_CATEGORY="racing"
MAX_GB_LEFT=12
LOG_FILE="$HOME/logs/${SCRIPT_NAME}.log"
# ------------------

log() {
  printf "%s | %s | %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_NAME" "$1" >> "$LOG_FILE"
}

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

log "Starting backlog guard check for category '${QBIT_CATEGORY}'"

login_response="$(
  curl -fsS -k \
    -c "$COOKIE_JAR" \
    --data-urlencode "username=$QBIT_USERNAME" \
    --data-urlencode "password=$QBIT_PASSWORD" \
    "${QBIT_BASE_URL}/api/v2/auth/login"
)"

if [[ "$login_response" != "Ok." ]]; then
  log "ERROR: qBittorrent login failed"
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

log "Current backlog: ${gb_left}GB (threshold: ${MAX_GB_LEFT}GB)"

if (( gb_left >= MAX_GB_LEFT )); then
  log "Decision: BLOCK new downloads (backlog too large)"
  exit 1
fi

log "Decision: ALLOW new downloads (backlog within limit)"
exit 0
