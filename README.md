# Halo CE Command Center

A full-stack operations toolkit for a self-hosted Halo: Combat Evolved (PC) dedicated server running under SAPP. Built for and tested on a Vultr VPS running two Halo CE instances 24/7.

One repo, one VPS, no SaaS, no paid frontend. What you get:

- 🛡️ **Layered DDoS defense** — kernel hardening, per-source rate limits, public reputation feeds (FireHOL/Spamhaus), auto-banned attacker subnets via a Prometheus-driven trigger.
- 📣 **Discord notifications** — player joins/leaves with country flag + VPN detection, in-game command snitching, traffic spike alerts, watched-service crash/recovery.
- 📊 **Prometheus + Grafana** stack auto-provisioned for dashboards and metrics.
- 🎯 **Stat tracker with KDA leaderboard** — per-IP kills/deaths/assists/captures, in-game `/stats`/`/top`/`/fragger`/`/capper`/`/rank` commands, mirrored to Discord slash commands. VPN-flagged IPs are logged but excluded from the public leaderboard.
- 🎮 **SAPP Lua scripts** — drop-in scripts that wire all the event hooks into the bot's CSV protocol.

---

## What's in this repo

```
.
├── observability/        Docker compose stack — netmon-alert + prometheus +
│                         grafana + node-exporter + auto-banner.
│                         This is the deployment.
├── firewall/             iptables/ipset hardening scripts
│                          - reputation feed updater (FireHOL/Spamhaus)
│                          - GeoIP whitelist updater (optional, disabled by default)
├── sapp/                 SAPP Lua scripts that run inside the Halo CE
│                         dedicated server. They write events to CSV/log
│                         files the bot tails.
└── docs/                 CSV protocol + architecture + ops notes
```

---

## How it works

```
   Halo CE dedicated server (haloceded + SAPP under Wine)
                │  SAPP Lua scripts append to:
                ▼
                /opt/halo-monitor/players.log    (joins / leaves / commands)
                /opt/halo-monitor/events.log     (kills / deaths / assists / caps)
                             │
                             │ tail
                             ▼
                      netmon-alert ───┬─► Discord webhook  +  /stats /top /fragger /capper /rank
                       (Python bot)   │       slash commands query the SQLite stats DB
                                      ├─► /metrics (Prometheus scrape)
                                      ├─► SQLite stats DB (kills/deaths/assists/caps per IP)
                                      ▼
                                  prometheus
                                      │
                                      ▼
                                  auto-banner
                                      │  on PPS spike → tcpdump
                                      │  → group by /24 → ipset add
                                      ▼
                               iptables drops attacker subnets
```

**The integration boundary is the CSV/log files.** SAPP appends rows; the bot does everything downstream. See [`docs/CSV_FORMAT.md`](docs/CSV_FORMAT.md) for the schema.

The `auto-banner` arrow is the most operationally risky piece — it can drop legitimate players. Before turning it on, read [`docs/AUTO_BANNER.md`](docs/AUTO_BANNER.md).

---

## Quick start

### 1. Deploy the stack

```bash
cd observability
cp .env.example .env
$EDITOR .env                 # fill in DISCORD_WEBHOOK and Halo ports
docker compose up -d
```

See [`observability/STACK_README.md`](observability/STACK_README.md) for the full walkthrough (env vars, healthchecks, persistence, Grafana provisioning). If you used to run the legacy single-process daemon, see [`docs/MIGRATION.md`](docs/MIGRATION.md).

### 2. Install the SAPP scripts

Drop the Lua files from [`sapp/`](sapp/) into your Halo CE instance's `cg/sapp/lua/` directory and add the matching `lua_load` lines to `cg/sapp/init.txt`. See [`sapp/README.md`](sapp/README.md) for the per-script details (server-name config, paths, in-game commands).

