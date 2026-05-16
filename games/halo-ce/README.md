# Halo CE adapter (reference implementation)

SAPP Lua scripts that write join / leave / command / state events to the bot's CSV. Used as the reference for the [game-agnostic adapter contract](../README.md).

## Background

In many SAPP-under-Wine builds, the built-in `http_client()` function is stubbed and silently does nothing — so we can't POST to Discord directly from Lua. The Lua side just appends to `/opt/halo-monitor/players.log`, and the Python bot tails that file and does the actual Discord delivery.

This file-based design has a nice side effect: it's reused as the integration boundary for every other game.

## Scripts

| File | Purpose |
|---|---|
| `discord_notify.lua` | Required. Hooks `EVENT_JOIN` / `EVENT_LEAVE` / `EVENT_COMMAND`, writes CSV. Also emits a periodic `state` row with current `sv_maxplayers`. |
| `discord_welcome.lua` | Optional. Sends a private chat message to every joining player. |

## Install

For each Halo server instance:

1. Drop `discord_notify.lua` into the instance's SAPP lua directory (typically `cg/sapp/lua/`).
2. Edit the top of the file:
   ```lua
   local SERVER_NAME = "Server 1"   -- must match HALO_SERVERS in your bot env
   ```
3. Append to that instance's `cg/sapp/init.txt`:
   ```
   lua_load discord_notify
   ```
4. Restart the Halo server (or hot-load via rcon: `lua_load discord_notify`).

You should immediately see a new `state` row in `players.log`:
```
2026-05-15T19:46:31Z,Server 1,startup,,,,
2026-05-15T19:46:31Z,Server 1,state,,,,maxplayers=16
```

If you don't see those lines appear, the Lua isn't writing — check that the Halo process has write access to `/opt/halo-monitor/`.

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
- The bot configured to read `players.log` at the path the Lua writes to (default `/opt/halo-monitor/players.log`).
