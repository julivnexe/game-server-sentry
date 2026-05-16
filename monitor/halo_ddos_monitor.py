#!/usr/bin/env python3
"""
halo_ddos_monitor.py

Multi-port DDoS monitor + Discord notifier for Halo CE dedicated servers
running SAPP under Wine on Linux.

Features:
  * Per-port PPS, bandwidth, and unique-source-IP flood detection
    (via iptables ACCEPT counter rules inserted at startup).
  * Posts alerts to a Discord webhook on threshold breaches.
  * Tails /opt/halo-monitor/players.log (written by discord_notify.lua) and
    posts join/leave embeds to Discord — this is the workaround for
    SAPP's http_client() being stubbed in many Wine builds.
  * VPN / proxy detection via proxycheck.io (no API key needed for 100
    lookups/day; set PROXYCHECK_KEY for 1000/day).
  * Returning-player detection by IP (immune to shared CD-key issues).
  * Map-change rejoin deduplication so the channel doesn't spam when SAPP
    re-fires EVENT_JOIN for everyone on a new map.
  * systemctl watchdog: posts a red alert if any watched halo-server unit
    drops out of `active`, and a green recovery alert when it returns.

Privacy:
  * Player IPs are looked up for country / VPN status, then shown in the
    embed alongside the country. (You can comment out the IP field if you
    want to keep the lookup but hide the IP from Discord — see post_join_leave.)
  * CD-key hashes are NEVER sent to Discord. They're only in players.log
    on disk, for the operator's own forensics.
  * For DDoS flood alerts, attacker IPs are filtered to exclude any IPs
    matching currently-connected players (avoids doxing a laggy player as
    an "attacker").

Configuration via environment variables (see halo-ddos-monitor.service):
  DISCORD_WEBHOOK         (required) Webhook URL.
  HALO_SERVERS            "port:Display Name,port:Display Name,..."
                          e.g. "2302:Public,2303:Scrims"
  PROXYCHECK_KEY          (optional) proxycheck.io API key.
  PLAYER_LOG              path to the CSV log (default /opt/halo-monitor/players.log)
  LOG_POS_FILE            tail bookmark (default /opt/halo-monitor/players.log.pos)
  WATCHED_SERVICES        comma-separated systemd units to watch
                          (default "halo-server")
  IFACE                   force a specific network interface
                          (default: autodetect via `ip route show default`)
  SAMPLE_INTERVAL / POLL_SEC and threshold knobs — see constants below.

Requires: python3-requests, iptables, ss, systemctl, iconv (for the lua side).
"""
import os
import time
import socket
import subprocess
from collections import defaultdict, deque
from datetime import datetime, timezone

import requests

# ============ CONFIG ============
WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK", "https://discord.com/api/webhooks/REPLACE_ME/REPLACE_ME")
# format: "port1:Name 1,port2:Name 2,..."
HALO_SERVERS_RAW = os.environ.get("HALO_SERVERS", "2302:Server 1")
IFACE = os.environ.get("IFACE", "")
PLAYER_LOG = os.environ.get("PLAYER_LOG", "/opt/halo-monitor/players.log")
LOG_POS_FILE = os.environ.get("LOG_POS_FILE", "/opt/halo-monitor/players.log.pos")
PROXYCHECK_KEY = os.environ.get("PROXYCHECK_KEY", "").strip()

# Detection thresholds (per server, per POLL_SEC window)
PPS_THRESHOLD = int(os.environ.get("PPS_THRESHOLD", "3000"))
BPS_THRESHOLD = int(os.environ.get("BPS_THRESHOLD", str(8 * 1024 * 1024)))  # 8 Mbps
UNIQUE_IPS_WINDOW_SEC = int(os.environ.get("UNIQUE_IPS_WINDOW_SEC", "10"))
UNIQUE_IPS_THRESHOLD = int(os.environ.get("UNIQUE_IPS_THRESHOLD", "40"))
ALERT_COOLDOWN_SEC = int(os.environ.get("ALERT_COOLDOWN_SEC", "60"))
POLL_SEC = int(os.environ.get("POLL_SEC", "2"))
# ================================

HOSTNAME = socket.gethostname()

# In-memory cache: ip -> {"country_label": ..., "org": ..., "vpn_type": ..., "is_suspicious": bool}
_ip_info_cache = {}

# In-memory set of currently-active player keys (server, name, hash).
# Used to suppress duplicate joins from map-change rejoins (SAPP fires
# EVENT_JOIN for every player on every map change).
_active_players = set()

