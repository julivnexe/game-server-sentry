#!/usr/bin/env python3
"""discord_stats_bot.py — Slash-command interface to the Halo CE stats files.

Runs as a gateway bot (no inbound port needed). Reads the same files
stats_ingest.py writes, so the source-of-truth is unchanged: events.log
→ in-memory aggregation → leaderboard.txt / cappers.txt / player/<ip>.txt.

Slash commands registered:
  /top              Top 5 by KDA
  /fragger          Alias for /top
  /capper           Top 5 by flag captures
  /stats <player>   Lookup K/D/A/C/KDA by Halo player name
  /rank <player>    Lookup rank by Halo player name

Reads DISCORD_BOT_TOKEN from environment. Commands are guild-scoped at
startup (instant availability) by iterating bot.guilds — no need to
hand-configure a guild ID.
"""

import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import discord
from discord import app_commands

TOKEN          = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
ADMIN_ROLE_ID  = int(os.environ.get("ADMIN_ROLE_ID")    or 0)
STATUS_CHAN_ID = int(os.environ.get("STATUS_CHANNEL_ID") or 0)
MATCH_CHAN_ID  = int(os.environ.get("MATCH_CHANNEL_ID")  or 0)
ALERT_CHAN_ID  = int(os.environ.get("ALERTS_CHANNEL_ID") or 0)

STATS_DIR      = Path("/opt/halo-monitor/stats")
LEADERBOARD    = STATS_DIR / "leaderboard.txt"
FRAGGERS       = STATS_DIR / "fraggers.txt"
CAPPERS        = STATS_DIR / "cappers.txt"
PLAYER_DIR     = STATS_DIR / "player"
STATUS_DIR     = Path("/opt/halo-monitor")
STATUS_GLOB    = "server_status_*.json"  # per-port files written by halo_extras.lua
MATCH_LOG      = Path("/opt/halo-monitor/match_summaries.log")
MATCH_POS_FILE = Path("/opt/halo-monitor/match_summaries.log.pos")
STATUS_MSG_ID  = Path("/opt/halo-monitor/status_msg_id")
BANLIST_SEEN   = Path("/opt/halo-monitor/banlist_seen.txt")
CMD_QUEUE      = Path("/opt/halo-monitor/sapp_command_queue.txt")
TOP_N          = 5
STATUS_REFRESH = 60     # seconds between live status edits
MATCH_POLL     = 5
BANLIST_POLL   = 30

if not TOKEN:
    print("ERR: DISCORD_BOT_TOKEN env var is empty", file=sys.stderr)
    sys.exit(2)


