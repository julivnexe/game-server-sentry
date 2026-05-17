# SAPP Lua scripts

The Lua scripts that run inside the Halo CE dedicated server. They hook SAPP event callbacks and append rows to disk; the Python bot tails those files and does everything downstream (Discord posts, Prometheus metrics, SQLite stats).

## Background

In many SAPP-under-Wine builds, the built-in `http_client()` function is stubbed and silently does nothing — so we can't POST to Discord directly from Lua. The Lua side just appends to log files in `/opt/halo-monitor/`, and the Python bot reads from those files.

## Scripts

| File | Purpose |
|---|---|
| `discord_notify.lua` | Required. Hooks `EVENT_JOIN` / `EVENT_LEAVE` / `EVENT_COMMAND`, writes to `players.log`. Also emits a periodic `state` row with current `sv_maxplayers`. |
| `stats_tracker.lua`   | Optional. Per-IP K/D/A/captures. Hooks `EVENT_DIE` / `EVENT_DAMAGE_APPLICATION` / `EVENT_SCORE`, writes to `events.log`. Exposes `/stats`, `/top`, `/fragger`, `/capper`, `/rank` chat commands. VPN-flagged IPs are logged but excluded from the leaderboard (filtering is Python-side via ProxyCheck.io). |

## Install

For each Halo server instance:

1. Drop the `.lua` files into the instance's SAPP lua directory (typically `cg/sapp/lua/`).
2. Edit `SERVER_NAME` at the top of each script to identify this instance:
   ```lua
   local SERVER_NAME = "Server 1"   -- must match HALO_SERVERS in your bot env
   ```
3. Append to that instance's `cg/sapp/init.txt`:
   ```
   lua_load discord_notify
   lua_load stats_tracker
   ```
4. Restart the Halo server (or hot-load via rcon: `lua_load <name>`).

You should immediately see new rows in `players.log`:
```
2026-05-15T19:46:31Z,Server 1,startup,,,,,v1
2026-05-15T19:46:31Z,Server 1,state,,,,maxplayers=16,v1
```

If you don't see those lines appear, the Lua isn't writing — check that the Halo process has write access to `/opt/halo-monitor/`.

## Stats tracker specifics

`stats_tracker.lua` reads back pre-baked text files written by the Python bot to answer chat commands without needing a SQLite driver inside SAPP Lua:

- `/opt/halo-monitor/stats/leaderboard.txt` — top players by KDA (one row per entry, pipe-separated `key=value` fields)
- `/opt/halo-monitor/stats/cappers.txt`     — top players by flag captures
- `/opt/halo-monitor/stats/player/<ip>.txt` — per-IP stats for the `/stats` and `/rank` commands

The Python bot regenerates these files every 30 seconds. The Lua side just reads and formats — it has no opinion on KDA math.

### Assists

SAPP doesn't have a native assist event. The script keeps a per-victim table of recent damagers (within a 6-second window, tunable via `ASSIST_WINDOW_SEC`) and credits an assist to anyone who damaged the victim but didn't land the killing blow. The window resets on death.

### Flag captures

Only credited when the gametype is CTF — checked via `get_var(0, "$gt")`. Other gametypes fire `EVENT_SCORE` too (Slayer = kill, KOTH = hill-time, Race = lap), and we don't want to double-count those.

## Notes on `state` heartbeat

`discord_notify.lua` reads `sv_maxplayers` from `cg/init.txt` (since SAPP doesn't expose it as a `get_var()` variable). It also hooks `EVENT_COMMAND` to detect `sv_maxplayers <n>` and the common `max <n>` alias for runtime changes — so the bot's "X/Y" count in Discord stays fresh even if you change the player cap mid-session.

If you edit `init.txt` directly while the server is running, the heartbeat picks up the new value within 60 seconds (the timer interval).

## `lo3` (live on 3)

There used to be a vote-based `lo3_vote.lua` here. It was removed because SAPP's `timer()` is unreliable under Wine and the 1-second-spaced map resets drifted to 14+ seconds in practice. The cleaner solution is a `commands.txt` alias:

```
lo3 'sv_map_reset;w8 5;sv_map_reset;w8 5;sv_map_reset' 3
```

The `w8 5` (wait 5 ticks ≈ 167 ms) between resets is necessary — back-to-back `sv_map_reset` calls collapse to a single event because the game engine processes them within the same tick. Admin level 3 required.

## Requirements

- SAPP 10.2.1 CE (or compatible).
- Halo CE dedicated server running under Wine on Linux (or natively on Windows).
- The bot configured to read `players.log` and `events.log` at the paths the Lua writes to (default `/opt/halo-monitor/`).