> **Context for non-modders:** Halo CE (the PC version of Halo: Combat Evolved, 2003) has no first-class plugin API. [SAPP](https://opencarnage.net/index.php?/topic/31-sapp/) is a community-maintained Lua-based modding framework that adds event hooks to the stock dedicated server. Without SAPP these scripts have nothing to attach to.

### 3. Run the firewall hardening (optional but strongly recommended)

```
sudo bash firewall/update_reputation.sh   # populate halo-reputation ipset
# add iptables rules per firewall/README.md
```

See [`firewall/README.md`](firewall/README.md) for the full DDoS-hardening recipe (sysctl, iptables, ipset, rate limits).

---

## Stat tracker (KDA leaderboard)

`sapp/stats_tracker.lua` hooks `EVENT_DIE`, `EVENT_DAMAGE_APPLICATION`, and `EVENT_SCORE` to log every kill, death, assist, and CTF flag capture to `/opt/halo-monitor/events.log`. The Python bot ingests that file into a SQLite database keyed by player IP.

**KDA formula:** `(kills + assists) / max(1, deaths)`, shown to one decimal.

### In-game commands

| Command | What it shows |
|---|---|
| `/stats`   | The caller's own K / D / A / C and KDA |
| `/top`     | Top 5 players by KDA (alias of `/fragger`) |
| `/fragger` | Top 5 players by KDA |
| `/capper`  | Top 5 players by flag captures |
| `/rank`    | The caller's rank among all tracked players |

### Discord commands

The same data is exposed via Discord slash commands posted by the bot:

| Slash | What it shows |
|---|---|
| `/stats <player>` | K/D/A/C and KDA for the named player (or yourself if linked) |
| `/top`            | Top 5 by KDA, posted as a Discord embed |
| `/fragger`        | Alias of `/top` |
| `/capper`         | Top 5 by captures |
| `/rank <player>`  | Rank for the named player |

The SQLite DB is shared between in-game and Discord paths — there's only one source of truth.

### VPN posture

On first sight of a new IP, the bot queries [ProxyCheck.io](https://proxycheck.io/) (free tier, 1000 lookups/day). VPN-flagged IPs are still logged to the events file and counted in their own personal `/stats`, but they're excluded from the public leaderboard so players using a VPN for legitimate privacy reasons don't lose visibility against non-VPN players. You can disable the VPN check entirely in the bot config.

---

## Defense layers, ranked by effectiveness

| Layer | Tool | What it catches |
|---|---|---|
| 1 | kernel sysctl (`tcp_syncookies=1`, `rp_filter=2`) | Spoofed-source amplification floods |
| 2 | iptables INPUT chain | Specific bad IPs, per-source-IP rate limit, per-port rate limit |
| 3 | ipset `halo-banlist` | Auto-banned attacker subnets (24h TTL) populated by `auto-banner` from live PPS spikes |
| 4 | ipset `halo-reputation` | Known-malicious IPs from FireHOL Level 1 + Spamhaus DROP/EDROP (~4.6K CIDRs, daily refresh) |
| 5 | ipset `halo-allowlist` | Verified players from `players.log` (bypass rate limits) |

Single-VPS realistic ceiling: ~5–10 Gbps. Beyond that, you need upstream filtering (your hosting provider's DDoS protection appliance — see [`docs/UPSTREAM.md`](docs/UPSTREAM.md)).

---

## Operational footprint

Numbers from the live deployment running this stack 24/7 on a Vultr VPS (Ubuntu 22.04, single vCPU):

- Current entries in `halo-banlist`: **42**
- Reputation feed size: **4,631 CIDRs** (FireHOL Level 1 + Spamhaus DROP/EDROP)
- Full-stack CPU at idle: **~0.8%** combined across 5 containers
- Full-stack memory: **~153 MB resident** (grafana 56, prometheus 31, netmon-alert 30, auto-banner 27, node-exporter 8)
- Grafana exposure: bound to `127.0.0.1`, accessed via SSH local-forward (originally was publicly exposed — see security note below)
- Uptime since last redeploy: // TODO: re-measure after stack has been stable for >24h
- Player join → Discord post latency: // TODO: instrument with a histogram metric

### Security notes

During the documentation pass for this README, I noticed Grafana was bound to `0.0.0.0:3000` and UFW allowed port 3000 from anywhere — meaning the dashboard was publicly reachable. Prometheus was correctly bound to `127.0.0.1` but Grafana wasn't, which made the protection on Prometheus theater (anyone could log into Grafana and query Prometheus through its datasource).

Fixed by rebinding the Grafana container to `127.0.0.1:3000:3000` in the compose file and removing the UFW rule for `3000/tcp`. Access is now via SSH local-forward only:

```
ssh -L 3000:127.0.0.1:3000 <vps>   # then open http://localhost:3000
```

Lesson: consistency across services matters more than getting one service right. If you bind one service to localhost for safety, audit every other service in the same compose file at the same time.

---

## Privacy posture

- `players.log`, `events.log`, and the SQLite stats DB (which contain real IPs and CD-key hashes) are `.gitignore`d. **Never commit them.**
- CD-key hashes are never sent to Discord.
- IPs and country flags are sent by default — disable by editing `post_join_leave()` in the bot.
- VPN-using players are first-class: there is no VPN-blocking layer in this stack. Real-time VPN detection (ProxyCheck.io) is informational only — shown as an `⚠️ VPN detected` field in the embed and used to keep the public KDA leaderboard fair, never used to gate access.

---

## Running tests

```
python -m pip install pytest
python -m pytest tests/
```

The suite covers the highest-risk surfaces: CSV parser (all row types + backward-compat shapes + malformed rows), auto-banner trigger threshold and /24 grouping logic, and the bogon-filter on the reputation feed (the loopback case that took an hour to diagnose in prod). 53 tests, runs in under a second, no docker or network required.

---

## License

MIT — see [`LICENSE`](LICENSE).

This project is unaffiliated with Microsoft, Bungie, 343 Industries, or the SAPP author. Bring your own copy of Halo CE / SAPP.