# --------------------------------------------------------------------
# File parsing
# --------------------------------------------------------------------
def parse_pipe_line(line: str) -> dict:
    """rank=1|name=Bob|kills=10|..."""
    out = {}
    for kv in line.strip().split("|"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            out[k] = v
    return out


def parse_kv_file(path: Path) -> dict | None:
    """ip=1.2.3.4 / kills=10 / ... one key=value per line."""
    try:
        out = {}
        with open(path, encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    out[k] = v
        return out or None
    except FileNotFoundError:
        return None


def read_board(path: Path, top_n: int = TOP_N) -> list[dict]:
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                d = parse_pipe_line(line)
                if "rank" in d:
                    rows.append(d)
                    if len(rows) >= top_n:
                        break
    except FileNotFoundError:
        pass
    return rows


def find_player(name: str) -> dict | None:
    """Case-insensitive name lookup across per-IP files. Returns the
    closest match — exact first, then substring."""
    name_l = name.lower().strip()
    substring_match = None
    for p in PLAYER_DIR.glob("*.txt"):
        d = parse_kv_file(p)
        if not d:
            continue
        n = d.get("name", "").lower()
        if n == name_l:
            return d
        if substring_match is None and name_l in n:
            substring_match = d
    return substring_match


# --------------------------------------------------------------------
# Bot
# --------------------------------------------------------------------
intents = discord.Intents.default()
client = discord.Client(intents=intents)
tree   = app_commands.CommandTree(client)


def board_embed(title: str, rows: list[dict], color: int,
                metric_field: str, metric_label: str) -> discord.Embed:
    e = discord.Embed(title=title, color=color)
    for r in rows:
        e.add_field(
            name=f"#{r['rank']}  {r.get('name', '?')}",
            value=(
                f"**{metric_label}** {r.get(metric_field, '0')}  •  "
                f"K{r.get('kills', '0')} / D{r.get('deaths', '0')} / "
                f"A{r.get('assists', '0')} / C{r.get('captures', '0')}"
            ),
            inline=False,
        )
    e.set_footer(text="Halo CE Command Center")
    return e


async def send_kda_board(interaction: discord.Interaction):
    rows = read_board(LEADERBOARD)
    if not rows:
        await interaction.response.send_message(
            "Leaderboard not ready yet — wait ~30 seconds after the ingest "
            "starts, or play a few rounds first.",
            ephemeral=True)
        return
    await interaction.response.send_message(
        embed=board_embed("🎯  Top Fraggers (by KDA)", rows, 0x00bfff,
                          "kda", "KDA"))


@tree.command(name="top", description="Top 5 players by KDA")
async def top_cmd(interaction: discord.Interaction):
    await send_kda_board(interaction)


@tree.command(name="fragger", description="Top 5 players by raw kill count")
async def fragger_cmd(interaction: discord.Interaction):
    rows = read_board(FRAGGERS)
    if not rows:
        await interaction.response.send_message(
            "Fragger board not ready yet.", ephemeral=True)
        return
    await interaction.response.send_message(
        embed=board_embed("💀  Top Fraggers (by raw kills)", rows, 0xff3344,
                          "kills", "Kills"))


@tree.command(name="capper", description="Top 5 players by flag captures")
async def capper_cmd(interaction: discord.Interaction):
    rows = read_board(CAPPERS)
    if not rows:
        await interaction.response.send_message(
            "Capper board not ready yet.", ephemeral=True)
        return
    await interaction.response.send_message(
        embed=board_embed("🚩  Top Cappers (by captures)", rows, 0x33dd33,
                          "captures", "Caps"))


@tree.command(name="stats", description="Lookup K/D/A/Captures by Halo player name")
@app_commands.describe(player="Halo player name (case-insensitive)")
async def stats_cmd(interaction: discord.Interaction, player: str):
    d = find_player(player)
    if not d:
        await interaction.response.send_message(
            f"No stats found for `{player}`. Per-player files only exist "
            f"for IPs that have been online during this ingest run.",
            ephemeral=True)
        return
    e = discord.Embed(title=f"Stats: {d['name']}", color=0xff8800)
    e.add_field(name="Kills",    value=d.get("kills",    "0"))
    e.add_field(name="Deaths",   value=d.get("deaths",   "0"))
    e.add_field(name="Assists",  value=d.get("assists",  "0"))
    e.add_field(name="Captures", value=d.get("captures", "0"))
    e.add_field(name="KDA",      value=d.get("kda",      "0.0"))
    e.add_field(name="Rank",     value=f"{d.get('rank', '?')} / {d.get('total', '?')}")
    e.set_footer(text="Halo CE Command Center")
    await interaction.response.send_message(embed=e)


@tree.command(name="rank", description="Show a player's rank by Halo name")
@app_commands.describe(player="Halo player name (case-insensitive)")
async def rank_cmd(interaction: discord.Interaction, player: str):
    d = find_player(player)
    if not d:
        await interaction.response.send_message(
            f"No rank found for `{player}`.", ephemeral=True)
        return
    await interaction.response.send_message(
        f"**{d['name']}** — rank **{d.get('rank', '?')}** / "
        f"{d.get('total', '?')}  (KDA {d.get('kda', '0.0')})"
    )


@tree.command(name="commands", description="List all stat commands available in this server")
async def commands_cmd(interaction: discord.Interaction):
    e = discord.Embed(title="Halo CE Command Center — Slash Commands",
                      color=0x5865F2)
    e.add_field(name="/top",
                value="Top 5 players by KDA",
                inline=False)
    e.add_field(name="/fragger",
                value="Top 5 players by raw kill count",
                inline=False)
    e.add_field(name="/capper",
                value="Top 5 players by flag captures",
                inline=False)
    e.add_field(name="/stats <player>",
                value="Lookup K/D/A/Captures/KDA by Halo player name (case-insensitive)",
                inline=False)
    e.add_field(name="/rank <player>",
                value="Lookup a player's rank by Halo player name",
                inline=False)
    e.add_field(name="/commands",
                value="This list",
                inline=False)
    e.set_footer(text="Stats come from the live SAPP events log on the VPS. "
                       "KDA = (kills + assists) / max(1, deaths).")
    await interaction.response.send_message(embed=e, ephemeral=True)


####################################################################
# Admin slash commands (write to SAPP command queue)
####################################################################
def _admin_only(interaction: discord.Interaction) -> bool:
    if ADMIN_ROLE_ID == 0:
        return False
    return any(r.id == ADMIN_ROLE_ID for r in (interaction.user.roles or []))


def _enqueue_sapp(cmd: str):
    CMD_QUEUE.parent.mkdir(parents=True, exist_ok=True)
    with open(CMD_QUEUE, "a", encoding="utf-8") as f:
        f.write(cmd + "\n")


@tree.command(name="ban", description="ADMIN: Ban a player by name (IP+CD-key, persistent)")
@app_commands.describe(player="In-game player name (case-sensitive)")
async def ban_cmd(interaction: discord.Interaction, player: str):
    if not _admin_only(interaction):
        await interaction.response.send_message("Admin role required.", ephemeral=True)
        return
    _enqueue_sapp(f"sv_ban \"{player}\" 1d \"banned via Discord by {interaction.user}\"")
    await interaction.response.send_message(
        f"Queued: ban **{player}** (executes within 1s)", ephemeral=True)


@tree.command(name="kick", description="ADMIN: Kick a player by name")
@app_commands.describe(player="In-game player name")
async def kick_cmd(interaction: discord.Interaction, player: str):
    if not _admin_only(interaction):
        await interaction.response.send_message("Admin role required.", ephemeral=True)
        return
    _enqueue_sapp(f"sv_kick \"{player}\"")
    await interaction.response.send_message(f"Queued: kick **{player}**", ephemeral=True)


@tree.command(name="unban", description="ADMIN: Unban an IP from SAPP banlist")
@app_commands.describe(ip="IP address to unban")
async def unban_cmd(interaction: discord.Interaction, ip: str):
    if not _admin_only(interaction):
        await interaction.response.send_message("Admin role required.", ephemeral=True)
        return
    _enqueue_sapp(f"sv_unban {ip}")
    await interaction.response.send_message(f"Queued: unban **{ip}**", ephemeral=True)


@tree.command(name="map", description="ADMIN: Switch to a different map")
@app_commands.describe(name="map filename (e.g. bloodgulch)", gametype="gametype (e.g. slayer)")
async def map_cmd(interaction: discord.Interaction, name: str, gametype: str = "slayer"):
    if not _admin_only(interaction):
        await interaction.response.send_message("Admin role required.", ephemeral=True)
        return
    _enqueue_sapp(f"sv_map {name} {gametype}")
    await interaction.response.send_message(
        f"Queued: load **{name}** as **{gametype}**", ephemeral=True)


@tree.command(name="restart", description="ADMIN: Reset the current match")
async def restart_cmd(interaction: discord.Interaction):
    if not _admin_only(interaction):
        await interaction.response.send_message("Admin role required.", ephemeral=True)
        return
    _enqueue_sapp("sv_map_reset")
    await interaction.response.send_message("Queued: restart match", ephemeral=True)


####################################################################
# Background task 1: live server status (auto-edit pinned message)
# If STATUS_CHAN_ID is 0, dry-run mode: prints to journal instead of sending.
####################################################################
async def live_status_loop():
    await client.wait_until_ready()
    channel = client.get_channel(STATUS_CHAN_ID) if STATUS_CHAN_ID else None
    dry_run = channel is None
    if dry_run:
        print(f"[live_status] DRY-RUN mode (STATUS_CHANNEL_ID={STATUS_CHAN_ID}) — printing to journal", flush=True)

    msg = None
    if not dry_run:
        if STATUS_MSG_ID.exists():
            try:
                msg = await channel.fetch_message(int(STATUS_MSG_ID.read_text().strip()))
            except Exception:
                msg = None
        if msg is None:
            msg = await channel.send(embed=discord.Embed(title="Halo CE — live status",
                                                         description="initializing…",
                                                         color=0x4f9ce8))
            STATUS_MSG_ID.parent.mkdir(parents=True, exist_ok=True)
            STATUS_MSG_ID.write_text(str(msg.id))
            try:
                await msg.pin(reason="Halo CE live status")
            except Exception:
                pass

    while not client.is_closed():
        try:
            status_files = sorted(STATUS_DIR.glob(STATUS_GLOB))
            if status_files:
                servers = []
                total_count = 0
                for f in status_files:
                    try:
                        servers.append(json.loads(f.read_text()))
                        total_count += servers[-1].get("count", 0)
                    except Exception:
                        continue
                color = 0x33dd33 if total_count > 0 else 0x666666
                e = discord.Embed(
                    title=f"Halo CE — live status ({total_count} players online)",
                    color=color)
                for data in servers:
                    count = data.get("count", 0)
                    max_p = data.get("max", 16)
                    players = data.get("players", [])
                    lines = ([f"**{p['name']}** — K {p.get('kills',0)} / D {p.get('deaths',0)}"
                              for p in players] or ["*nobody online*"])
                    e.add_field(
                        name=f"{data.get('server','Server')} — {count}/{max_p} on {data.get('map','?')} / {data.get('gt','?')}",
                        value="\n".join(lines),
                        inline=False)
                if servers:
                    e.set_footer(text=f"Updated {servers[-1].get('ts','?')}")
                if dry_run:
                    summary = " | ".join(
                        f"{d.get('server','?')} {d.get('count',0)}/{d.get('max',16)} on {d.get('map','?')}"
                        for d in servers)
                    print(f"[live_status] would-update: {summary}", flush=True)
                else:
                    await msg.edit(embed=e)
        except Exception as exc:
            print(f"[live_status] error: {exc}", file=sys.stderr)
        await asyncio.sleep(STATUS_REFRESH)


####################################################################
# Background task 2: match-end summary poster
# If MATCH_CHAN_ID is 0, dry-run: prints summary line to journal.
####################################################################
async def match_summary_loop():
    await client.wait_until_ready()
    channel = client.get_channel(MATCH_CHAN_ID) if MATCH_CHAN_ID else None
    dry_run = channel is None
    if dry_run:
        print(f"[match_summary] DRY-RUN mode (MATCH_CHANNEL_ID={MATCH_CHAN_ID}) — printing to journal", flush=True)

    pos = int(MATCH_POS_FILE.read_text().strip()) if MATCH_POS_FILE.exists() else 0

    while not client.is_closed():
        try:
            if MATCH_LOG.exists():
                with open(MATCH_LOG, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(pos)
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            d = json.loads(line)
                        except Exception:
                            continue
                        if dry_run:
                            print(f"[match_summary] MATCH END {d.get('server','?')} "
                                  f"map={d.get('map','?')} gt={d.get('gt','?')} "
                                  f"mvp={d.get('mvp','?')}({d.get('mvp_score',0)}) "
                                  f"top_fragger={d.get('top_fragger','?')}({d.get('top_fragger_kills',0)}) "
                                  f"longest_streak={d.get('longest_streak_name','?')}({d.get('longest_streak',0)}) "
                                  f"top_caps={d.get('top_caps',0)}", flush=True)
                        else:
                            e = discord.Embed(
                                title=f"🏁  Match ended — {d.get('map','?')} ({d.get('gt','?')})",
                                color=0xffa500)
                            e.add_field(name="MVP",
                                        value=f"**{d.get('mvp','?')}** (score {d.get('mvp_score',0)})",
                                        inline=False)
                            e.add_field(name="Top fragger",
                                        value=f"{d.get('top_fragger','?')} — {d.get('top_fragger_kills',0)} kills",
                                        inline=True)
                            e.add_field(name="Longest streak",
                                        value=f"{d.get('longest_streak_name','?')} — {d.get('longest_streak',0)}",
                                        inline=True)
                            caps = d.get("top_caps", 0)
                            if caps > 0:
                                e.add_field(name="Top capper",
                                            value=f"{d.get('top_capper','?')} — {caps} caps",
                                            inline=True)
                            e.set_footer(text=f"{d.get('server','?')} • {d.get('ts','?')}")
                            await channel.send(embed=e)
                    pos = f.tell()
                MATCH_POS_FILE.write_text(str(pos))
        except Exception as exc:
            print(f"[match_summary] error: {exc}", file=sys.stderr)
        await asyncio.sleep(MATCH_POLL)


####################################################################
# Background task 3: DDoS auto-report (new halo-banlist entries)
# If ALERT_CHAN_ID is 0, dry-run: prints each new ban to journal.
####################################################################
async def ddos_alert_loop():
    await client.wait_until_ready()
    channel = client.get_channel(ALERT_CHAN_ID) if ALERT_CHAN_ID else None
    dry_run = channel is None
    if dry_run:
        print(f"[ddos_alert] DRY-RUN mode (ALERTS_CHANNEL_ID={ALERT_CHAN_ID}) — printing to journal", flush=True)

    def current_banlist():
        try:
            out = subprocess.check_output(
                ["sudo", "ipset", "list", "halo-banlist"],
                text=True, stderr=subprocess.DEVNULL, timeout=5)
            seen_members = False
            ips = set()
            for line in out.splitlines():
                if seen_members:
                    parts = line.split()
                    if parts:
                        ips.add(parts[0])
                if line.startswith("Members:"):
                    seen_members = True
            return ips
        except Exception:
            return set()

    seen = set()
    if BANLIST_SEEN.exists():
        seen = set(BANLIST_SEEN.read_text().split())
    while not client.is_closed():
        try:
            now = current_banlist()
            new = now - seen
            for ip in sorted(new):
                if dry_run:
                    print(f"[ddos_alert] AUTO-BANNED {ip}", flush=True)
                else:
                    e = discord.Embed(
                        title="🛡  Auto-banned",
                        description=f"`{ip}` added to halo-banlist",
                        color=0xff3344)
                    e.set_footer(text="halo-banlist • DDoS auto-mitigation")
                    await channel.send(embed=e)
            if now != seen:
                BANLIST_SEEN.write_text("\n".join(sorted(now)))
                seen = now
        except Exception as exc:
            print(f"[ddos_alert] error: {exc}", file=sys.stderr)
        await asyncio.sleep(BANLIST_POLL)


@client.event
async def on_ready():
    print(f"Logged in as {client.user} ({client.user.id})", flush=True)
    total = 0
    for guild in client.guilds:
        try:
            tree.copy_global_to(guild=guild)
            synced = await tree.sync(guild=guild)
            print(f"  synced {len(synced)} commands to '{guild.name}' ({guild.id})", flush=True)
            total += len(synced)
        except Exception as exc:
            print(f"  sync failed for '{guild.name}': {exc}", file=sys.stderr)
    print(f"Total commands live: {total}", flush=True)

    # Launch the three background tasks
    asyncio.create_task(live_status_loop())
    asyncio.create_task(match_summary_loop())
    asyncio.create_task(ddos_alert_loop())


if __name__ == "__main__":
    client.run(TOKEN, log_handler=None)
