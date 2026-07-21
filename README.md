# 🐓 Downed Rooster

An ISP outage almanac. An OpenWrt router watches the line; a GitHub Pages
dashboard keeps the record.

**Live dashboard:** https://jcroy.github.io/downedrooster/
(append `?demo` to preview it with generated data)

## How it works

You can't report an outage *while* the line is down, so the monitor records
locally and publishes after the fact:

```
┌────────────── OpenWrt router ──────────────┐      ┌────────── GitHub ──────────┐
│ cron, every minute:                        │      │                            │
│   ping 1.1.1.1 / 8.8.8.8 / 9.9.9.9        │      │  data/outages.jsonl        │
│   (+ optional DB host check)               │      │  data/heartbeat.json       │
│                                            │      │        ▲                   │
│   down → note the timestamp (flash)        │      │        │ Contents API      │
│   up   → append outage to local queue ─────┼──────┼────────┘ (curl + PAT)      │
│   every 6h → heartbeat                     │      │                            │
└────────────────────────────────────────────┘      │  GitHub Pages serves       │
                                                    │  index.html ← reads data   │
                                                    └────────────────────────────┘
```

- The queue survives reboots (it lives on flash, written only on up/down
  transitions — never on the every-minute check).
- Every publish is a git commit, so the full history is also in `git log`.
- The heartbeat lets the dashboard tell "no outages" apart from "monitor dead".
- Two monitors: `wan` (internet, any ping target answering = up) and an
  optional `db` (any shell command you configure, e.g. a ping or TCP check
  against the database host you depend on).

## Repo layout

```
index.html                       the dashboard (GitHub Pages)
data/outages.jsonl               one JSON object per finished outage
data/heartbeat.json              last check-in from the router
openwrt/downedrooster.sh         the monitor (BusyBox ash)
openwrt/downedrooster.conf.example
```

Outage record format:

```json
{"monitor":"wan","start":"2026-07-20T03:12:41Z","end":"2026-07-20T03:26:05Z","duration_seconds":804}
```

Timestamps are UTC; the dashboard renders them in the viewer's local time.

## Router setup

1. **Create a token.** GitHub → Settings → Developer settings →
   [Fine-grained personal access tokens](https://github.com/settings/personal-access-tokens/new).
   Repository access: **only this repo**. Permissions: **Contents — Read and write**.
   Nothing else.

2. **Install the dependencies** (jsonfilter and base64 already ship with OpenWrt):

   ```sh
   opkg update && opkg install curl ca-bundle
   ```

3. **Copy the files over:**

   ```sh
   scp openwrt/downedrooster.sh root@192.168.1.1:/usr/bin/downedrooster.sh
   scp openwrt/downedrooster.conf.example root@192.168.1.1:/etc/downedrooster.conf
   ```

4. **On the router:**

   ```sh
   chmod +x /usr/bin/downedrooster.sh
   chmod 600 /etc/downedrooster.conf
   vi /etc/downedrooster.conf        # set GITHUB_TOKEN (and DB_CHECK_CMD if wanted)
   ```

5. **Add the cron job:**

   ```sh
   echo '* * * * * /usr/bin/downedrooster.sh' >> /etc/crontabs/root
   /etc/init.d/cron enable && /etc/init.d/cron restart
   ```

6. **Check it's alive:**

   ```sh
   /usr/bin/downedrooster.sh && logread -e downedrooster
   ```

   Within the first minute you should see a heartbeat commit land in the repo.

To stage a test outage without unplugging anything, point it at a dead target
once: `PING_TARGETS=203.0.113.1 DOWNEDROOSTER_CONF=/etc/downedrooster.conf /usr/bin/downedrooster.sh`
(that marks `wan` down), then run the script normally and watch the outage
record appear.

## Local preview

```sh
python3 -m http.server -d . 8080
# http://localhost:8080/?demo   ← generated sample data
# http://localhost:8080/        ← live data files
```

## Notes

- The published data is timestamps, durations, and the `PROVIDER` label you
  choose — never your IP address or hostname.
- Detection resolution is the cron interval (1 minute) — sub-minute blips can
  slip between checks.
- If the router loses power during an outage, the recorded start time survives
  (it's on flash), and the outage is published once both power and line return.
- Heartbeat commits are intentional noise (4/day at the default 6h). Raise
  `HEARTBEAT_HOURS` or set it to `0` in the conf to quiet them.
