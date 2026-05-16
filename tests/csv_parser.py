"""Reference CSV parser that matches the spec in docs/CSV_FORMAT.md.

This is a clean reimplementation that the test suite uses to validate
both the spec and the production parser logic in netmon_alert.py /
auto_banner.py. If this file drifts from the production parsers, the
tests catch it — that's the point.

Accepts schema v1 in three concrete shapes for backward compat:
  * 6-field legacy (pre-extra)
  * 7-field unversioned (extra column, implicit v1)
  * 8-field versioned (extra column + trailing schema_version)
"""
from __future__ import annotations
from dataclasses import dataclass
from typing import Optional


@dataclass
class Row:
    timestamp: str
    server_name: str
    action: str
    player_name: str
    ip: str           # may include ":port"
    hash: str
    extra: str
    schema_version: str   # "v1" if unversioned legacy row


def parse_row(line: str) -> Optional[Row]:
    """Parse one CSV line into a Row, or return None for malformed lines.

    Never raises — malformed input always yields None so the production
    parsers can `continue` past garbage without aborting log replay.
    """
    if not line or line.startswith("#"):
        return None
    line = line.rstrip("\r\n")
    if not line.strip():
        return None
    parts = line.split(",", 7)
    if len(parts) == 8:
        ts, server, action, name, ip, hsh, extra, ver = parts
    elif len(parts) == 7:
        ts, server, action, name, ip, hsh, extra = parts
        ver = "v1"
    elif len(parts) == 6:
        ts, server, action, name, ip, hsh = parts
        extra, ver = "", "v1"
    else:
        return None
    if not action:
        return None
    return Row(
        timestamp=ts,
        server_name=server,
        action=action,
        player_name=name,
        ip=ip,
        hash=hsh,
        extra=extra,
        schema_version=ver,
    )


def parse_command_extra(extra: str) -> tuple[str, str]:
    """Parse `lvl=<n>|cmd=<text>` payload. Mirrors netmon_alert.py."""
    lvl, cmd = "0", ""
    for part in (extra or "").split("|", 1):
        if part.startswith("lvl="):
            lvl = part[4:] or "0"
        elif part.startswith("cmd="):
            cmd = part[4:]
    return lvl, cmd


def parse_state_extra(extra: str) -> Optional[int]:
    """Parse `maxplayers=<n>` payload. Returns None if missing/bad."""
    if not extra.startswith("maxplayers="):
        return None
    try:
        return int(extra.split("=", 1)[1])
    except (ValueError, IndexError):
        return None
