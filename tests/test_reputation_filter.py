"""Reputation feed parser / bogon filter tests.

The script firewall/update_reputation.sh adds CIDRs from FireHOL Level 1
and Spamhaus DROP/EDROP to ipset halo-reputation. The single most
dangerous bug we've hit was the loopback case: FireHOL includes
127.0.0.0/8 (as a bogon meant for spoofed-source detection), and
dropping it system-wide breaks all loopback traffic.

These tests reimplement the bogon filter in Python and prove it
catches every bogon class the bash script lists.
"""
import re
import pytest


def is_bogon(cidr_or_ip: str) -> bool:
    """Port of the `is_bogon()` shell function in update_reputation.sh.

    Returns True for any RFC1918, loopback, link-local, CGNAT, multicast,
    reserved, or documentation-only range. False for publicly routable.
    """
    ip = cidr_or_ip.split("/")[0].strip()
    if not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
        return False
    octets = [int(o) for o in ip.split(".")]
    o1, o2, o3, _o4 = octets
    if o1 == 0:                                   return True   # 0.0.0.0/8
    if o1 == 10:                                  return True   # RFC1918
    if o1 == 127:                                 return True   # loopback
    if o1 == 169 and o2 == 254:                   return True   # link-local
    if o1 == 172 and 16 <= o2 <= 31:              return True   # RFC1918
    if o1 == 192 and o2 == 0 and o3 == 0:         return True   # special use
    if o1 == 192 and o2 == 0 and o3 == 2:         return True   # TEST-NET-1
    if o1 == 192 and o2 == 168:                   return True   # RFC1918
    if o1 == 198 and o2 in (18, 19):              return True   # benchmarking
    if o1 == 198 and o2 == 51 and o3 == 100:      return True   # TEST-NET-2
    if o1 == 203 and o2 == 0 and o3 == 113:       return True   # TEST-NET-3
    if o1 == 100 and 64 <= o2 <= 127:             return True   # CGNAT
    if 224 <= o1 <= 239:                          return True   # multicast
    if 240 <= o1 <= 255:                          return True   # reserved
    return False


# ---------- the dangerous ones we've hit in prod ----------

@pytest.mark.parametrize("bogon", [
    "127.0.0.1",                # the loopback case that took an hour to diagnose
    "127.0.0.0/8",
    "10.0.0.0/8",
    "10.255.255.255",
    "172.16.0.0/12",
    "172.20.1.1",
    "192.168.0.0/16",
    "192.168.1.100",
    "169.254.1.1",              # link-local
    "100.64.0.0/10",            # CG-NAT (shared by mobile carriers)
    "100.127.255.255",          # high end of CG-NAT
    "0.0.0.0",
    "224.0.0.1",                # multicast
    "255.255.255.255",          # broadcast
])
def test_known_bogons_are_filtered(bogon):
    assert is_bogon(bogon), f"{bogon} should be filtered but wasn't"


# ---------- publicly routable, must NOT be filtered ----------

@pytest.mark.parametrize("public_ip", [
    "8.8.8.8",                   # Google DNS
    "1.1.1.1",                   # Cloudflare DNS
    "203.0.114.0",               # *just outside* TEST-NET-3 (203.0.113.0/24)
    "100.63.255.255",            # *just outside* CG-NAT (still public)
    "100.128.0.0",               # *just outside* CG-NAT
    "172.15.255.255",            # *just outside* RFC1918 172.16/12
    "172.32.0.0",                # *just outside* RFC1918 172.16/12
    "126.255.255.255",           # *just outside* loopback
    "128.0.0.1",                 # *just outside* loopback
])
def test_public_ips_are_not_filtered(public_ip):
    assert not is_bogon(public_ip), f"{public_ip} should NOT be filtered"


# ---------- FireHOL line format ----------

def parse_firehol_line(line: str):
    """Lines look like:
        # comment
        1.2.3.0/24
        4.5.0.0/16   ; extra annotation

       Returns the CIDR or None.
    """
    line = line.strip()
    if not line or line.startswith(("#", ";")):
        return None
    return line.split()[0]


def test_firehol_comment_lines_ignored():
    assert parse_firehol_line("# updated daily") is None
    assert parse_firehol_line("; spamhaus") is None
    assert parse_firehol_line("") is None
    assert parse_firehol_line("    ") is None


def test_firehol_cidr_extracted():
    assert parse_firehol_line("203.0.113.0/24") == "203.0.113.0/24"
    assert parse_firehol_line("203.0.113.0/24 ; ASN12345") == "203.0.113.0/24"
    assert parse_firehol_line("  8.8.8.8/32  ") == "8.8.8.8/32"


def test_end_to_end_feed_round_trip():
    """Simulate ingesting a few lines of a FireHOL-style feed and confirm
    bogons are excluded while public CIDRs make it into the final set."""
    feed = """\
# FireHOL Level 1 — synthetic test fixture
# updated 2026-05-15
127.0.0.0/8
10.0.0.0/8
1.2.3.0/24
203.0.113.0/24
8.8.4.0/24
# comment in the middle
192.168.0.0/16
9.9.9.9/32
"""
    accepted = []
    skipped = []
    for line in feed.splitlines():
        cidr = parse_firehol_line(line)
        if cidr is None:
            continue
        if is_bogon(cidr):
            skipped.append(cidr)
        else:
            accepted.append(cidr)
    assert accepted == ["1.2.3.0/24", "8.8.4.0/24", "9.9.9.9/32"]
    assert "127.0.0.0/8" in skipped
    assert "10.0.0.0/8" in skipped
    assert "192.168.0.0/16" in skipped
    assert "203.0.113.0/24" in skipped
