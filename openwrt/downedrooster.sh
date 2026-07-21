#!/bin/sh
# downedrooster — ISP outage monitor for OpenWrt
#
# Run from cron every minute. Detects connectivity loss, logs the outage
# locally while the line is down, then publishes finished outage records to
# a GitHub Pages repo via the Contents API once the link returns.
#
# Needs only: BusyBox ash, curl, ca-bundle, jsonfilter, base64
# (jsonfilter and base64 ship with stock OpenWrt; `opkg install curl ca-bundle`).

CONF="${DOWNEDROOSTER_CONF:-/etc/downedrooster.conf}"
[ -f "$CONF" ] && . "$CONF"

GITHUB_REPO="${GITHUB_REPO:-}"          # "owner/name"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"        # fine-grained PAT, Contents read/write
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
PING_TARGETS="${PING_TARGETS:-1.1.1.1 8.8.8.8 9.9.9.9}"
DB_CHECK_CMD="${DB_CHECK_CMD:-}"        # optional second monitor; exit 0 = up
HEARTBEAT_HOURS="${HEARTBEAT_HOURS:-6}" # 0 disables heartbeat
PROVIDER="${PROVIDER:-}"                # ISP name shown on the dashboard (never the IP)
STATE_DIR="${STATE_DIR:-/etc/downedrooster}"
OUTAGES_PATH="${OUTAGES_PATH:-data/outages.jsonl}"
HEARTBEAT_PATH="${HEARTBEAT_PATH:-data/heartbeat.json}"

API="https://api.github.com/repos/$GITHUB_REPO/contents"
QUEUE="$STATE_DIR/queue.jsonl"
NOW=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() { logger -t downedrooster "$*"; }

mkdir -p "$STATE_DIR"

# One run at a time; a lock older than 10 minutes is stale (crashed run).
LOCK="/tmp/downedrooster.lock"
if [ -f "$LOCK" ]; then
    lock_ts=$(cat "$LOCK" 2>/dev/null)
    [ -n "$lock_ts" ] && [ $((NOW - lock_ts)) -lt 600 ] && exit 0
fi
echo "$NOW" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

net_up() {
    for t in $PING_TARGETS; do
        ping -c 1 -W 2 "$t" >/dev/null 2>&1 && return 0
    done
    return 1
}

# track <monitor> <0=up|1=down> — record transitions, queue finished outages.
# State survives reboot (flash), but is only written on transitions.
track() {
    sf="$STATE_DIR/$1.down"
    if [ "$2" = "1" ]; then
        if [ ! -f "$sf" ]; then
            echo "$NOW $NOW_ISO" > "$sf"
            log "$1 went DOWN"
        fi
    elif [ -f "$sf" ]; then
        read -r start_ts start_iso < "$sf"
        dur=$((NOW - start_ts))
        printf '{"monitor":"%s","start":"%s","end":"%s","duration_seconds":%s}\n' \
            "$1" "$start_iso" "$NOW_ISO" "$dur" >> "$QUEUE"
        rm -f "$sf"
        log "$1 back UP after ${dur}s"
    fi
}

if net_up; then WAN=0; else WAN=1; fi
track wan "$WAN"

if [ -n "$DB_CHECK_CMD" ]; then
    if sh -c "$DB_CHECK_CMD" >/dev/null 2>&1; then track db 0; else track db 1; fi
fi

# Publishing needs a working link and credentials.
[ "$WAN" = "1" ] && exit 0
[ -n "$GITHUB_REPO" ] && [ -n "$GITHUB_TOKEN" ] || exit 0

gh_get() {
    curl -fsS -m 20 \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "$API/$1?ref=$GITHUB_BRANCH"
}

# gh_put <path> <commit message> <base64 content> <sha or empty>
gh_put() {
    body="{\"message\":\"$2\",\"branch\":\"$GITHUB_BRANCH\",\"content\":\"$3\""
    [ -n "$4" ] && body="$body,\"sha\":\"$4\""
    body="$body}"
    curl -fsS -m 30 -X PUT \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -d "$body" "$API/$1" >/dev/null 2>&1
}

# Push queued outages: fetch current file, append, PUT back.
# On any failure the queue is kept and retried next minute.
if [ -s "$QUEUE" ]; then
    sha=""
    existing=""
    resp=$(gh_get "$OUTAGES_PATH" 2>/dev/null)
    if [ -n "$resp" ]; then
        sha=$(printf '%s' "$resp" | jsonfilter -e '@.sha')
        existing=$(printf '%s' "$resp" | jsonfilter -e '@.content' | base64 -d 2>/dev/null)
    fi
    n=$(wc -l < "$QUEUE")
    b64=$({ [ -n "$existing" ] && printf '%s\n' "$existing"; cat "$QUEUE"; } | base64 | tr -d '\n')
    if gh_put "$OUTAGES_PATH" "record $n outage(s) at $NOW_ISO" "$b64" "$sha"; then
        : > "$QUEUE"
        log "published $n outage record(s)"
    else
        log "publish failed, keeping queue for retry"
    fi
fi

# Heartbeat so the dashboard can tell "no outages" from "monitor dead".
# Timer lives in /tmp: a reboot just sends one extra heartbeat.
if [ "$HEARTBEAT_HOURS" -gt 0 ] 2>/dev/null; then
    hb="/tmp/downedrooster.heartbeat"
    last=$(cat "$hb" 2>/dev/null)
    [ -n "$last" ] || last=0
    if [ $((NOW - last)) -ge $((HEARTBEAT_HOURS * 3600)) ]; then
        sha=""
        resp=$(gh_get "$HEARTBEAT_PATH" 2>/dev/null)
        [ -n "$resp" ] && sha=$(printf '%s' "$resp" | jsonfilter -e '@.sha')
        payload=$(printf '{"last_heartbeat":"%s","interval_hours":%s,"provider":"%s"}' "$NOW_ISO" "$HEARTBEAT_HOURS" "$PROVIDER")
        b64=$(printf '%s\n' "$payload" | base64 | tr -d '\n')
        gh_put "$HEARTBEAT_PATH" "heartbeat $NOW_ISO" "$b64" "$sha" && echo "$NOW" > "$hb"
    fi
fi

exit 0
