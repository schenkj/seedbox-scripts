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
SCRIPT_NAME="qbit-racing-popularity-cleanup"

CATEGORY="racing"
POPULARITY_CUTOFF=50
GRACE_PERIOD_MINUTES=120

LOG_FILE="$HOME/logs/${SCRIPT_NAME}.log"
# ------------------

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

COOKIE_JAR="$(mktemp)"
TORRENTS_JSON="$(mktemp)"
MATCHES_FILE="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$TORRENTS_JSON" "$MATCHES_FILE"' EXIT

log "=== RUN START ==="
log "category=${CATEGORY} cutoff=${POPULARITY_CUTOFF} grace_minutes=${GRACE_PERIOD_MINUTES}"

login_response="$(
  curl -fsS -k \
    -c "$COOKIE_JAR" \
    --data-urlencode "username=${QBIT_USERNAME}" \
    --data-urlencode "password=${QBIT_PASSWORD}" \
    "${QBIT_BASE_URL}/api/v2/auth/login"
)"

if [[ "$login_response" != "Ok." ]]; then
  log "ERROR: qBittorrent login failed. Response: ${login_response}"
  log "=== RUN END ==="
  exit 1
fi

curl -fsS -k \
  -b "$COOKIE_JAR" \
  "${QBIT_BASE_URL}/api/v2/torrents/info?category=${CATEGORY}" \
  -o "$TORRENTS_JSON"

python3 - "$TORRENTS_JSON" "$POPULARITY_CUTOFF" "$GRACE_PERIOD_MINUTES" > "$MATCHES_FILE" <<'PY'
import json
import sys
import time

json_file = sys.argv[1]
cutoff = float(sys.argv[2])
grace_seconds = int(sys.argv[3]) * 60
now = int(time.time())

with open(json_file, "r", encoding="utf-8") as f:
    torrents = json.load(f)

for t in torrents:
    popularity = float(t.get("popularity") or 0)
    ratio = float(t.get("ratio") or 0)
    torrent_hash = t.get("hash", "")
    name = (t.get("name", "") or "").replace("\t", " ").replace("\n", " ")
    state = t.get("state", "")

    added_on = int(t.get("added_on") or 0)
    age_seconds = max(0, now - added_on) if added_on > 0 else 0

    if age_seconds >= grace_seconds and popularity < cutoff:
        print(f"{torrent_hash}\t{name}\t{ratio}\t{popularity}\t{age_seconds}\t{state}")
PY

removed_count=0

while IFS=$'\t' read -r hash name ratio popularity age_seconds state; do
  [[ -z "$hash" ]] && continue

  if curl -fsS -k \
    -b "$COOKIE_JAR" \
    --data-urlencode "hashes=${hash}" \
    --data-urlencode "deleteFiles=true" \
    "${QBIT_BASE_URL}/api/v2/torrents/delete" > /dev/null; then
    age_minutes=$(( age_seconds / 60 ))
    log "REMOVED: name=\"${name}\" hash=${hash} ratio=${ratio} popularity=${popularity} age_minutes=${age_minutes} state=${state} deleteFiles=true"
    removed_count=$((removed_count + 1))
  else
    log "ERROR: failed to remove name=\"${name}\" hash=${hash} ratio=${ratio} popularity=${popularity} state=${state}"
  fi
done < "$MATCHES_FILE"

log "removed_count=${removed_count}"
log "=== RUN END ==="