# IPs we've ever seen join a server. Used to mark returning visitors.
# IP is more reliable than CD-key hash for Halo CE because many hashes
# are shared via leaked CD-keys.
_seen_ips = set()

# Systemd units to watch for liveness; alert on state transitions.
HALO_SERVICES = [s.strip() for s in os.environ.get(
    "WATCHED_SERVICES", "halo-server").split(",") if s.strip()]
_service_state = {}


def parse_servers(raw):
    """Parse "port:name[:max],port:name[:max],..." into
       {port: {"name": ..., "max": int}}. Max defaults to 16."""
    out = {}
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry or ":" not in entry:
            continue
        bits = entry.split(":")
        if len(bits) < 2:
            continue
        try:
            port = int(bits[0].strip())
        except ValueError:
            continue
        # Last segment is max if it parses as an int, else part of the name
        max_players = 16
        name_parts = bits[1:]
        if len(name_parts) >= 2:
            try:
                max_players = int(name_parts[-1].strip())
                name_parts = name_parts[:-1]
            except ValueError:
                pass
        name = ":".join(s.strip() for s in name_parts)
        out[port] = {"name": name, "max": max_players}
    return out


SERVERS = parse_servers(HALO_SERVERS_RAW)
SERVER_MAX = {info["name"]: info["max"] for info in SERVERS.values()}
SERVER_PORT = {info["name"]: port for port, info in SERVERS.items()}

# Live maxplayers per server, updated whenever the Lua side writes an
# action="state" row with extra="maxplayers=N". Falls back to SERVER_MAX
# (static env-derived value) for any server we haven't heard a heartbeat from.
_server_max = dict(SERVER_MAX)

# Optional per-server join password used to build the "connect" command.
# Format: "port:password,port:password,...". Leave empty entry for no password.
# Example: "SERVER_PASSWORDS=2312:your-password"
SERVER_PASSWORDS_RAW = os.environ.get("SERVER_PASSWORDS", "")
SERVER_PASSWORDS = {}
for entry in SERVER_PASSWORDS_RAW.split(","):
    entry = entry.strip()
    if not entry or ":" not in entry:
        continue
    p, pw = entry.split(":", 1)
    try:
        SERVER_PASSWORDS[int(p.strip())] = pw.strip()
    except ValueError:
        pass

# Public IP for building connect commands. Auto-detected on first use if unset.
PUBLIC_IP = os.environ.get("PUBLIC_IP", "").strip()

# Optional per-server IP override. Useful if you run servers across multiple
# VPSes / hostnames. Format: "port:ip,port:ip,..."
# If a port isn't listed here, the auto-detected PUBLIC_IP is used.
SERVER_IPS_RAW = os.environ.get("SERVER_IPS", "")
SERVER_IPS = {}
for entry in SERVER_IPS_RAW.split(","):
    entry = entry.strip()
    if not entry or ":" not in entry:
        continue
    p, ip = entry.split(":", 1)
    try:
        SERVER_IPS[int(p.strip())] = ip.strip()
    except ValueError:
        pass


