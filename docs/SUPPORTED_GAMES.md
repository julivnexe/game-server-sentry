# Supported games — compatibility matrix

Any game that lets you run a dedicated server **and** exposes one of: a plugin API, RCON, parseable server logs, or a status query protocol. The bot only consumes a CSV file ([`CSV_FORMAT.md`](CSV_FORMAT.md)) — anything that can produce that file works.

**Legend:**
- ✅ = reference adapter shipped in this repo
- 🟢 = plugin API verified to exist; an adapter is a weekend project
- 🟡 = workable via log-scraping or RCON polling; more brittle

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

**Caveat:** This list is "could be made to work with sensible effort." Of these, only Halo CE has a shipping adapter in this repo today. The 🟢 entries are weekend projects (~50–100 lines each), the 🟡 ones are weekend-and-a-half because log/RCON parsing is finicky. PRs welcome — see [`../games/README.md`](../games/README.md).

**Games that won't work cleanly:** anything where you can't run your own dedicated server (Valorant, Fortnite, modern CoD, Apex, etc.), or where the server is a closed binary with no plugin API and no useful log output (some Korean/Chinese MMO clients).

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

See [`CSV_FORMAT.md`](CSV_FORMAT.md) for the full schema and [`../games/README.md`](../games/README.md) for adapter design notes and patterns for common engines.
