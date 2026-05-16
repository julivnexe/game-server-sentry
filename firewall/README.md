# Firewall hardening scripts

iptables + ipset + sysctl recipe for layered DDoS defense on a single VPS.

## Scripts

| File | Purpose | Cadence |
|---|---|---|
| `update_reputation.sh` | Pulls FireHOL Level 1, Spamhaus DROP, Spamhaus EDROP into ipset `halo-reputation`. Filters bogons (loopback, RFC1918, link-local, etc.) before adding. | Daily |
| `update_geoip.sh` | Pulls per-country CIDR zones from ipdeny.com into ipset `halo-geo-allow`. **Optional / disabled by default** because it blocks VPN-using players. Edit the `COUNTRIES` array if you want to use it. | Weekly |

## iptables rule recipe

Insert at the **top** of your `INPUT` chain (where `<game_port>` is your game's listen port, e.g. 2312 for Halo CE):

```bash
# Drop anything matching the auto-banlist (managed by auto-banner container).
iptables -I INPUT 1 -m set --match-set halo-banlist src -j DROP

# Drop public-reputation matches, EXCEPT on loopback (otherwise you'll drop
# your own host's internal traffic — FireHOL/Spamhaus include bogons).
iptables -I INPUT 2 ! -i lo -m set --match-set halo-reputation src -j DROP

# Fast-path the allowlist: verified players bypass rate limits.
iptables -I INPUT 3 -p udp -m multiport --dports <game_port> \
    -m set --match-set halo-allowlist src -j ACCEPT

# Per-source-IP rate limit (per-player flood protection).
iptables -I INPUT 4 -p udp -m multiport --dports <game_port> \
    -m hashlimit --hashlimit-name game-pps --hashlimit-mode srcip \
    --hashlimit-above 80/sec --hashlimit-burst 400 -j DROP

# Per-destination-port rate limit (absolute ceiling).
iptables -I INPUT 5 -p udp -m multiport --dports <game_port> \
    -m hashlimit --hashlimit-name game-port --hashlimit-mode dstport \
    --hashlimit-above 500/sec --hashlimit-burst 1000 -j DROP

# Finally, accept legit traffic.
iptables -A INPUT -p udp --dport <game_port> -j ACCEPT
```

Persist with `iptables-save > /etc/iptables/rules.v4`.

## ipsets

Create the empty sets before adding the iptables rules above:

```bash
ipset create halo-banlist     hash:net family inet hashsize 1024 maxelem 65536 timeout 86400
ipset create halo-allowlist   hash:ip  family inet hashsize 1024 maxelem 65536
ipset create halo-reputation  hash:net family inet hashsize 16384 maxelem 524288
ipset create halo-geo-allow   hash:net family inet hashsize 16384 maxelem 524288  # optional
```

Persist via `ipset save > /etc/ipset/<setname>.set` and restore at boot before `iptables-restore` runs. The repo's `halo-firewall-restore.service` systemd unit does this; copy from your VPS deployment or write your own.

## sysctl hardening

Drop this into `/etc/sysctl.d/10-network-security.conf`:

```
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.netfilter.nf_conntrack_max = 65536
```

`sysctl --system` to apply.

## Systemd timer template

```ini
# /etc/systemd/system/halo-reputation-update.service
[Unit]
Description=Refresh halo-reputation ipset
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/firewall/update_reputation.sh
```

```ini
# /etc/systemd/system/halo-reputation-update.timer
[Unit]
Description=Daily reputation refresh

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
```

`systemctl enable --now halo-reputation-update.timer`.

## ⚠️ The loopback trap

FireHOL Level 1 and Spamhaus DROP both include bogon networks (127.0.0.0/8, 10.0.0.0/8, RFC1918, etc.) because those addresses should never appear as public source IPs and seeing them means the packet is spoofed.

If you add those to an ipset and DROP everything matching, **you will drop all loopback traffic on your host** — Prometheus on `127.0.0.1:9090`, healthchecks, internal HTTP, everything dies silently and the symptom looks like "my monitoring is broken."

The `update_reputation.sh` script filters bogons before adding (defense in depth), and the recommended iptables rule above uses `! -i lo` to exempt loopback explicitly. Keep both safeguards.
