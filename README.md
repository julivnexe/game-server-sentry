# SoplonBOT — Halo CE Discord Notifier & DDoS Monitor

A small monitoring stack for Halo CE dedicated servers running SAPP on Linux + Wine.

Posts to a Discord webhook on:
- Player joins / leaves (with country flag, IP, VPN detection, and a "🔄 returning" marker)
- PPS / bandwidth / connection-flood spikes per server port
- Watched systemd services going down or coming back up

Works around the common SAPP-under-Wine quirk where `http_client()` is stubbed: the SAPP Lua side just appends to a local CSV, and a Python daemon tails that file and does the actual Discord delivery.

---

## Repo layout

```
halo-soplon-bot/
├── halo_ddos_monitor.py         # The Python monitor daemon
├── halo-ddos-monitor.service    # systemd unit (copy to /etc/systemd/system/)
├── lua/
│   ├── discord_notify.lua       # SAPP: writes join/leave CSV
│   ├── discord_welcome.lua      # Optional: posts an invite message on join
│   └── lo3_vote.lua             # Optional: unanimous in-chat lo3 vote
├── README.md
├── LICENSE
└── .gitignore
```

`players.log` (the on-disk forensics CSV) is intentionally `.gitignore`d. It contains real player IPs and CD-key hashes — never commit it.

---

## Requirements

- Ubuntu 22.04 (or similar) host running `haloceded.exe` under Wine.
- SAPP 10.2.1 CE (or compatible).
- Root / sudo on the host.
- Python 3.8+ with `python3-requests`:
  ```bash
  sudo apt install -y python3-requests iptables
  ```

---

## Installation

### 1. Drop the Python monitor in place

```bash
sudo mkdir -p /opt/halo-monitor
sudo install -m 755 halo_ddos_monitor.py /opt/halo-monitor/halo_ddos_monitor.py
sudo touch /opt/halo-monitor/players.log
```

### 2. Configure the systemd unit

Edit `halo-ddos-monitor.service` and set:

- `DISCORD_WEBHOOK` — your webhook URL (Server Settings → Integrations → Webhooks in Discord).
- `HALO_SERVERS` — comma-separated `port:Display Name` pairs, one per Halo server you run. Example for three servers:
  ```
  Environment="HALO_SERVERS=2302:Public,2303:Scrims,2304:Test"
  ```
  The display name appears in every Discord embed as the "Server" field, and is the value the Lua script writes to `players.log`, so it must match `SERVER_NAME` in each `discord_notify.lua` copy.
- `WATCHED_SERVICES` — comma-separated systemd unit names to watch for crash/recovery (e.g. `halo-server,halo-server-3`).
- *(optional)* `PROXYCHECK_KEY` — free signup at https://proxycheck.io/dashboard. Without it you get 100 VPN lookups/day from the free tier; with it, 1000/day.

Then install and start it:

```bash
sudo install -m 644 halo-ddos-monitor.service /etc/systemd/system/halo-ddos-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable --now halo-ddos-monitor
sudo systemctl status halo-ddos-monitor
```

You should see a green **🟢 Halo monitor online** embed in Discord with the list of watched ports.

### 3. Install the SAPP Lua side

For each Halo server you run, place `lua/discord_notify.lua` into that instance's SAPP lua directory (typically `cg/sapp/lua/`), edit the top:

```lua
local SERVER_NAME = "Server 1"   -- must match HALO_SERVERS in the systemd unit
```

Then add this line to that instance's `cg/sapp/init.txt`:

```
lua_load discord_notify
```

Restart the Halo server (or hot-load via rcon: `lua_load discord_notify`).

### 4. (Optional) Bonus Lua scripts

- `lua/discord_welcome.lua` — sends a private chat message to every joining player. Edit `WELCOME_MESSAGE` at the top. Add `lua_load discord_welcome` to `cg/sapp/init.txt`.
- `lua/lo3_vote.lua` — unanimous lo3 vote in chat. Pairs with a SAPP commands.txt alias (see file header). Add `lua_load lo3_vote` to `cg/sapp/init.txt`.

