#!/bin/bash
# Builds halo-geo-allow ipset from ipdeny.com per-country CIDR zonefiles.
# Editable: just change the COUNTRIES array.
set -euo pipefail

IPSET=halo-geo-allow
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

COUNTRIES=(
    # North America
    us ca mx
    # Central America / Caribbean
    gt bz hn sv ni cr pa cu do ht jm pr aw bs bb tt dm kn lc vc gd ag ky tc bm vg
    # South America
    ar bo br cl co ec gy py pe sr uy ve fk gf
    # Europe (added per request)
    gb
    # Oceania
    au nz fj pg nc pf
)

for cc in "${COUNTRIES[@]}"; do
    curl -fsSL --max-time 15 "https://www.ipdeny.com/ipblocks/data/aggregated/${cc}-aggregated.zone" -o "$TMP/$cc" 2>/dev/null || logger -t halo-geo-allow "fetch failed: $cc"
done

ipset create "$IPSET" hash:net family inet hashsize 16384 maxelem 524288 -exist
ipset create "${IPSET}_new" hash:net family inet hashsize 16384 maxelem 524288 -exist
ipset flush "${IPSET}_new"

count=0
while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    [[ "$cidr" =~ ^# ]] && continue
    if ipset add "${IPSET}_new" "$cidr" -exist 2>/dev/null; then
        count=$((count + 1))
    fi
done < <(cat "$TMP"/* 2>/dev/null | sort -u)

ipset swap "${IPSET}_new" "$IPSET"
ipset destroy "${IPSET}_new"

mkdir -p /etc/ipset
ipset save "$IPSET" > /etc/ipset/halo-geo-allow.set

logger -t halo-geo-allow "refreshed: $count CIDRs from ${#COUNTRIES[@]} countries"
echo "halo-geo-allow: $count CIDRs from ${#COUNTRIES[@]} countries"
