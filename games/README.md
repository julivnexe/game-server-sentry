# Game adapters

The bot is game-agnostic. The integration contract is a single CSV file ([`docs/CSV_FORMAT.md`](../docs/CSV_FORMAT.md)). A "game adapter" is anything that emits that CSV: a server-side plugin, a log scraper, an RCON poller, a sidecar process, a userspace wrapper.

## Available adapters

| Game | Status | Notes |
|---|---|---|
| **Halo CE** | ✅ Reference impl | SAPP Lua scripts. See [`halo-ce/`](halo-ce/). |
| Minecraft (Spigot/Paper) | 🚧 Sketch | Java plugin reading `PlayerJoinEvent` / `PlayerCommandPreprocessEvent`. |
| Source engine (CS:GO/CS2, TF2, L4D2) | 🚧 Sketch | SourceMod plugin hooking `client_connect` / `client_disconnect` / `say` events. |
| Garry's Mod | 🚧 Sketch | Lua hooks `PlayerInitialSpawn` / `PlayerDisconnected` / `PlayerSay`. |
| Rust | 🚧 Sketch | Oxide/uMod plugin. |
| Generic log-scraper | 🚧 Sketch | `tail -F server.log \| your_parser.py` for games without plugin APIs. |

Want one of the sketches implemented? Open an issue, or PR it directly using the Halo CE adapter as a template.

## Writing a new adapter — quick recipe

1. Find your game's hooks for: **player join**, **player leave**, **player chat/command**, **server start**, **max-players changed**.
2. In each hook, append a CSV row to `/opt/halo-monitor/players.log` (or wherever your bot is configured to read from).
3. Test by tailing the file (`tail -F players.log`) while you join your own server.
4. Run the bot pointed at that file.

## Common adapter patterns

### Plugin-with-direct-write (preferred when available)

Your game's plugin API can read events directly and append to the CSV. This is what the Halo CE Lua adapter does. Cleanest, lowest latency.

### Log-scraper sidecar

Many game servers emit structured log lines for joins/leaves (`[INFO] PlayerX[1.2.3.4] joined`). A small Python/Go process tails the log, parses, writes the CSV. Works without a plugin API but is fragile when log formats change.

### RCON poller

For games with RCON but no event hooks, poll `status` every 5–10 seconds, diff the player list against the previous poll, emit join/leave rows for the delta. Loses chat/command events but works as a baseline.

### Gamespy / `\status\` query

Many older games (Quake, UT, Halo, Soldier of Fortune, etc) respond to a UDP `\status\` query packet with a key/value-formatted player list. Same diff approach as RCON.

## Server-name discipline

The `server_name` field in your CSV rows **must exactly match** the display name in your bot config (`HALO_SERVERS=2312:My Scrim Server:4` → server_name must be `My Scrim Server`). Otherwise embeds will show the right player but no rules-of-engagement metadata (player count, connect string).

## CSV escaping

The CSV is comma-separated with no quoting. Strip or replace commas in player names and command text before writing. The Halo CE Lua adapter uses `:gsub(",", " ")` — copy that pattern.

## Submitting an adapter

PRs welcome. To add a new game:

1. Create `games/<game-id>/` with at least:
   - `README.md` (install + config)
   - The adapter source (plugin, script, whatever)
2. Update the table at the top of this file.
3. Update the top-level [`README.md`](../README.md) if your game has a wide audience.
