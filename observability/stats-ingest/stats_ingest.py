#!/usr/bin/env python3
"""stats_ingest.py — Halo CE Command Center per-IP K/D/A/captures aggregator.

Tails /opt/halo-monitor/events.log (written by sapp/stats_tracker.lua),
maintains an in-memory dict keyed by player IP, and regenerates the
text files that stats_tracker.lua reads to answer /stats, /top,
/fragger, /capper, /rank chat commands.

Source-of-truth is the events.log file. On startup the entire log is
replayed to rebuild state — no separate DB.

Output files (paths the Lua script expects):
  /opt/halo-monitor/stats/leaderboard.txt   — top N by KDA, pipe-sep
  /opt/halo-monitor/stats/cappers.txt       — top N by captures, pipe-sep
  /opt/halo-monitor/stats/player/<ip>.txt   — per-IP stats (key=value lines)

VPN filtering via ProxyCheck.io is a TODO — for the first scrim we ship
without it. The events.log still records every event including VPN
players; only the public leaderboard math would exclude them.
"""

import os
import sys
import time
import signal
from pathlib import Path

EVENTS_LOG       = Path("/opt/halo-monitor/events.log")
STATS_DIR        = Path("/opt/halo-monitor/stats")
LEADERBOARD_PATH = STATS_DIR / "leaderboard.txt"   # sorted by KDA
FRAGGERS_PATH    = STATS_DIR / "fraggers.txt"      # sorted by raw kills
CAPPERS_PATH     = STATS_DIR / "cappers.txt"       # sorted by flag captures
PLAYER_DIR       = STATS_DIR / "player"
REGEN_EVERY_SEC  = 30
TOP_N            = 50

# stats[ip] = {"name": str, "kills": int, "deaths": int, "assists": int, "captures": int}
stats = {}
online = set()      # IPs currently in-server (driven by JOIN/LEAVE rows)
running = True


def kda(s):
    return (s["kills"] + s["assists"]) / max(1, s["deaths"])


def ensure_entry(ip, name):
    if not ip:
        return None
    if ip not in stats:
        stats[ip] = {
            "name": name or "?",
            "kills": 0, "deaths": 0, "assists": 0, "captures": 0,
        }
    if name:
        stats[ip]["name"] = name
    return stats[ip]


def update_for_event(row):
    """row = [ts, server, event, actor_ip, actor_name, target_ip, target_name, extra, schema]"""
    if len(row) < 8:
        return
    event = row[2]
    actor_ip, actor_name = row[3], row[4]
    target_ip, target_name = row[5], row[6]

    if event == "KILL":
        a = ensure_entry(actor_ip, actor_name)
        if a:
            a["kills"] += 1
        t = ensure_entry(target_ip, target_name)
        if t:
            t["deaths"] += 1
    elif event == "SUICIDE":
        a = ensure_entry(actor_ip, actor_name)
        if a:
            a["deaths"] += 1
    elif event == "ASSIST":
        a = ensure_entry(actor_ip, actor_name)
        if a:
            a["assists"] += 1
    elif event == "FLAG_CAP":
        a = ensure_entry(actor_ip, actor_name)
        if a:
            a["captures"] += 1
    elif event == "JOIN":
        ensure_entry(actor_ip, actor_name)
        if actor_ip:
            online.add(actor_ip)
    elif event == "LEAVE":
        if actor_ip:
            online.discard(actor_ip)


def safe_field(s):
    """Strip newlines and pipes from output values so the line format
    stays parseable by the Lua reader."""
    return (s or "").replace("|", " ").replace("\n", " ").replace("\r", "")


def regenerate():
    STATS_DIR.mkdir(parents=True, exist_ok=True)
    PLAYER_DIR.mkdir(parents=True, exist_ok=True)

    by_kda    = sorted(stats.items(),
                       key=lambda kv: (-kda(kv[1]), -kv[1]["kills"]))
    by_kills  = sorted(stats.items(),
                       key=lambda kv: (-kv[1]["kills"], -kda(kv[1])))
    by_cap    = sorted(stats.items(),
                       key=lambda kv: (-kv[1]["captures"], -kda(kv[1])))

    total = len(stats)

    def write_board(path, rows):
        tmp = path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            for rank, (_ip, s) in enumerate(rows[:TOP_N], start=1):
                f.write(
                    f"rank={rank}|name={safe_field(s['name'])}"
                    f"|kills={s['kills']}|deaths={s['deaths']}"
                    f"|assists={s['assists']}|captures={s['captures']}"
                    f"|kda={kda(s):.1f}\n"
                )
        tmp.replace(path)

    write_board(LEADERBOARD_PATH, by_kda)
    write_board(FRAGGERS_PATH,    by_kills)
    write_board(CAPPERS_PATH,     by_cap)

    kda_rank = {ip: i + 1 for i, (ip, _s) in enumerate(by_kda)}

    # Per-IP files. Only write for IPs we've seen recently (online or in stats).
    # Writing every IP every cycle would be wasteful as the player count grows.
    for ip in online:
        s = stats.get(ip)
        if not s:
            continue
        out = PLAYER_DIR / f"{ip}.txt"
        tmp = out.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(f"ip={ip}\n")
            f.write(f"name={safe_field(s['name'])}\n")
            f.write(f"kills={s['kills']}\n")
            f.write(f"deaths={s['deaths']}\n")
            f.write(f"assists={s['assists']}\n")
            f.write(f"captures={s['captures']}\n")
            f.write(f"kda={kda(s):.1f}\n")
            f.write(f"rank={kda_rank.get(ip, total)}\n")
            f.write(f"total={total}\n")
        tmp.replace(out)


def replay_all():
    """Read the full events.log to rebuild state. Returns the byte offset
    we ended at so the tail loop can continue from there."""
    if not EVENTS_LOG.exists():
        return 0
    with open(EVENTS_LOG, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n").rstrip("\r")
            if not line:
                continue
            row = line.split(",")
            update_for_event(row)
        return f.tell()


def tail(start_offset):
    pos = start_offset
    last_regen = 0
    while running:
        try:
            with open(EVENTS_LOG, "r", encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                for line in f:
                    line = line.rstrip("\n").rstrip("\r")
                    if not line:
                        continue
                    update_for_event(line.split(","))
                pos = f.tell()
        except FileNotFoundError:
            pass
        except Exception as e:
            print(f"tail loop error: {e}", file=sys.stderr)

        now = time.time()
        if now - last_regen >= REGEN_EVERY_SEC:
            try:
                regenerate()
                last_regen = now
            except Exception as e:
                print(f"regen failed: {e}", file=sys.stderr)
        time.sleep(1)


def handle_signal(_signum, _frame):
    global running
    running = False


def main():
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    print("stats_ingest: replaying events.log…", flush=True)
    pos = replay_all()
    print(f"stats_ingest: replay done, pos={pos}, players={len(stats)}, online={len(online)}", flush=True)
    try:
        regenerate()
        print(f"stats_ingest: wrote initial leaderboard ({len(stats)} players)", flush=True)
    except Exception as e:
        print(f"initial regen failed: {e}", file=sys.stderr)
    tail(pos)


if __name__ == "__main__":
    main()
