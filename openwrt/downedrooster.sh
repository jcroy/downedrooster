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
STATE_DIR="${STATE_DIR:-/etc/downedrooster}"        # survives reboot (flash)
RUN_DIR="${RUN_DIR:-/tmp/downedrooster}"            # cleared by reboot (tmpfs)
POLL_SECONDS="${POLL_SECONDS:-60}"      # how often cron runs this script
MAX_GAP_SECONDS="${MAX_GAP_SECONDS:-$((POLL_SECONDS * 3))}"  # missed checks before we admit we stopped watching
OUTAGES_PATH="${OUTAGES_PATH:-data/outages.jsonl}"
HEARTBEAT_PATH="${HEARTBEAT_PATH:-data/heartbeat.json}"

API="https://api.github.com/repos/$GITHUB_REPO/contents"
QUEUE="$STATE_DIR/queue.jsonl"
NOW=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() { logger -t downedrooster "$*"; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -D %s -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

mkdir -p "$STATE_DIR" "$RUN_DIR"

# One run at a time; a lock older than 10 minutes is stale (crashed run).
LOCK="$RUN_DIR/lock"
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
#
# An outage lasts as long as we SAW the link down, never as long as the clock
# says it has been since it dropped. Those differ whenever the monitor stops
# looking: a stalled cron, a reboot, a read-only or full flash that refuses to
# clear the marker. Counting the blind stretch as downtime turns "we lost
# track" into "the internet was out" and inflates a one-minute blip into days.
#
# So each check that finds the link down stamps a sighting in RUN_DIR — RAM, so
# it costs no flash write, and a reboot wipes it, which is exactly the truth: we
# were not watching. A stretch longer than MAX_GAP_SECONDS with no sighting is
# banked as blind time and published as a gap the dashboard can flag, never as
# downtime. Only start and banked blind time live on flash, still written on
# transitions alone.
track() {
    sf="$STATE_DIR/$1.down"           # start_ts start_iso blind_seconds
    seen="$RUN_DIR/$1.seen"           # last check that confirmed it down

    if [ "$2" = "1" ]; then
        if [ ! -f "$sf" ]; then
            printf '%s %s 0\n' "$NOW" "$NOW_ISO" > "$sf" || log "ERROR: cannot write $sf"
            log "$1 went DOWN"
        else
            # Still down. If we lost sight of it since the last check, bank the
            # blind stretch now — it is rare, so the flash write is cheap.
            read -r start_ts start_iso blind < "$sf"
            [ -n "$blind" ] || blind=0
            last=$(cat "$seen" 2>/dev/null)
            [ -n "$last" ] || last="$start_ts"
            gap=$((NOW - last))
            if [ "$gap" -gt "$MAX_GAP_SECONDS" ]; then
                printf '%s %s %s\n' "$start_ts" "$start_iso" "$((blind + gap))" > "$sf" \
                    || log "ERROR: cannot write $sf"
                log "$1 unwatched for ${gap}s mid-outage — not counting it as downtime"
            fi
        fi
        echo "$NOW" > "$seen"
        return 0
    fi

    [ -f "$sf" ] || return 0

    read -r start_ts start_iso blind < "$sf"
    [ -n "$blind" ] || blind=0
    last=$(cat "$seen" 2>/dev/null)
    [ -n "$last" ] || last="$start_ts"

    # Up again. A recent sighting means we watched it come back, so the outage
    # ran until now. A stale one means we only know it was down as far as that
    # sighting, plus the one poll interval that is our detection resolution —
    # everything after that is blind, not downtime.
    trailing=0
    if [ $((NOW - last)) -le "$MAX_GAP_SECONDS" ]; then
        end_ts="$NOW"
        end_iso="$NOW_ISO"
    else
        end_ts=$((last + POLL_SECONDS))
        [ "$end_ts" -gt "$NOW" ] && end_ts="$NOW"
        end_iso=$(iso "$end_ts")
        trailing=$((NOW - end_ts))
    fi

    # Blind stretches inside the outage come off its duration; the one after it
    # ends never counted towards it. Both are reported as the gap.
    dur=$((end_ts - start_ts - blind))
    [ "$dur" -lt 0 ] && dur=0
    blind=$((blind + trailing))

    if [ "$blind" -gt 0 ]; then
        rec=$(printf '{"monitor":"%s","start":"%s","end":"%s","duration_seconds":%s,"confirmed":false,"gap_seconds":%s}' \
            "$1" "$start_iso" "$end_iso" "$dur" "$blind")
        note="back UP — ${dur}s confirmed down, ${blind}s unwatched"
    else
        rec=$(printf '{"monitor":"%s","start":"%s","end":"%s","duration_seconds":%s}' \
            "$1" "$start_iso" "$end_iso" "$dur")
        note="back UP after ${dur}s"
    fi

    # Only forget the outage once its record is safely queued.
    if printf '%s\n' "$rec" >> "$QUEUE"; then
        log "$1 $note"
        rm -f "$sf" "$seen"
        if [ -f "$sf" ]; then
            log "ERROR: cannot clear $sf — $STATE_DIR may be read-only or full"
        fi
    else
        log "ERROR: cannot append to $QUEUE — $1 outage held open for retry"
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
# Timer lives in RUN_DIR: a reboot just sends one extra heartbeat.
if [ "$HEARTBEAT_HOURS" -gt 0 ] 2>/dev/null; then
    hb="$RUN_DIR/heartbeat"
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