### 5. Make iptables counter rules persistent (optional but recommended)

The monitor inserts ACCEPT rules at startup for each watched port (they exist purely so we can read the packet/byte counters). To survive reboots:

```bash
sudo apt install -y iptables-persistent
sudo iptables-save | sudo tee /etc/iptables/rules.v4
```

---

## Configuration knobs

All set via the systemd unit's `Environment=` lines:

| Variable | Default | Purpose |
|---|---|---|
| `DISCORD_WEBHOOK` | *(required)* | Webhook URL |
| `HALO_SERVERS` | `2302:Server 1` | `port:name` list |
| `WATCHED_SERVICES` | `halo-server` | systemd units for liveness watch |
| `PROXYCHECK_KEY` | *(empty)* | proxycheck.io API key |
| `PPS_THRESHOLD` | `3000` | inbound packets/sec to alert on |
| `BPS_THRESHOLD` | `8388608` | bytes/sec to alert on (8 Mbps) |
| `UNIQUE_IPS_THRESHOLD` | `40` | unique src IPs in window to flood-alert |
| `UNIQUE_IPS_WINDOW_SEC` | `10` | flood-detection window |
| `ALERT_COOLDOWN_SEC` | `60` | minimum gap between alerts of same kind |
| `POLL_SEC` | `2` | main loop interval |
| `IFACE` | *(autodetect)* | override outbound interface name |
| `PLAYER_LOG` | `/opt/halo-monitor/players.log` | CSV path |
| `LOG_POS_FILE` | `/opt/halo-monitor/players.log.pos` | tail bookmark |

---

## Privacy model

`players.log` contains real player IPs and CD-key hashes. It's used internally for:
- Country / VPN lookup on join.
- Returning-visitor detection (matched by IP).
- Filtering known-player IPs out of DDoS attacker IP lists, so a laggy player isn't doxed as an attacker.

CD-key hashes are **never** sent to Discord. IPs and country flags **are** sent (in join/leave embeds and flood alerts). If you'd rather keep IPs off Discord:

- Edit `post_join_leave()` in `halo_ddos_monitor.py` and remove the `IP` field from the `fields` list.
- The country flag and VPN flag can stay since neither leaks the IP itself.

Keep your `#logs` Discord channel locked to mods/admins.

---

## Troubleshooting

**Monitor starts but no embeds appear.**
Test the webhook directly from the VPS:
```bash
curl -X POST -H 'Content-Type: application/json' \
  -d '{"content":"test"}' "$DISCORD_WEBHOOK"
```
If Discord receives it, the webhook is fine. Check `journalctl -u halo-ddos-monitor -f` for errors.

**Join/leave embeds aren't appearing but DDoS alerts work.**
The Lua script isn't writing to `players.log`. Check:
- The script is in the right `cg/sapp/lua/` for the instance you joined.
- `lua_load discord_notify` is in `cg/sapp/init.txt`.
- `SERVER_NAME` in the Lua matches what you set in `HALO_SERVERS`.
- The Halo process can write to `/opt/halo-monitor/` (since you run as root, it can).

**Map changes spam "Player joined" for everyone.**
The monitor dedupes via an in-memory `_active_players` set. It seeds from log replay at startup, so during the *first* map change after a restart you may see duplicate joins for already-present players. Subsequent map changes are clean.

**Embeds say a player is from "Country X" but I know they're from Y.**
proxycheck.io's accuracy is good but not perfect. Mobile and VPN traffic in particular often geolocates to the carrier's headquarters, not the user. There's no fix for this short of a paid geo provider.

**The 🔄 returning marker doesn't appear for someone I know joined before.**
The marker matches on **IP**, not name or hash. Dynamic IPs, VPN exit rotation, and mobile-cellular changes all break the match. False negatives are expected; false positives don't happen (unrelated households almost never share an IP).

---

## License

MIT — see `LICENSE`.

This project is unaffiliated with Microsoft, Bungie, 343 Industries, or the SAPP author. You bring your own copy of Halo CE / SAPP.
