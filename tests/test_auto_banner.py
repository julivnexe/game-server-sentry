"""Auto-banner threshold + subnet logic tests.

The auto-banner is the only part of the stack that proactively cuts
players off the server. These tests prove:

  * The trigger fires at the documented PPS_TRIGGER threshold and not
    below it.
  * /24 grouping correctly buckets IPs from the same subnet.
  * Subnet bans only trigger when at least MIN_IPS_PER_SUBNET distinct
    IPs from one /24 appear.
  * Individual /32 bans skip IPs already covered by a banned /24.
"""
from collections import Counter
import ipaddress

import pytest


# ---------- the logic under test, reimplemented for testability ----------
# Mirrors auto_banner.py:group_by_subnet and the evaluate_and_ban flow,
# pulled out so we don't import the full module (which has side effects
# at module load: ipset/iptables calls, prometheus connection, etc).

def group_by_subnet(ips):
    """Mirror of auto_banner.group_by_subnet."""
    from collections import defaultdict
    subnets = defaultdict(set)
    for ip in ips:
        parts = ip.split(".")
        if len(parts) != 4:
            continue
        subnet = f"{parts[0]}.{parts[1]}.{parts[2]}.0/24"
        subnets[subnet].add(ip)
    return subnets


def is_whitelisted(ip, whitelist_cidrs):
    """Mirror of auto_banner.is_whitelisted_subnet but parameterised."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    for cidr in whitelist_cidrs:
        try:
            if addr in ipaddress.ip_network(cidr, strict=False):
                return True
        except ValueError:
            continue
    return False


def decide_bans(counter, *, player_whitelist, permanent_whitelist,
                pps_trigger, min_ips_per_subnet, single_ip_pps,
                capture_duration):
    """Mirror of auto_banner.evaluate_and_ban's decision logic."""
    total_pps = sum(counter.values()) / capture_duration
    if total_pps < pps_trigger:
        return [], []
    bans = []
    skipped = []
    subnets = group_by_subnet(counter.keys())
    for subnet, ips in subnets.items():
        if len(ips) < min_ips_per_subnet:
            continue
        if any(ip in player_whitelist for ip in ips):
            skipped.append(f"{subnet} (contains a known player)")
            continue
        sample = next(iter(ips))
        if is_whitelisted(sample, permanent_whitelist):
            skipped.append(f"{subnet} (permanent whitelist)")
            continue
        bans.append(subnet)
    banned_prefixes = {b.rsplit(".0/", 1)[0] for b in bans}
    for ip, pkts in counter.items():
        pps_ip = pkts / capture_duration
        if pps_ip < single_ip_pps:
            continue
        if ip in player_whitelist:
            skipped.append(f"{ip} (known player)")
            continue
        if is_whitelisted(ip, permanent_whitelist):
            skipped.append(f"{ip} (permanent whitelist)")
            continue
        prefix = ".".join(ip.split(".")[:3])
        if prefix in banned_prefixes:
            continue  # already covered by subnet ban
        bans.append(f"{ip}/32")
    return bans, skipped


# ---------- /24 grouping ----------

def test_group_by_subnet_buckets_same_24():
    subnets = group_by_subnet(["1.2.3.4", "1.2.3.5", "1.2.3.6"])
    assert subnets == {"1.2.3.0/24": {"1.2.3.4", "1.2.3.5", "1.2.3.6"}}


def test_group_by_subnet_separates_different_24s():
    subnets = group_by_subnet(["1.2.3.4", "1.2.4.4"])
    assert set(subnets) == {"1.2.3.0/24", "1.2.4.0/24"}


def test_group_by_subnet_ignores_malformed():
    subnets = group_by_subnet(["1.2.3.4", "not.an.ip", ""])
    assert "1.2.3.0/24" in subnets
    assert len(subnets) == 1


# ---------- PPS trigger threshold ----------

def test_trigger_does_not_fire_below_threshold():
    # 100 IPs each at 1 pps = 100 pps total — far below trigger 1500
    counter = Counter({f"203.0.113.{i}": 15 for i in range(100)})
    bans, _ = decide_bans(counter,
                          player_whitelist=set(),
                          permanent_whitelist=["127.0.0.0/8", "10.0.0.0/8"],
                          pps_trigger=1500,
                          min_ips_per_subnet=3,
                          single_ip_pps=300,
                          capture_duration=15)
    assert bans == []


def test_trigger_fires_at_threshold():
    # 10 IPs from same /24, each sending 2500 packets in 15s = ~167 pps each
    # = 1667 pps total, exceeds 1500. Ten IPs from one /24 → subnet ban.
    counter = Counter({f"203.0.113.{i}": 2500 for i in range(10)})
    bans, _ = decide_bans(counter,
                          player_whitelist=set(),
                          permanent_whitelist=["127.0.0.0/8"],
                          pps_trigger=1500,
                          min_ips_per_subnet=3,
                          single_ip_pps=300,
                          capture_duration=15)
    assert "203.0.113.0/24" in bans


# ---------- veto rules ----------

def test_subnet_with_known_player_is_skipped():
    counter = Counter({f"203.0.113.{i}": 2500 for i in range(10)})
    bans, skipped = decide_bans(
        counter,
        player_whitelist={"203.0.113.5"},   # a real player from this /24
        permanent_whitelist=["127.0.0.0/8"],
        pps_trigger=1500,
        min_ips_per_subnet=3,
        single_ip_pps=300,
        capture_duration=15,
    )
    assert "203.0.113.0/24" not in bans
    assert any("known player" in s for s in skipped)


def test_rfc1918_skipped():
    # All from a single private /24 sending hard — must still skip.
    counter = Counter({f"10.0.0.{i}": 5000 for i in range(5)})
    bans, skipped = decide_bans(
        counter,
        player_whitelist=set(),
        permanent_whitelist=["10.0.0.0/8", "127.0.0.0/8"],
        pps_trigger=1500,
        min_ips_per_subnet=3,
        single_ip_pps=300,
        capture_duration=15,
    )
    assert "10.0.0.0/24" not in bans
    assert any("whitelist" in s.lower() for s in skipped)


def test_single_ip_ban_below_min_subnet_count():
    # One IP sending 24000 packets in 15s = 1600 pps total (exceeds trigger)
    # AND >300 pps single-IP threshold. No /24 cluster, so /32 ban fires.
    counter = Counter({"203.0.113.99": 24000})
    bans, _ = decide_bans(
        counter,
        player_whitelist=set(),
        permanent_whitelist=["127.0.0.0/8"],
        pps_trigger=1500,
        min_ips_per_subnet=3,
        single_ip_pps=300,
        capture_duration=15,
    )
    assert "203.0.113.99/32" in bans


def test_single_ip_skipped_when_subnet_already_banned():
    # 5 IPs in same /24, each ~400 pps — total 2000 pps (triggers).
    # Subnet bans, individual /32 entries are redundant.
    counter = Counter({f"203.0.113.{i}": 6000 for i in range(5)})
    bans, _ = decide_bans(
        counter,
        player_whitelist=set(),
        permanent_whitelist=["127.0.0.0/8"],
        pps_trigger=1500,
        min_ips_per_subnet=3,
        single_ip_pps=300,
        capture_duration=15,
    )
    assert "203.0.113.0/24" in bans
    assert not any(b.endswith("/32") for b in bans)
