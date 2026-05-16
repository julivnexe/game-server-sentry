# `players.log` — schema spec (v1)

This is the integration boundary between game adapters and the bot. Treat it like an API.

**Current version:** `v1`.

## Schema v1 — column list

A row is comma-separated, terminated by `\n`, encoded UTF-8.

| # | Column | Type | Required | Notes |
|--:|---|---|---|---|
| 1 | `timestamp`     | ISO 8601 UTC, `2026-05-15T19:46:31Z` | yes | Used for ordering and returning-player TTLs. |
| 2 | `server_name`   | string                              | yes (`""` allowed for service rows) | Must match the bot's display name for the server. See [escaping](#escaping) for commas. |
| 3 | `action`        | enum: `join` · `leave` · `command` · `state` · `startup` | yes | See [row types](#row-types). |
| 4 | `player_name`   | string                              | conditional | Empty for `state` / `startup`. |
| 5 | `ip:port`       | `ip` or `ip:port`, IPv4             | conditional | Empty for `state` / `startup`. |
| 6 | `hash`          | opaque per-player ID                | conditional | CD-key hash, Steam ID, account UUID — whatever your game has. Empty allowed. **Never** sent to Discord. |
| 7 | `extra`         | action-specific payload             | yes (may be empty) | See per-row format below. |
| 8 | `schema_version`| string, e.g. `v1`                   | optional (legacy rows omit it; treated as `v1`) | Added for forward compatibility. New adapters MUST emit it. |

7-field rows (no `schema_version`) are parsed as `v1` for backward compatibility. **New writers must emit 8 fields with `v1` as the last.**

## Row types

### `join`

```
2026-05-15T19:46:31Z,My Server,join,playerName,1.2.3.4:51234,abc123,,v1
```

- Posts a `🟢 Player joined` Discord embed (country + VPN flag + connect command).
- Adds the player to the bot's in-memory `_active_players` and `_seen_ips` sets.

`extra` is empty.

### `leave`

```
2026-05-15T19:48:12Z,My Server,leave,playerName,1.2.3.4:51234,abc123,,v1
```

- Posts a `🔴 Player left` Discord embed.
- Removes the player from `_active_players`.
- Must be paired with a prior `join` for the same `(server_name, player_name, hash)` key; orphan leaves are dropped silently.

`extra` is empty.

### `command`

```
2026-05-15T19:49:01Z,My Server,command,playerName,1.2.3.4:51234,abc123,lvl=3|cmd=/lo3,v1
```

- Posts a `🛠️ Command used` Discord embed.
- No state change.

`extra` format:
```
lvl=<admin_level>|cmd=<command_text>
```

Both keys required. `admin_level` is `0` for unprivileged players. `command_text` is the raw command as the player typed it (including the slash if any).

### `state`

```
2026-05-15T19:49:00Z,My Server,state,,,,maxplayers=16,v1
```

- Updates the bot's per-server max-player count.
- **No Discord post.**

`extra` format:
```
maxplayers=<n>
```

Emit on adapter load, on periodic heartbeat (≥ every 60 s recommended), and on detected runtime change (e.g. `sv_maxplayers <n>` or its alias). Game adapters that can't observe max-player changes should at least emit the boot value once.

### `startup`

```
2026-05-15T19:23:41Z,My Server,startup,,,,,v1
```

- The game server (re)started.
- The bot drops any stale "active" entries for this `server_name` from its in-memory dedup set.
- **No Discord post.**

`extra` is empty.

## Escaping

**No commas, newlines, or carriage returns anywhere except as field separators / row terminators.** The repo deliberately does **not** implement RFC 4180 double-quote escaping; the cost in adapter complexity (every plugin language needs a quoting routine) outweighs the convenience of letting `,` appear in names.

Adapter responsibility: before writing a field, replace any of `,`, `\n`, `\r` with a space (or any non-comma character). The reference Halo CE Lua adapter uses:

```lua
local function csv_safe(s)
    return tostring(s or ""):gsub(",", " "):gsub("\n", " "):gsub("\r", "")
end
```

The bot's parser does **not** un-escape. Whatever the adapter wrote is what shows up in the Discord embed.

UTF-8 is the expected encoding. The bot decodes with `errors='replace'` so a stray invalid byte in a player name renders as `�` rather than crashing the parser, but adapters should avoid producing invalid sequences.

## Append-only

The bot tails the file by maintaining a byte offset in `players.log.pos`. Do not rotate, truncate, or rewrite past lines while the bot is running. If you need rotation, stop the bot, rotate, delete `players.log.pos`, restart the bot. (Restarting causes the bot to re-emit Discord embeds for all rows past the new bookmark — set the bookmark to file-end if you want a clean restart without spam.)

## Migrating between schema versions

The project promises **backward compatibility for at least one minor version**. If `v2` is introduced:

- `v1` rows will continue to parse correctly for the entire `v2` release cycle.
- Adapters can keep emitting `v1` for that cycle.
- The bot's parser will accept both `v1` and `v2` rows simultaneously.

When `v3` is introduced, `v1` support may be dropped (with a deprecation notice in `CHANGELOG.md` at least one release ahead). Adapters should upgrade to `v2` before that deprecation window closes.

Forward-incompatible changes that **would** trigger a version bump:
- Adding a required column
- Changing the semantics of an existing `action` value
- Changing the meaning of `extra` for an existing action
- Changing the row separator or quoting rules

Forward-compatible changes that **do not** trigger a version bump:
- Adding a new `action` value (parsers that don't recognise it should `continue`)
- Adding optional keys to `extra` payloads (e.g. `lvl=3|cmd=/lo3|country=US`)
- New trailing columns past `schema_version` — but ordered after `schema_version` so older parsers can still find it

## Where the bot reads from

Default path: `/opt/halo-monitor/players.log` (carried over from the original Halo CE deployment). Override via the `PLAYER_LOG` environment variable in `observability/.env` for any other game.

The bookmark file lives next to the log file with a `.pos` suffix: `players.log.pos`.

## Minimal adapter skeleton

Pseudocode for any game with `onJoin` / `onLeave` / `onCommand` hooks:

```
SCHEMA_VERSION = "v1"
LOG_PATH       = "/opt/halo-monitor/players.log"
SERVER_NAME    = "My Server"

def write(action, name="", ip="", hash="", extra=""):
    ts    = utc_now_iso_z()
    name  = csv_safe(name)
    extra = csv_safe(extra)
    with open(LOG_PATH, "a") as f:
        f.write(f"{ts},{SERVER_NAME},{action},{name},{ip},{hash},{extra},{SCHEMA_VERSION}\n")

def on_load():
    write("startup")
    write("state", extra=f"maxplayers={read_max_from_config()}")
    schedule_periodic(60_seconds,
        lambda: write("state", extra=f"maxplayers={read_max()}"))

def on_join(player):    write("join",    player.name, player.ip, player.hash)
def on_leave(player):   write("leave",   player.name, player.ip, player.hash)
def on_command(player, cmd):
    write("command", player.name, player.ip, player.hash,
          extra=f"lvl={player.admin_level}|cmd={cmd}")
```

That's the whole contract.
