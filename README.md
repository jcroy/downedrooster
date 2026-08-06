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
- While the line is down, every check stamps a sighting in `/tmp` — free, and
  wiped by a reboot, which is the point: an outage only counts for as long as
  the monitor actually watched it, never for as long as the clock says.
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
openwrt/test_downedrooster.sh    monitor tests — fake clock, fake ping, no network
```

Run the tests with `sh openwrt/test_downedrooster.sh`.

Outage record format:

```json
{"monitor":"wan","start":"2026-07-20T03:12:41Z","end":"2026-07-20T03:26:05Z","duration_seconds":804}
```

Timestamps are UTC; the dashboard renders them in the viewer's local time.

If the monitor lost sight of the line partway through — a reboot, a stalled
cron, a flash that went read-only — it says so instead of guessing, and the
dashboard marks the row with a ⚠:

```json
{"monitor":"wan","start":"2026-07-31T15:22:00Z","end":"2026-07-31T15:23:00Z","duration_seconds":60,"confirmed":false,"gap_seconds":246840}
```

`duration_seconds` is only ever downtime a check actually observed;
`gap_seconds` is how long the monitor was blind. Records without those two
fields were watched from start to finish.

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
- A silent monitor is not evidence of an outage. If the router loses power, the
  cron stalls, or the flash goes read-only mid-outage, the start time still
  survives on flash and the outage is published when the router comes back —
  but bounded to the downtime that was actually seen, with the unwatched
  stretch reported as `gap_seconds`. The one thing it will not do is bill you
  for days it wasn't looking.
- Heartbeat commits are intentional noise (4/day at the default 6h). Raise
  `HEARTBEAT_HOURS` or set it to `0` in the conf to quiet them.
