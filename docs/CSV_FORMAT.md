# `players.log` CSV format

The bot is game-agnostic because it only reads one thing: a CSV file. Whatever produces that file is your game adapter.

## Schema (7 fields)

```
timestamp,server_name,action,player_name,ip:port,hash,extra
```

| Field | Format | Notes |
|---|---|---|
| `timestamp` | ISO 8601 UTC, e.g. `2026-05-15T19:46:31Z` | Required. Used for ordering and TTL on returning-player markers. |
| `server_name` | Any string, no commas | Must match the server's display name in your bot config. |
| `action` | One of `join`, `leave`, `command`, `state`, `startup` | See action semantics below. |
| `player_name` | Any string, no commas (strip or replace if needed) | Use empty string for non-player actions like `state` / `startup`. |
| `ip:port` | `ip` or `ip:port`. IPv4 only. | Empty string allowed for non-player actions. |
| `hash` | Opaque per-player ID (e.g. CD-key hash, Steam ID, account UUID) | Used together with name for dedup. Empty string is OK if your game has no equivalent. **Never** posted to Discord. |
| `extra` | Action-specific payload | See per-action format below. |

Rules:

- **No commas anywhere except as field separators.** Replace commas in names with spaces before writing.
- **No newlines.** Strip them.
- **UTF-8 encoding.** Other encodings work but the bot decodes with `errors='replace'`.
- **Append-only.** The bot tails the file using a byte-offset bookmark (`players.log.pos`). Don't rotate or truncate while the bot is running.

## Action semantics

### `join`

A player connected to the server. The bot:
- posts a `🟢 Player joined` Discord embed (country + VPN flag + connect command)
- updates `_active_players` set (used for dedup)
- adds the IP to `_seen_ips` (used for the `🔄 returning` marker)

`extra` is empty.

### `leave`

A player disconnected. The bot:
- posts a `🔴 Player left` Discord embed
- removes the player from `_active_players`

`extra` is empty. Must be paired with a prior `join` for the same `(server, name, hash)` key — orphan leaves are ignored.

### `command`

A player ran an in-game command (chat slash-command, RCON, etc). The bot:
- posts a `🛠️ Command used` Discord embed with the command text and admin level

`extra` format:
```
lvl=<admin_level>|cmd=<command_text>
```

Example:
```
2026-05-15T20:01:23Z,My Server,command,julivnexe,1.2.3.4:51234,abc123,lvl=3|cmd=/lo3
```

### `state`

A periodic heartbeat from the game adapter describing current server state. The bot updates its in-memory tracking; **no Discord post**.

`extra` format:
```
maxplayers=<n>
```

This is what keeps the "Players online: X/Y" count fresh when the operator changes `sv_maxplayers` (or its equivalent) at runtime. Emit at least one per minute, plus immediately on max-player config changes.

### `startup`

The game server (re)started. The bot:
- drops any stale "active" entries for this `server_name` from its in-memory dedup set
- **no Discord post**

`extra` is empty. Emit once when your adapter loads.

## Writing a minimal adapter

Pseudocode for an adapter that hooks `onPlayerJoin` / `onPlayerLeave` / `onCommand`:

```
def write_csv(action, name="", ip="", hash="", extra=""):
    ts = utc_now_iso_z()
    name = name.replace(",", " ").replace("\n", " ")
    extra = extra.replace(",", " ").replace("\n", " ")
    with open("/var/log/gameserver/players.log", "a") as f:
        f.write(f"{ts},{SERVER_NAME},{action},{name},{ip},{hash},{extra}\n")

def on_load():
    write_csv("startup")
    write_csv("state", extra=f"maxplayers={read_max_from_config()}")
    schedule_periodic(60_seconds, lambda: write_csv("state", extra=f"maxplayers={read_max()}"))

def on_join(player):    write_csv("join",    player.name, player.ip, player.hash)
def on_leave(player):   write_csv("leave",   player.name, player.ip, player.hash)
def on_command(player, cmd):
    write_csv("command", player.name, player.ip, player.hash,
              extra=f"lvl={player.admin_level}|cmd={cmd}")
```

That's the whole contract.

## Bookmark file

The bot writes its tail position to `players.log.pos` (default `/opt/halo-monitor/players.log.pos`). If you delete it, the bot replays the entire log on next start — useful for testing, but expect a Discord embed spam.

## Where the bot reads from

By default: `/opt/halo-monitor/players.log`. Override via `PLAYER_LOG` environment variable (see [`observability/.env.example`](../observability/.env.example) or [`monitor/halo-ddos-monitor.service`](../monitor/halo-ddos-monitor.service)).

For game adapters that can't write to that exact path (e.g. running in a container or chroot), mount it in or symlink — both work.
