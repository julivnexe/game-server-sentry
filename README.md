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

## Privacy posture

- `players.log` (which contains real IPs and CD-key hashes for Halo) is `.gitignore`d. **Never commit it.**
- CD-key hashes are never sent to Discord.
- IPs and country flags are sent by default — disable by editing `post_join_leave()` in the bot.
- VPN-using players are first-class: there is no VPN-blocking layer in this stack. Real-time VPN detection (proxycheck.io) is informational only, shown as an `⚠️ VPN detected` field in the embed, never used to gate access.

---

## Compatible games

Any game that lets you run a dedicated server **and** exposes one of: a plugin API, RCON, parseable server logs, or a status query protocol. The bot only consumes a CSV file — anything that can produce that file works.

Legend: ✅ = reference adapter shipped in this repo · 🟢 = plugin API I've verified exists, easy adapter · 🟡 = workable via log-scraping or RCON polling, more brittle.

| Game | Status | Integration surface |
|---|---|---|
| Halo: Combat Evolved (PC) | ✅ | [SAPP](https://opencarnage.net/index.php?/topic/31-sapp/) Lua — `EVENT_JOIN` / `EVENT_LEAVE` / `EVENT_COMMAND` |
| Minecraft Java (Spigot / Paper / Purpur) | 🟢 | Bukkit API — `PlayerJoinEvent`, `PlayerQuitEvent`, `PlayerCommandPreprocessEvent` |
| Minecraft Bedrock | 🟡 | Log scraper on BDS, or use a [WaterdogPE](https://github.com/WaterdogPE/WaterdogPE) proxy with plugins |
| Counter-Strike 2 / CS:GO / TF2 / L4D2 / DOD:S | 🟢 | [SourceMod](https://www.sourcemod.net/) — `OnClientConnected`, `OnClientDisconnect`, `say` cmd hooks |
| Garry's Mod | 🟢 | GLua hooks — `PlayerInitialSpawn`, `PlayerDisconnected`, `PlayerSay` |
| Rust (Facepunch) | 🟢 | [uMod / Oxide](https://umod.org/) plugin — `OnPlayerConnected`, `OnPlayerDisconnected`, `OnUserChat` |
| 7 Days to Die | 🟡 | Mod via Harmony, or `telnet`-based remote admin output parsing |
| Terraria (TShock) | 🟢 | [TShock](https://tshock.co/) plugin API — `PlayerHooks.PlayerPostLogin`, `ServerApi.Hooks.ServerLeave` |
| ARK: Survival Evolved | 🟡 | [ArkServerAPI](https://gameservershub.com/forums/resources/categories/ark-server-api.6/) (community framework) |
| Project Zomboid | 🟡 | Lua server events (`OnConnected`, `OnDisconnect`) |
| Valheim | 🟡 | [BepInEx](https://github.com/BepInEx/BepInEx) server-side mod or log scraping |
| Squad / Post Scriptum / Insurgency: Sandstorm | 🟡 | RCON player-list polling or log scraping |
| Killing Floor 2 | 🟡 | WebAdmin scraping or a server-side Mutator |
| Mordhau | 🟡 | RCON log scraping |
| Quake III / Wolfenstein ET / RTCW | 🟡 | Mod QVM hooks, or `getstatus` UDP query polling |
| Unreal Tournament series | 🟡 | UScript ServerActor |
| Any GameSpy-protocol game (Halo, UT, BF1942, MW2 IW4M, etc.) | 🟡 | `\status\` UDP query poller — works without server-side install |
| Any game with RCON | 🟡 | Poll `status` / `listplayers` every 5–10 s, diff and emit events |
| Any game with parseable join/leave log lines | 🟡 | `tail -F` log scraper |

**Caveat:** This list is "could be made to work with sensible effort." Of these, only Halo CE has a shipping adapter in this repo today. The 🟢 entries are weekend projects (~50–100 lines each), the 🟡 ones are weekend-and-a-half because log/RCON parsing is finicky. PRs welcome — see [`games/README.md`](games/README.md).

Games that **won't** work cleanly: anything where you can't run your own dedicated server (Valorant, Fortnite, modern CoD, Apex, etc.), or where the server is a closed binary with no plugin API and no useful log output (some Korean/Chinese MMO clients).

---

## Adding your own game

The bot only cares about one thing: a CSV file at `players.log` with rows like:

```
2026-05-15T19:46:31Z,My Server,join,playerName,1.2.3.4:51234,optional_hash,,v1
2026-05-15T19:48:12Z,My Server,leave,playerName,1.2.3.4:51234,optional_hash,,v1
2026-05-15T19:49:01Z,My Server,command,playerName,1.2.3.4:51234,optional_hash,lvl=3|cmd=/help,v1
2026-05-15T19:49:00Z,My Server,state,,,,maxplayers=16,v1
```

If your game can be made to emit those lines (via plugin, log scraper, RCON poller, gamespy query, etc), the bot handles everything else — Discord embeds, DDoS auto-ban, Prometheus metrics, the works.

See [`docs/CSV_FORMAT.md`](docs/CSV_FORMAT.md) for the full schema, and [`games/README.md`](games/README.md) for adapter design notes and patterns for common engines.

---

## License

MIT — see [`LICENSE`](LICENSE).

The Halo CE reference adapter is unaffiliated with Microsoft, Bungie, 343 Industries, or the SAPP author. Bring your own copy of Halo CE / SAPP.
