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
SCRIPT_NAME="autobrr-qbit-slots-check"
QBIT_CATEGORY="racing"

TARGET_ACTIVE_DOWNLOADS=3
MIN_USEFUL_AVG_SPEED_KIB=512
NEW_TORRENT_GRACE_SECONDS=300

LOG_FILE="$HOME/logs/${SCRIPT_NAME}.log"
# ------------------

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

MIN_USEFUL_AVG_SPEED_BPS=$((MIN_USEFUL_AVG_SPEED_KIB * 1024))
NOW="$(date +%s)"

log "=== RUN START ==="

login_response="$(
  curl -fsS -k \
    -c "$COOKIE_JAR" \
    --data-urlencode "username=$QBIT_USERNAME" \
    --data-urlencode "password=$QBIT_PASSWORD" \
    "${QBIT_BASE_URL}/api/v2/auth/login"
)"

if [[ "$login_response" != "Ok." ]]; then
  log "ERROR: qBittorrent login failed"
  log "=== RUN END ==="
  exit 2
fi

torrent_json="$(
  curl -fsS -k \
    -b "$COOKIE_JAR" \
    "${QBIT_BASE_URL}/api/v2/torrents/info?category=${QBIT_CATEGORY}"
)"

mapfile -t torrents < <(
  jq -r '.[] | [.hash, .name, .added_on, .amount_left] | @tsv' <<< "$torrent_json"
)

active_useful=0

for row in "${torrents[@]}"; do
  hash="${row%%$'\t'*}"
  rest="${row#*$'\t'}"

  name="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"

  added_on="${rest%%$'\t'*}"
  amount_left="${rest#*$'\t'}"

  # completed torrents never count, even during grace period
  if (( amount_left == 0 )); then
    continue
  fi

  # fresh incomplete torrents always count
  if (( added_on > 0 && NOW - added_on <= NEW_TORRENT_GRACE_SECONDS )); then
    ((active_useful+=1))
    continue
  fi

  avg_speed="$(
    curl -fsS -k \
      -b "$COOKIE_JAR" \
      --get \
      --data-urlencode "hash=$hash" \
      "${QBIT_BASE_URL}/api/v2/torrents/properties" \
    | jq -r '.dl_speed_avg // 0'
  )"

  if (( avg_speed >= MIN_USEFUL_AVG_SPEED_BPS )); then
    ((active_useful+=1))
  fi
done

log "active_useful=${active_useful} target=${TARGET_ACTIVE_DOWNLOADS}"

if (( active_useful < TARGET_ACTIVE_DOWNLOADS )); then
  log "RESULT: allow (slots not full)"
  log "=== RUN END ==="
  exit 0
fi

log "RESULT: deny (slots full)"
log "=== RUN END ==="
exit 1