def get_public_ip():
    global PUBLIC_IP
    if PUBLIC_IP:
        return PUBLIC_IP
    for url in ("https://icanhazip.com", "https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            r = requests.get(url, timeout=4)
            ip = (r.text or "").strip().split("\n")[0]
            if ip and ip.count(".") == 3:
                PUBLIC_IP = ip
                return PUBLIC_IP
        except Exception:
            continue
    return None


def detect_iface() -> str:
    if IFACE:
        return IFACE
    try:
        out = subprocess.check_output(["ip", "route", "show", "default"], text=True)
        parts = out.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    except Exception:
        pass
    return "eth0"


def post(payload):
    try:
        requests.post(WEBHOOK_URL, json=payload, timeout=5)
    except Exception as e:
        print(f"webhook error: {e}")


def post_alert(server_name, title, desc, color, fields=None):
    post({
        "username": "SoplonBOT",
        "embeds": [{
            "title": f"[{server_name}] {title}",
            "description": desc,
            "color": color,
            "fields": fields or [],
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }],
    })


def lookup_ip_info(ip_with_port):
    """proxycheck.io lookup, cached. Returns dict with country_label, org,
    vpn_type, is_suspicious. Free tier (no key) = 100 lookups/day."""
    empty = {"country_label": None, "org": None, "vpn_type": None, "is_suspicious": False}
    if not ip_with_port:
        return empty
    ip = ip_with_port.split(":", 1)[0]
    if not ip:
        return empty
    if ip in _ip_info_cache:
        return _ip_info_cache[ip]
    info = dict(empty)
    try:
        params = {"vpn": "1", "asn": "1", "risk": "1"}
        if PROXYCHECK_KEY:
            params["key"] = PROXYCHECK_KEY
        r = requests.get(f"https://proxycheck.io/v2/{ip}", params=params, timeout=4)
        data = r.json()
        if data.get("status") in ("ok", "warning"):
            entry = data.get(ip, {}) or {}
            cc = (entry.get("isocode") or "").upper()
            country = entry.get("country") or ""
            flag = "".join(
                chr(0x1F1E6 + ord(c) - ord("A")) for c in cc if "A" <= c <= "Z"
            )
            info["country_label"] = f"{flag} {country}".strip() if (flag or country) else None
            info["org"] = entry.get("provider") or entry.get("organisation") or entry.get("asn") or None
            if (entry.get("proxy") or "").lower() == "yes":
                info["is_suspicious"] = True
                info["vpn_type"] = entry.get("type") or "Proxy"
        else:
            print(f"proxycheck non-ok status for {ip}: {data}")
    except Exception as e:
        print(f"proxycheck lookup failed for {ip}: {e}")
    _ip_info_cache[ip] = info
    return info


def current_players_from_log(server_filter=None):
    if not os.path.exists(PLAYER_LOG):
        return [], set()
    active = {}
    try:
        with open(PLAYER_LOG, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split(",", 6)
                if len(parts) == 7:
                    ts, server, action, name, ip, hsh, _extra = parts
                elif len(parts) == 6:
                    ts, server, action, name, ip, hsh = parts
                elif len(parts) == 5:
                    ts, action, name, ip, hsh = parts
                    server = ""
                else:
                    continue
                if server_filter and server != server_filter:
                    continue
                if action == "startup":
                    # Server boot — drop any stale "active" entries for it
                    for k in list(active.keys()):
                        if k[0] == server:
                            del active[k]
                    continue
                if action not in ("join", "leave"):
                    continue
                key = (server, name, hsh)
                if action == "join":
                    active[key] = {"name": name, "ip": ip}
                elif action == "leave":
                    active.pop(key, None)
    except Exception as e:
        print(f"log read error: {e}")
    names = [p["name"] for p in active.values()]
    ips = {p["ip"] for p in active.values() if p["ip"]}
    return names, ips


def conntrack_unique_ips(port: int) -> set:
    ips = set()
    try:
        out = subprocess.check_output(["ss", "-uan"], text=True, timeout=3)
        for line in out.splitlines():
            if f":{port} " in line or line.endswith(f":{port}"):
                cols = line.split()
                if len(cols) >= 5:
                    peer = cols[4]
                    ip = peer.rsplit(":", 1)[0].strip("[]")
                    if ip and ip != "*":
                        ips.add(ip)
    except Exception:
        pass
    return ips


def ensure_iptables_counter(port: int):
    chain_check = subprocess.run(
        ["iptables", "-C", "INPUT", "-p", "udp", "--dport", str(port), "-j", "ACCEPT"],
        capture_output=True,
    )
    if chain_check.returncode != 0:
        subprocess.run(
            ["iptables", "-I", "INPUT", "1", "-p", "udp", "--dport", str(port), "-j", "ACCEPT"],
            check=False,
        )


def read_port_counter(port: int):
    try:
        out = subprocess.check_output(
            ["iptables", "-L", "INPUT", "-v", "-n", "-x"], text=True
        )
        for line in out.splitlines():
            if f"udp dpt:{port}" in line:
                cols = line.split()
                return int(cols[0]), int(cols[1])
    except Exception:
        pass
    return 0, 0


def safe_player_field(server_name) -> dict:
    names, _ = current_players_from_log(server_filter=server_name)
    if not names:
        return {"name": "Connected players", "value": "_none_", "inline": False}
    shown = names[:20]
    extra = f" _+ {len(names)-20} more_" if len(names) > 20 else ""
    return {
        "name": f"Connected players ({len(names)})",
        "value": ", ".join(f"`{n}`" for n in shown) + extra,
        "inline": False,
    }


def attack_source_ips(seen_ips: set, player_ips: set) -> list:
    return sorted(ip for ip in seen_ips if ip not in player_ips)


def get_log_pos() -> int:
    try:
        with open(LOG_POS_FILE) as f:
            return int((f.read() or "0").strip())
    except Exception:
        return 0


def set_log_pos(pos: int):
    try:
        with open(LOG_POS_FILE, "w") as f:
            f.write(str(pos))
    except Exception as e:
        print(f"could not save log pos: {e}")


def post_join_leave(server, action, name, ip_with_port=None, returning=False):
    names, _ = current_players_from_log(server_filter=server)
    count = len(names)
    if action == "join":
        title, color = "🟢 Player joined", 3066993
    else:
        title, color = "🔴 Player left", 15158332
    info = lookup_ip_info(ip_with_port)
    ip_clean = (ip_with_port or "").split(":", 1)[0] or "?"
    display_name = f"🔄 {name}" if returning else name
    fields = [
        {"name": "Server", "value": server, "inline": False},
        {"name": "Player", "value": display_name, "inline": True},
        {"name": "IP",     "value": f"`{ip_clean}`", "inline": True},
    ]
    if info.get("country_label"):
        fields.append({"name": "Country", "value": info["country_label"], "inline": True})
    if info.get("is_suspicious"):
        org = info.get("org") or "unknown"
        vtype = info.get("vpn_type") or "Proxy"
        fields.append({"name": f"⚠️ {vtype} detected", "value": org, "inline": False})
    max_players = _server_max.get(server, SERVER_MAX.get(server, 16))
    fields.append({"name": "Players online", "value": f"{count}/{max_players}", "inline": True})

    # On joins only: append a click-to-copy connect command for this server.
    if action == "join":
        port = SERVER_PORT.get(server)
        if port:
            host = SERVER_IPS.get(port) or get_public_ip()
            if host:
                pw = SERVER_PASSWORDS.get(port, "")
                cmd = f"connect {host}:{port}" + (f" {pw}" if pw else "")
                fields.append({
                    "name": "Connect",
                    "value": f"```\n{cmd}\n```",
                    "inline": False,
                })
    post({
        "username": "SoplonBOT",
        "embeds": [{
            "title": title,
            "color": color,
            "fields": fields,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }],
    })


def parse_command_extra(extra: str):
    """Parse the Lua-side extra payload for action='command'.
    Format: 'lvl=<n>|cmd=<text>'. Returns (level:str, command:str)."""
    lvl, cmd = "0", ""
    for part in (extra or "").split("|", 1):
        if part.startswith("lvl="):
            lvl = part[4:] or "0"
        elif part.startswith("cmd="):
            cmd = part[4:]
    return lvl, cmd


def post_command(server, name, ip_with_port, extra):
    """Post a Discord embed when a player issues an in-game / command."""
    lvl, cmd = parse_command_extra(extra)
    if not cmd:
        return
    info = lookup_ip_info(ip_with_port)
    ip_clean = (ip_with_port or "").split(":", 1)[0] or "?"
    fields = [
        {"name": "Server",    "value": server, "inline": False},
        {"name": "Player",    "value": name or "?", "inline": True},
        {"name": "IP",        "value": f"`{ip_clean}`", "inline": True},
        {"name": "Admin lvl", "value": str(lvl), "inline": True},
    ]
    if info.get("country_label"):
        fields.append({"name": "Country", "value": info["country_label"], "inline": True})
    if info.get("is_suspicious"):
        org = info.get("org") or "unknown"
        vtype = info.get("vpn_type") or "Proxy"
        fields.append({"name": f"⚠️ {vtype} detected", "value": org, "inline": False})
    fields.append({"name": "Command", "value": f"```\n{cmd[:900]}\n```", "inline": False})
    post({
        "username": "SoplonBOT",
        "embeds": [{
            "title": "🛠️ Command used",
            "color": 16753920,
            "fields": fields,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }],
    })


def check_service_health():
    for svc in HALO_SERVICES:
        try:
            r = subprocess.run(
                ["systemctl", "is-active", svc],
                capture_output=True, text=True, timeout=3,
            )
            new_state = (r.stdout or "").strip() or "unknown"
        except Exception as e:
            print(f"systemctl is-active {svc} failed: {e}")
            continue
        old_state = _service_state.get(svc)
        _service_state[svc] = new_state
        if old_state is None or old_state == new_state:
            continue
        if new_state == "active":
            post({
                "username": "SoplonBOT",
                "embeds": [{
                    "title": "✅ Halo service recovered",
                    "description": f"`{svc}` is back to **active** (was `{old_state}`)",
                    "color": 3066993,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                }],
            })
        else:
            post({
                "username": "SoplonBOT",
                "embeds": [{
                    "title": "🚨 Halo service down",
                    "description": f"`{svc}` state changed from `{old_state}` → **`{new_state}`**",
                    "color": 15158332,
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                }],
            })


def rebuild_active_players():
    _active_players.clear()
    _seen_ips.clear()
    if not os.path.exists(PLAYER_LOG):
        return
    try:
        with open(PLAYER_LOG, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split(",", 6)
                if len(parts) == 7:
                    _ts, server, action, name, ip, hsh, extra = parts
                elif len(parts) == 6:
                    _ts, server, action, name, ip, hsh = parts
                    extra = ""
                elif len(parts) == 5:
                    _ts, action, name, ip, hsh = parts
                    server = ""
                    extra = ""
                else:
                    continue
                if action == "startup":
                    for k in list(_active_players):
                        if k[0] == server:
                            _active_players.discard(k)
                    continue
                if action == "state":
                    if extra.startswith("maxplayers="):
                        try:
                            _server_max[server] = int(extra.split("=", 1)[1])
                        except (ValueError, IndexError):
                            pass
                    continue
                if action not in ("join", "leave"):
                    continue
                ip_clean = (ip or "").split(":", 1)[0]
                if action == "join" and ip_clean:
                    _seen_ips.add(ip_clean)
                key = (server, name, hsh)
                if action == "join":
                    _active_players.add(key)
                elif action == "leave":
                    _active_players.discard(key)
    except Exception as e:
        print(f"rebuild_active_players error: {e}")


def process_new_log_entries():
    """Tail players.log and post genuine join/leave events to Discord.
    Dedupes map-change rejoins via the _active_players set."""
    if not os.path.exists(PLAYER_LOG):
        return
    size = os.path.getsize(PLAYER_LOG)
    pos = get_log_pos()
    if pos > size:
        pos = 0  # rotated/truncated
    if pos >= size:
        return
    try:
        with open(PLAYER_LOG, encoding="utf-8", errors="replace") as f:
            f.seek(pos)
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split(",", 6)
                if len(parts) == 7:
                    _ts, server, action, name, ip, hsh, extra = parts
                elif len(parts) == 6:
                    _ts, server, action, name, ip, hsh = parts
                    extra = ""
                else:
                    continue
                if action == "startup":
                    # Drop in-memory ghosts for this server. No Discord post.
                    for k in list(_active_players):
                        if k[0] == server:
                            _active_players.discard(k)
                    continue
                if action == "state":
                    if extra.startswith("maxplayers="):
                        try:
                            _server_max[server] = int(extra.split("=", 1)[1])
                        except (ValueError, IndexError):
                            pass
                    continue
                if action == "command":
                    post_command(server, name, ip, extra)
                    continue
                if action not in ("join", "leave"):
                    continue
                key = (server, name, hsh)
                ip_clean = (ip or "").split(":", 1)[0]
                if action == "join":
                    if key in _active_players:
                        continue  # map-change rejoin, skip
                    returning = bool(ip_clean) and ip_clean in _seen_ips
                    if ip_clean:
                        _seen_ips.add(ip_clean)
                    _active_players.add(key)
                    post_join_leave(server, "join", name, ip, returning=returning)
                else:
                    if key not in _active_players:
                        continue
                    _active_players.discard(key)
                    # Don't show the returning marker on leave — the IP is
                    # already in _seen_ips from this player's own join, so a
                    # fresh check would falsely mark first-time visitors.
                    post_join_leave(server, "leave", name, ip, returning=False)
            set_log_pos(f.tell())
    except Exception as e:
        print(f"log tail error: {e}")


def main():
    if not SERVERS:
        print("[!] HALO_SERVERS env var is empty or invalid; exiting")
        return

    iface = detect_iface()
    print(f"[+] monitoring iface={iface} servers={SERVERS}")

    states = {}
    for port, info in SERVERS.items():
        ensure_iptables_counter(port)
        pkts, bts = read_port_counter(port)
        states[port] = {
            "name": info["name"],
            "last_pkts": pkts,
            "last_bytes": bts,
            "ip_window": deque(),
            "last_alert": defaultdict(lambda: 0.0),
        }

    # First-run guard for the join/leave tail: skip historical rows
    if not os.path.exists(LOG_POS_FILE) and os.path.exists(PLAYER_LOG):
        sz = os.path.getsize(PLAYER_LOG)
        set_log_pos(sz)
        print(f"[+] log tail starts at byte {sz} (historical join/leave rows skipped)")

    rebuild_active_players()
    print(f"[+] _active_players seeded with {len(_active_players)} entries from log")

    for svc in HALO_SERVICES:
        try:
            r = subprocess.run(
                ["systemctl", "is-active", svc],
                capture_output=True, text=True, timeout=3,
            )
            _service_state[svc] = (r.stdout or "").strip() or "unknown"
        except Exception:
            _service_state[svc] = "unknown"
    print(f"[+] watching services: {_service_state}")

    server_list = "\n".join(f"`{info['name']}` → UDP/{p} (max {info['max']})" for p, info in SERVERS.items())
    post({
        "username": "SoplonBOT",
        "embeds": [{
            "title": "🟢 Halo monitor online",
            "description": server_list,
            "color": 3066993,
            "fields": [
                {"name": "PPS threshold", "value": str(PPS_THRESHOLD), "inline": True},
                {"name": "BPS threshold", "value": f"{BPS_THRESHOLD // 1024 // 1024} Mbps", "inline": True},
                {"name": "Flood threshold", "value": f"{UNIQUE_IPS_THRESHOLD} IPs / {UNIQUE_IPS_WINDOW_SEC}s", "inline": True},
            ],
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }],
    })

    while True:
        time.sleep(POLL_SEC)
        now = time.time()

        # Tail players.log and post any genuine join/leave events.
        process_new_log_entries()

        # Watch halo services for crash / restart.
        check_service_health()

        for port, s in states.items():
            name = s["name"]
            pkts, bytes_ = read_port_counter(port)
            dp = pkts - s["last_pkts"]
            db = bytes_ - s["last_bytes"]
            s["last_pkts"], s["last_bytes"] = pkts, bytes_

            pps = dp / POLL_SEC
            bps = (db * 8) / POLL_SEC

            if pps >= PPS_THRESHOLD and now - s["last_alert"]["pps"] > ALERT_COOLDOWN_SEC:
                s["last_alert"]["pps"] = now
                post_alert(name, "⚠️ PPS spike",
                    f"Inbound packets to UDP/{port} spiked",
                    15105570,
                    [
                        {"name": "PPS", "value": f"{int(pps)}", "inline": True},
                        {"name": "Bandwidth", "value": f"{bps/1_000_000:.2f} Mbps", "inline": True},
                        safe_player_field(name),
                    ])

            if bps >= BPS_THRESHOLD and now - s["last_alert"]["bps"] > ALERT_COOLDOWN_SEC:
                s["last_alert"]["bps"] = now
                post_alert(name, "⚠️ Bandwidth spike",
                    f"Inbound bandwidth to UDP/{port} exceeded threshold",
                    15105570,
                    [
                        {"name": "PPS", "value": f"{int(pps)}", "inline": True},
                        {"name": "Bandwidth", "value": f"{bps/1_000_000:.2f} Mbps", "inline": True},
                        safe_player_field(name),
                    ])

            cur = conntrack_unique_ips(port)
            for ip in cur:
                s["ip_window"].append((now, ip))
            cutoff = now - UNIQUE_IPS_WINDOW_SEC
            while s["ip_window"] and s["ip_window"][0][0] < cutoff:
                s["ip_window"].popleft()
            unique_recent = {ip for _, ip in s["ip_window"]}

            if len(unique_recent) >= UNIQUE_IPS_THRESHOLD and now - s["last_alert"]["flood"] > ALERT_COOLDOWN_SEC:
                s["last_alert"]["flood"] = now
                _, player_ips = current_players_from_log(server_filter=name)
                attackers = attack_source_ips(unique_recent, player_ips)
                sample = ", ".join(attackers[:10]) if attackers else "_(all source IPs match known players — possible false positive)_"
                post_alert(name, "🚨 Connection flood detected",
                    f"{len(unique_recent)} unique src IPs hit UDP/{port} in the last {UNIQUE_IPS_WINDOW_SEC}s",
                    15158332,
                    [
                        {"name": f"Attack source IPs ({len(attackers)})", "value": f"`{sample}`", "inline": False},
                        safe_player_field(name),
                    ])


if __name__ == "__main__":
    main()
