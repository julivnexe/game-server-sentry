# Halo CE Command Center

A full-stack operations toolkit for a self-hosted Halo Custom Edition dedicated server running under SAPP. Built for and tested on a Vultr VPS running two Halo CE instances 24/7.

One repo, one VPS, no SaaS, no paid frontend. What you get:

- 🛡️ **Layered DDoS defense** — kernel hardening, per-source + port-wide rate limits, amplification-reflector source-port blocks, public reputation feeds (FireHOL/Spamhaus), and **two auto-ban timers** that promote SAPP DOS_ATTACK detections and rate-limit offenders into a persistent ipset (survives reboot via `ipset-persistent`).
- 📣 **Discord notifications** — player joins/leaves with country flag + VPN detection, in-game command snitching, traffic spike alerts, match-end MVP/top-fragger summaries, auto-ban alerts, live server-status pinned embed.
- 📊 **Prometheus + Grafana** stack auto-provisioned for dashboards and metrics.
- 🎯 **Stat tracker with KDA leaderboard** — per-IP kills/deaths/assists/captures, in-game `/stats` `/top` `/fragger` `/capper` `/rank` `/commands`, mirrored to Discord slash commands. `/fragger` ranks by raw kills, `/top` by KDA — different orderings on purpose.
- 🎯 **Server-side hit-registration fix** — `lagcomp_v3.lua` keeps a 500ms ring buffer of every player's position/aim/crouch and re-classifies damage events using the shooter's ping-rewound view. When the engine calls a shot a body hit but the rewind says it was a headshot, the damage is boosted in-flight (4× for sniper-class, 2× for pistol/AR). Body-shots that "felt like" headshots from the shooter's POV now register correctly.
- 🛠 **Admin slash commands from Discord** — `/ban` `/kick` `/unban` `/map` `/restart` driven from your phone, role-gated. Bot writes to a SAPP command queue the in-game script drains every second.
- 🎮 **SAPP Lua scripts** — `discord_notify` (events CSV), `stats_tracker` (KDA), `lagcomp_v3` (hit reg), `halo_extras` (live status JSON + match summaries + admin queue).

---

## Wait, what does this actually do? (the plain-English version)

If you run your own Halo Custom Edition dedicated server, you've probably hit at least one of these problems:

- Some kid floods your server with junk traffic and crashes it for everyone.
- You have no idea who's currently playing on your server without booting up Halo yourself and joining to check.
- The server quietly dies at 3 AM and you find out next morning when people DM you asking why.
- There's no scoreboard that survives between games — you can't see who the actual top players are over time.
- Halo's stock hit registration is wonky — shots that clearly hit on your screen register as misses on the server because of network lag.
- You're not at your PC when a griefer joins, and you have no remote way to kick them.

**This project fixes all of that.** Once it's set up, your VPS will:

1. **Watch for attackers and auto-block them.** When someone tries to flood your server, the firewall figures out where it's coming from and bans them for 24 hours. You don't have to do anything.
2. **Ping your Discord every time someone joins or leaves.** With their country flag, whether they're using a VPN, and their player count. So you (and your community) actually know who's around.
3. **Track Kills, Deaths, Assists, and Flag Captures for every player.** Stored per-IP, so people get credit even if they change names. Type `/top` in chat and you see the leaderboard. Same data is available as Discord slash commands.
4. **Fix wonky hit registration** with a server-side lag compensation script. Shots that should have been headshots from the shooter's perspective (but registered as body shots due to network lag) get retroactively upgraded. ~10-15% of body hits in a typical session get rescued.
5. **Moderate from anywhere** with Discord admin slash commands. `/ban`, `/kick`, `/unban`, `/map`, `/restart` — role-gated, executes on the server within 1 second. You can run a server from your phone.
6. **Alert you when the server crashes** so you can restart it (or have it auto-restart).
7. **Give you pretty Grafana graphs** of traffic and player counts if you want to nerd out.

> **What's a VPS?** Short for "Virtual Private Server." It's just a computer you rent online — runs 24/7, has its own internet connection. Vultr, Linode, DigitalOcean, Hetzner, OVH all sell them. The cheapest tier (~$5/month, 1 CPU, 1 GB RAM) is enough for two Halo servers + everything in this repo.

---

## What you'll need before starting

Honest checklist — gather these first:

