#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/home/usb488/logs"
LOG_FILE="$LOG_DIR/delete_unpopular_torrents.log"
mkdir -p "$LOG_DIR"
exec >>"$LOG_FILE" 2>&1

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

LOCK_FILE="/tmp/prune-racing-low-space.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || {
  log "Another instance is already running, exiting."
  exit 0
}

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
SCRIPT_NAME="prune-racing-low-space"
QBIT_CATEGORY="racing"

MIN_FREE_GB=80
MIN_AGE_SECONDS=1800
MIN_RATIO=0
MAX_SEED_DAYS=1   # don't delete before, if below min ratio
PENDING_TTL_SECONDS=60

STATE_FILE="/tmp/${SCRIPT_NAME}.state"
LOG_FILE="$HOME/logs/${SCRIPT_NAME}.log"
# ------------------

COOKIE_JAR="$(mktemp)"
TORRENTS_JSON="$(mktemp)"
PLAN_FILE="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$TORRENTS_JSON" "$PLAN_FILE"' EXIT

gb_to_bytes() {
  echo $(( $1 * 1024 * 1024 * 1024 ))
}

days_to_seconds() {
  echo $(( $1 * 86400 ))
}

get_free_bytes() {
  quota | awk 'NR==3 { printf "%.0f\n", ($4 - $2) * 1024 }'
}

get_pending_bytes() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo 0
    return
  fi

  awk -v now="$(date +%s)" -v ttl="$PENDING_TTL_SECONDS" '
    NR==1 { ts=$1 }
    NR==2 { bytes=$1 }
    END {
      if (ts == "" || bytes == "") {
        print 0
      } else if ((now - ts) <= ttl) {
        print bytes
      } else {
        print 0
      }
    }
  ' "$STATE_FILE"
}

write_pending_bytes() {
  local bytes="$1"
  printf "%s\n%s\n" "$(date +%s)" "$bytes" > "$STATE_FILE"
}

clear_pending_bytes() {
  rm -f "$STATE_FILE"
}

login() {
  local resp
  resp="$(
    curl -fsS -k \
      -c "$COOKIE_JAR" \
      --data-urlencode "username=$QBIT_USERNAME" \
      --data-urlencode "password=$QBIT_PASSWORD" \
      "${QBIT_BASE_URL}/api/v2/auth/login"
  )"
  [[ "$resp" == "Ok." ]]
}

fetch_torrents() {
  curl -fsS -k \
    -b "$COOKIE_JAR" \
    "${QBIT_BASE_URL}/api/v2/torrents/info?category=${QBIT_CATEGORY}" \
    > "$TORRENTS_JSON"
}

build_delete_plan() {
  local need_bytes="$1"
  local max_seed_seconds="$2"

  python3 - "$TORRENTS_JSON" "$MIN_AGE_SECONDS" "$MIN_RATIO" "$max_seed_seconds" "$need_bytes" > "$PLAN_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
min_age = int(sys.argv[2])
min_ratio = float(sys.argv[3])
max_seed_seconds = int(sys.argv[4])
need_bytes = int(sys.argv[5])

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

candidates = []
for t in data:
    torrent_hash = t.get("hash", "")
    if not torrent_hash:
        continue

    time_active = int(t.get("time_active", 0) or 0)
    if time_active < min_age:
        continue

    ratio = float(t.get("ratio", 0) or 0)
    seeding_time = int(t.get("seeding_time", 0) or 0)

    # Protection rule:
    # below MIN_RATIO => protected, unless above MAX_SEED_DAYS
    if ratio < min_ratio and seeding_time <= max_seed_seconds:
        continue

    popularity = float(t.get("popularity", 0) or 0)
    stored_bytes = int(t.get("completed", 0) or 0)
    if stored_bytes <= 0:
        continue

    candidates.append({
        "hash": torrent_hash,
        "popularity": popularity,
        "stored_bytes": stored_bytes,
        "name": t.get("name", ""),
        "ratio": ratio,
        "seeding_time": seeding_time,
    })

candidates.sort(key=lambda x: x["popularity"])

planned = []
total = 0

for t in candidates:
    planned.append(t)
    total += t["stored_bytes"]
    if total >= need_bytes:
        break

for t in planned:
    print(
        f'{t["hash"]}\t{t["stored_bytes"]}\t{t["popularity"]}\t'
        f'{t["ratio"]}\t{t["seeding_time"]}\t{t["name"]}'
    )
PY
}

delete_one() {
  local hash="$1"
  curl -fsS -k \
    -b "$COOKIE_JAR" \
    -X POST \
    --data-urlencode "hashes=${hash}" \
    --data-urlencode "deleteFiles=true" \
    "${QBIT_BASE_URL}/api/v2/torrents/delete" > /dev/null
}

main() {
  local min_free_bytes free_bytes pending_bytes effective_free_bytes need_bytes
  local max_seed_seconds planned_total=0 planned_count=0

  log "=== RUN START ==="

  min_free_bytes="$(gb_to_bytes "$MIN_FREE_GB")"
  max_seed_seconds="$(days_to_seconds "$MAX_SEED_DAYS")"
  free_bytes="$(get_free_bytes)"

  log "free_bytes=$free_bytes min_free_bytes=$min_free_bytes"

  if (( free_bytes >= min_free_bytes )); then
    clear_pending_bytes
    log "Enough free space according to quota. Clearing pending state."
    log "=== RUN END ==="
    exit 0
  fi

  pending_bytes="$(get_pending_bytes)"
  effective_free_bytes=$((free_bytes + pending_bytes))

  log "pending_bytes=$pending_bytes effective_free_bytes=$effective_free_bytes"

  if (( effective_free_bytes >= min_free_bytes )); then
    log "Quota likely lagging; recent deletions should cover the gap."
    log "=== RUN END ==="
    exit 0
  fi

  need_bytes=$((min_free_bytes - effective_free_bytes))
  log "need_bytes=$need_bytes min_ratio=$MIN_RATIO max_seed_days=$MAX_SEED_DAYS"

  if ! login; then
    log "ERROR: qBittorrent login failed"
    log "=== RUN END ==="
    exit 2
  fi

  log "qBittorrent login successful"

  fetch_torrents
  log "Fetched racing torrents from qBittorrent"

  build_delete_plan "$need_bytes" "$max_seed_seconds"

  if [[ ! -s "$PLAN_FILE" ]]; then
    log "No eligible racing torrents to delete."
    log "=== RUN END ==="
    exit 1
  fi

  while IFS=$'\t' read -r hash stored_bytes popularity ratio seeding_time name; do
    [[ -n "${hash:-}" ]] || continue
    log "Deleting: popularity=$popularity ratio=$ratio seeding_time=$seeding_time bytes=$stored_bytes hash=$hash name=$name"
    delete_one "$hash"
    planned_total=$((planned_total + stored_bytes))
    planned_count=$((planned_count + 1))
  done < "$PLAN_FILE"

  write_pending_bytes $((pending_bytes + planned_total))

  log "planned_count=$planned_count planned_reclaim_bytes=$planned_total"
  log "pending_bytes_now=$((pending_bytes + planned_total))"
  log "=== RUN END ==="
}

main
