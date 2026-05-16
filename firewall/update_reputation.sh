#!/bin/bash
# Pulls free IP-reputation feeds (FireHOL Level 1, Spamhaus DROP/EDROP) into
# the halo-reputation ipset. Filters bogon ranges (loopback, RFC1918, link-local,
# CGNAT, multicast, etc.) because feeds include them but iptables would then
# drop legitimate host-internal traffic.
set -euo pipefail

IPSET=halo-reputation
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FEEDS=(
    "https://iplists.firehol.org/files/firehol_level1.netset"
    "https://www.spamhaus.org/drop/drop.txt"
    "https://www.spamhaus.org/drop/edrop.txt"
)

# Bogons that must never be in the public-source-IP ban list. If they appear
# as a packet source, our `-i ! lo` exclusion in iptables already saves
# loopback, but we filter here too for defense in depth and clarity.
is_bogon() {
    case "$1" in
        0.*|10.*|127.*|169.254.*|192.0.0.*|192.0.2.*|198.18.*|198.19.*|198.51.100.*|203.0.113.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        192.168.*) return 0 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
        22[4-9].*|23[0-9].*|24[0-9].*|25[0-5].*) return 0 ;;
    esac
    return 1
}

for url in "${FEEDS[@]}"; do
    name=$(basename "$url")
    curl -fsSL --max-time 30 "$url" -o "$TMP/$name" || logger -t halo-reputation "feed fetch failed: $url"
done

ipset create "$IPSET" hash:net family inet hashsize 16384 maxelem 524288 -exist
ipset create "${IPSET}_new" hash:net family inet hashsize 16384 maxelem 524288 -exist
ipset flush "${IPSET}_new"

count=0
skipped=0
while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    if is_bogon "$cidr"; then
        skipped=$((skipped + 1))
        continue
    fi
    if ipset add "${IPSET}_new" "$cidr" -exist 2>/dev/null; then
        count=$((count + 1))
    fi
done < <(cat "$TMP"/* 2>/dev/null | grep -Ev '^[[:space:]]*([;#]|$)' | awk '{print $1}' | sort -u)

ipset swap "${IPSET}_new" "$IPSET"
ipset destroy "${IPSET}_new"

mkdir -p /etc/ipset
ipset save "$IPSET" > /etc/ipset/halo-reputation.set

logger -t halo-reputation "refreshed: $count CIDRs loaded, $skipped bogons filtered"
echo "halo-reputation: $count CIDRs loaded, $skipped bogons filtered"