- **A VPS** running Ubuntu 22.04 or similar (any cheap Linux VPS works). You need SSH access as either `root` or a user with `sudo`.
- **Your own copy of Halo Custom Edition** with SAPP installed and a working dedicated server. This repo doesn't ship Halo itself — that's separate (see [`halo-vps-ansible`](https://github.com/julivnexe/halo-vps-ansible) for an automated way to set the Halo side up). If you already have a Halo server running on a VPS, you're good.
- **A Discord server you own**, with permission to create a webhook. Server Settings → Integrations → Webhooks → "New Webhook" → copy the URL. That URL is the secret that lets the bot post messages.
- **Some willingness to copy-paste commands into a terminal.** You don't need to know what they do — just paste and run.

If you don't have a Halo server set up yet, do that first. The rest of this README assumes you can SSH into your VPS and your Halo server is running on at least one port.

---

## Installation — for normal humans

This walkthrough assumes you have a VPS and a running Halo CE server. Replace `your-vps` with your VPS's IP or hostname.

### Step 1 — Connect to your VPS

```
ssh your-username@your-vps
```

If that works, you're in. Everything from here happens on the VPS.

### Step 2 — Install Docker (one-time)

Copy-paste this:
```
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
exit
```

Reconnect (the `exit` is important — your user needs to "see" Docker), then verify:
```
ssh your-username@your-vps
docker ps
```

If that prints an empty table instead of an error, you're good.

### Step 3 — Download this project

```
git clone https://github.com/julivnexe/Halo-CE-Command-Center.git
cd Halo-CE-Command-Center
```

### Step 4 — Tell it your secrets

```
cd observability
cp .env.example .env
nano .env
```

You'll see a list of settings. The two that matter:
- `DISCORD_WEBHOOK=` — paste the webhook URL you copied earlier
- `HALO_SERVERS=` — list your Halo ports and server names, like `2310:My Cool Server:16,2312:My Scrim Server:8`. The format is `port:name:maxplayers`.

Save (`Ctrl+O`, Enter, `Ctrl+X` in nano).

### Step 5 — Start everything

```
docker compose up -d
```

Wait ~30 seconds. Then check it's healthy:
```
docker compose ps
```

All five containers should say `running`.

### Step 6 — Install the SAPP scripts on your Halo server

Find your Halo server's SAPP lua folder (usually `cg/sapp/lua/` inside your Halo install) and drop these four files in:

| File | What it does |
|---|---|
| `sapp/discord_notify.lua` | Required. Writes join/leave/command events to `players.log` |
| `sapp/stats_tracker.lua` | Required for KDA + `/stats` `/top` `/fragger` `/capper` `/rank` `/commands` chat commands |
| `sapp/lagcomp_v3.lua` | Optional but recommended. Server-side hit registration fix |
| `sapp/halo_extras.lua` | Optional. Live server status JSON + match-end summaries + admin command queue (used by the Discord bot's `/ban` `/kick` etc.) |

Open each one in a text editor and find the line near the top:
```lua
local SERVER_NAME = "Server 1"
```
Change `"Server 1"` to **exactly** match the name you put in `HALO_SERVERS` in your `.env` file. If you have multiple Halo instances, each one needs its own copy of the scripts with the matching name.

Then add these lines to your Halo server's `cg/sapp/init.txt`:
```
lua_load discord_notify
lua_load stats_tracker
lua_load lagcomp_v3
lua_load halo_extras
```

Restart your Halo server.

### Step 7 — Test it

Join your Halo server. Within a couple seconds you should see a Discord message: "*PlayerName* joined Server 1, 1/16 players." Leave the server — you should get a leave message.

If you don't see anything in Discord:
- Run `docker compose logs -f netmon-alert` and try joining again. Watch what it prints.
- Check that your Halo server has write access to `/opt/halo-monitor/` on the VPS.
- Make sure the `SERVER_NAME` in the Lua script exactly matches the name in `.env`.

### Step 8 (optional) — Turn on the firewall hardening

This is the DDoS protection layer. It's optional because it can theoretically block legit players if it misfires — but in practice it's been solid. Read [`docs/AUTO_BANNER.md`](docs/AUTO_BANNER.md) first so you know what it'll do, then:
```
sudo bash firewall/update_reputation.sh
```
See [`firewall/README.md`](firewall/README.md) for the full hardening recipe (iptables rules, rate limits, etc).

---

## How it works (also in plain English)

The whole thing is built around one simple idea: **Halo writes events to a text file, and a small program watches the file.**

1. When something happens in Halo (someone joins, kills someone, captures a flag, whatever), a SAPP Lua script writes one line to a log file. That's it — Halo's job is done.
2. A Python program ("the bot") is constantly tailing that file. When it sees a new line, it figures out what kind of event it is and acts:
   - "Someone joined" → post a Discord message + remember their IP
   - "Someone got killed" → bump the killer's kill count in the database
   - "Server PPS spiked" → grab packet captures + ban the source subnet
3. Meanwhile, a firewall layer (separate from the bot) keeps a list of bad IPs and drops their packets before they ever reach Halo. The bot adds attackers to this list automatically.
4. The Grafana dashboard reads metrics out of Prometheus, which scrapes them from the bot. That's where the live graphs come from.

The reason it's split into pieces (Lua + Python + Prometheus + iptables) instead of one giant program: each piece does one thing well, and if one crashes, the others keep working. The bot can die and your Halo server keeps running. Halo can crash and the bot keeps watching for it to come back. The firewall doesn't care if either is up — it just drops the packets it's told to drop.

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

> **Context for non-modders:** Halo Custom Edition (released 2004) is a free standalone PC client built on top of the original Halo: Combat Evolved engine, designed specifically to support custom maps and community modding. It has no first-class plugin API — [SAPP](https://opencarnage.net/index.php?/topic/31-sapp/) is a community-maintained Lua-based modding framework that adds event hooks to the stock dedicated server. Without SAPP these scripts have nothing to attach to.

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
| `/stats`    | The caller's own K / D / A / C and KDA |
| `/top`      | Top 5 by **KDA** (overall skill — kills/(deaths+assists)) |
| `/fragger`  | Top 5 by **raw kill count** (different ordering from `/top`) |
| `/capper`   | Top 5 by flag captures |
| `/rank`     | The caller's rank among all tracked players |
| `/commands` | This list |

Responses appear in chat (persist ~10s), not the 1-second console overlay.

### Discord slash commands

The same data is exposed via Discord slash commands posted by the bot:

| Slash | What it shows |
|---|---|
| `/stats <player>` | K/D/A/C and KDA for the named player |
| `/top`            | Top 5 by KDA |
| `/fragger`        | Top 5 by raw kills |
| `/capper`         | Top 5 by captures |
| `/rank <player>`  | Rank for the named player |
| `/commands`       | This list |

### Admin slash commands (role-gated)

| Slash | What it does |
|---|---|
| `/ban <player>`            | IP + CD-key ban (1-day default) |
| `/kick <player>`           | Boot from server |
| `/unban <ip>`              | Undo a ban |
| `/map <name> <gametype>`   | Switch to a different map |
| `/restart`                 | Reset current match |

The bot writes the command to `/opt/halo-monitor/sapp_command_queue.txt`. `halo_extras.lua` drains the queue every second and runs each line via `execute_command()`. Set `ADMIN_ROLE_ID` in `bot.env` to enable — without it, the commands refuse with "Admin role required" so randos can't run them.

### VPN posture

On first sight of a new IP, the bot queries [ProxyCheck.io](https://proxycheck.io/) (free tier, 1000 lookups/day). VPN-flagged IPs are still logged to the events file and counted in their own personal `/stats`, but they're excluded from the public leaderboard so players using a VPN for legitimate privacy reasons don't lose visibility against non-VPN players. You can disable the VPN check entirely in the bot config.

---

## Defense layers, ranked by effectiveness

| Layer | Tool | What it catches |
|---|---|---|
| 1 | kernel sysctl (`tcp_syncookies=1`, `rp_filter=2`) | Spoofed-source amplification floods |
| 2 | iptables: amplification-reflector source-port DROP (UDP src 19/53/123/161/389/1900/5353/11211) | Chargen/DNS/NTP/SNMP/LDAP/SSDP/mDNS/memcached reflection attacks |
| 3 | iptables: tiny-UDP DROP (`length 0:15` on game ports) | Empty/tiny UDP floods that aren't real Halo packets |
| 4 | ipset `halo-geo-allow` ACCEPT (before banlist DROP) | Verified players' rules win over false-positive bans |
| 5 | ipset `halo-banlist` DROP | Auto-banned attacker IPs/subnets, 24h–7d TTL |
| 6 | ipset `halo-reputation` DROP (excl. loopback) | Known-malicious IPs from FireHOL Level 1 + Spamhaus DROP/EDROP (~4.6K CIDRs) |
| 7 | iptables hashlimit per-source (60/sec/IP) | Single-source flood |
| 8 | iptables hashlimit per-port (400/sec) | Aggregate flood across many sources |
| 9 | INPUT default DROP | Catch-all for anything not explicitly accepted |

**Two auto-ban timers** keep the banlist fresh:
- `sapp-ipban-sync.timer` (every 60s) — reads SAPP's UTF-16 logs for DOS_ATTACK detections, promotes to `halo-banlist` with 7-day TTL, cross-checks `halo-geo-allow` so verified players aren't false-banned
- `ratelimit-autoban.timer` (every 30s) — reads conntrack for sources with >200 game-port flows, auto-bans

Persistence via `ipset-persistent` + `netfilter-persistent` — both the iptables rules AND the ipset contents survive reboot.

Single-VPS realistic ceiling: ~5–10 Gbps. Beyond that, you need upstream filtering (your hosting provider's DDoS protection appliance — see [`docs/UPSTREAM.md`](docs/UPSTREAM.md)).

### Admin path fallback: Tailscale

During a sustained attack, your hosting provider's edge filter may null-route admin SSH from your home IP while UDP game traffic keeps flowing. Recommended fallback: install Tailscale on the VPS — gives the box a `100.x.y.z` overlay address reachable from any device on the same tailnet, completely bypassing the public-internet block.

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
