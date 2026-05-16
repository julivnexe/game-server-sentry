# Game Server Sentry — Self-Hosted DDoS Defense + Discord Notifier


Free, self-hosted observability and DDoS protection for **any** UDP/TCP game server. Originally built for Halo CE; the per-game integration is now a pluggable adapter, with Halo CE shipped as the reference implementation.

What you get on a single VPS, no SaaS, no paid frontend:

- 🛡️ **Layered DDoS defense** — kernel hardening, per-source rate limits, public reputation feeds (FireHOL/Spamhaus), auto-banned attacker subnets via a Prometheus-driven trigger.
- 📣 **Discord notifications** — player joins/leaves with country flag + VPN detection, in-game command snitching, traffic spike alerts, watched-service crash/recovery.
- 📊 **Prometheus + Grafana** stack auto-provisioned for dashboards and metrics.
- 🎮 **Game-agnostic CSV protocol** — adapt to any game by emitting an 8-column CSV (schema `v1`) that the monitor tails. Halo CE adapter (SAPP Lua) included; templates for other engines in [`games/`](games/).

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
├── games/                Per-game integrations. CSV-emitting adapters.
│   └── halo-ce/          Reference: SAPP Lua scripts
└── docs/                 CSV protocol + architecture + ops notes
```

---

## How it works

```
   game server  ─────────────┐
   (Halo, MC, Source, etc)  │  writes CSV
                             ▼
                    /var/log/gameserver/players.log
                             │
                             │ tail
                             ▼
                      netmon-alert ───┬─► Discord webhook
                       (Python bot)   │
                                      ├─► /metrics (Prometheus scrape)
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

**The integration boundary is the CSV file.** Your game adapter writes rows; the bot does everything downstream. See [`docs/CSV_FORMAT.md`](docs/CSV_FORMAT.md) for the schema.

The `auto-banner` arrow in that diagram is the most operationally risky piece of the stack — it can drop legitimate players. Before turning it on, read [`docs/AUTO_BANNER.md`](docs/AUTO_BANNER.md) for thresholds, TTL, unbanning procedure, and false-positive scenarios.

---

## Quick start

### 1. Deploy the stack

```bash
cd observability
cp .env.example .env
$EDITOR .env                 # fill in DISCORD_WEBHOOK and game ports
docker compose up -d
```

See [`observability/STACK_README.md`](observability/STACK_README.md) for the full walkthrough (env vars, healthchecks, persistence, Grafana provisioning). If you used to run the legacy single-process daemon, see [`docs/MIGRATION.md`](docs/MIGRATION.md).

### 2. Pick (or write) a game adapter

- **Halo CE:** drop [`games/halo-ce/discord_notify.lua`](games/halo-ce/discord_notify.lua) into your SAPP `lua/` dir, add `lua_load discord_notify` to `init.txt`. See [`games/halo-ce/README.md`](games/halo-ce/README.md).
- **Other games:** see [`games/README.md`](games/README.md) for the adapter contract and example sketches (Minecraft plugin, SourceMod, Garry's Mod, etc).

> **Context for non-modders:** Halo CE (the PC version of Halo: Combat Evolved, 2003) has no first-class plugin API. The SAPP runtime is a community-maintained Lua-based modding framework that adds event hooks. `game-server-sentry` doesn't depend on SAPP — only the Halo CE adapter does. Other games will use their own plugin systems, log scrapers, or RCON pollers via the CSV contract.

### 3. Run the firewall hardening (optional but strongly recommended)

```
sudo bash firewall/update_reputation.sh   # populate halo-reputation ipset
# add iptables rules per firewall/README.md
```

See [`firewall/README.md`](firewall/README.md) for the full DDoS-hardening recipe (sysctl, iptables, ipset, rate limits).

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

Numbers from the live deployment running this stack 24/7:

- Player join → Discord post latency: // TODO: measure (target: under 2s end-to-end)
- Auto-banner trigger → ipset add: // TODO: measure
- Current /24s in halo-banlist: // TODO: read live
- Reputation feed size: ~4,600 CIDRs (FireHOL Level 1 + Spamhaus DROP/EDROP)
- Full-stack CPU at idle: // TODO: read from Grafana
- Full-stack memory: // TODO: read from Grafana
- Uptime since last redeploy: // TODO: read from Grafana

---

## Privacy posture

- `players.log` (which contains real IPs and CD-key hashes for Halo) is `.gitignore`d. **Never commit it.**
- CD-key hashes are never sent to Discord.
- IPs and country flags are sent by default — disable by editing `post_join_leave()` in the bot.
- VPN-using players are first-class: there is no VPN-blocking layer in this stack. Real-time VPN detection (proxycheck.io) is informational only, shown as an `⚠️ VPN detected` field in the embed, never used to gate access.

---

## Supported games

Halo CE has a shipping reference adapter. The CSV protocol is designed to extend to any game with a plugin API, RCON, or parseable logs — see [`docs/SUPPORTED_GAMES.md`](docs/SUPPORTED_GAMES.md) for the current compatibility matrix and [`docs/CSV_FORMAT.md`](docs/CSV_FORMAT.md) for the schema you'd target when writing a new adapter.

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

The Halo CE reference adapter is unaffiliated with Microsoft, Bungie, 343 Industries, or the SAPP author. Bring your own copy of Halo CE / SAPP.
