#!/bin/sh
# Tests for downedrooster.sh — run from anywhere: sh openwrt/test_downedrooster.sh
#
# The script is driven through fake time (FAKE_NOW), a fake ping (FAKE_NET) and
# an empty GITHUB_REPO, which makes it stop right after recording and leaves the
# queue on disk for inspection. Nothing touches the network or the real /tmp.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/downedrooster.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; printf '       want: %s\n       got:  %s\n' "$2" "$3"; fails=$((fails + 1)); }

# ---------- stubs ----------

mkdir -p "$TMP/bin"

cat > "$TMP/bin/date" <<'EOF'
#!/bin/sh
# "now" comes from FAKE_NOW; -d conversions pass through to the real date.
for a in "$@"; do [ "$a" = "-d" ] && exec /bin/date "$@"; done
fmt=""
for a in "$@"; do case "$a" in +*) fmt="$a" ;; esac; done
[ "$fmt" = "+%s" ] && { echo "$FAKE_NOW"; exit 0; }
exec /bin/date -u -d "@$FAKE_NOW" "$fmt"
EOF

cat > "$TMP/bin/ping" <<'EOF'
#!/bin/sh
exit "${FAKE_NET:-0}"
EOF

cat > "$TMP/bin/logger" <<'EOF'
#!/bin/sh
shift 2
echo "$*" >> "$TEST_LOG"
EOF

chmod +x "$TMP/bin/date" "$TMP/bin/ping" "$TMP/bin/logger"

# ---------- harness ----------

STATE=""; RUN=""; LOG=""

reset() {
    rm -rf "$TMP/state" "$TMP/run" "$TMP/log"
    mkdir -p "$TMP/state" "$TMP/run"
    : > "$TMP/log"
    STATE="$TMP/state"; RUN="$TMP/run"; LOG="$TMP/log"
}

# run <epoch> <0=link up|1=link down>
# stderr is kept (the unwritable-flash case is meant to produce some) but parked
# in $TMP/stderr so it does not scribble over the results.
run() {
    PATH="$TMP/bin:$PATH" \
    FAKE_NOW="$1" FAKE_NET="$2" TEST_LOG="$LOG" \
    DOWNEDROOSTER_CONF="$TMP/absent.conf" \
    STATE_DIR="$STATE" RUN_DIR="$RUN" \
    GITHUB_REPO="" GITHUB_TOKEN="" \
    sh "$SCRIPT" 2>> "$TMP/stderr"
}

queue() { cat "$STATE/queue.jsonl" 2>/dev/null; }
iso() { /bin/date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

check() {
    got=$(queue)
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1" "$2" "$got"; fi
}

T0=$(/bin/date -u -d '2026-07-31T15:22:00Z' +%s)

echo "downedrooster.sh"

# ---------- a plain one-minute blip: unchanged behaviour ----------

reset
run "$T0" 1
run $((T0 + 60)) 0
check "one-minute blip is recorded as 60s, no flags" \
  "{\"monitor\":\"wan\",\"start\":\"$(iso "$T0")\",\"end\":\"$(iso $((T0 + 60)))\",\"duration_seconds\":60}"

# ---------- a real outage watched all the way through ----------

reset
run "$T0" 1
run $((T0 + 60)) 1
run $((T0 + 120)) 1
run $((T0 + 180)) 0
check "outage watched throughout keeps its full duration" \
  "{\"monitor\":\"wan\",\"start\":\"$(iso "$T0")\",\"end\":\"$(iso $((T0 + 180)))\",\"duration_seconds\":180}"

# ---------- the bug: monitor stops watching, link is fine ----------
# 2026-07-31: link blipped once, the monitor then went blind for 2d 20h and on
# its return billed the whole window as downtime.

reset
run "$T0" 1
run $((T0 + 246900)) 0
check "blind stretch is a gap, not downtime" \
  "{\"monitor\":\"wan\",\"start\":\"$(iso "$T0")\",\"end\":\"$(iso $((T0 + 60)))\",\"duration_seconds\":60,\"confirmed\":false,\"gap_seconds\":246840}"

# ---------- the same, with the flash unwritable (the actual incident) ----------
# The marker cannot be cleared and the queue cannot be appended to, so the
# outage stays open until a reboot restores the filesystem.

if [ "$(id -u)" = "0" ]; then
    printf '  skip unwritable flash (running as root)\n'
else
    reset
    run "$T0" 1
    chmod a-w "$STATE"
    run $((T0 + 60)) 0
    run $((T0 + 120)) 0
    run $((T0 + 180)) 0
    chmod u+w "$STATE"
    run $((T0 + 246900)) 0
    check "unwritable flash cannot inflate the record" \
      "{\"monitor\":\"wan\",\"start\":\"$(iso "$T0")\",\"end\":\"$(iso $((T0 + 60)))\",\"duration_seconds\":60,\"confirmed\":false,\"gap_seconds\":246840}"
fi

# ---------- router reboots in the middle of a genuine outage ----------
# Volatile state is lost, so the unwatched hour is reported as a gap instead of
# being claimed as downtime.

reset
run "$T0" 1
run $((T0 + 60)) 1
rm -rf "$RUN"; mkdir -p "$RUN"          # reboot: tmpfs is empty again
run $((T0 + 3660)) 1
run $((T0 + 3720)) 0
check "reboot mid-outage reports the unwatched hour as a gap" \
  "{\"monitor\":\"wan\",\"start\":\"$(iso "$T0")\",\"end\":\"$(iso $((T0 + 3720)))\",\"duration_seconds\":60,\"confirmed\":false,\"gap_seconds\":3660}"

# ---------- nothing recorded while the link is fine ----------

reset
run "$T0" 0
run $((T0 + 60)) 0
check "no record when the link never dropped" ""

# ---------- an outage still in progress is not published early ----------

reset
run "$T0" 1
run $((T0 + 60)) 1
check "outage in progress stays unpublished" ""

echo
if [ "$fails" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$fails test(s) failed"
fi
exit $((fails > 0))
