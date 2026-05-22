#!/usr/bin/env bash
#
# halo-firewall.sh — parameterized wrapper around antimomentum/haloce's
# firewall-newtest.sh (raw-table, Halo-CE-protocol-aware DDoS filter).
#
# Derivative work of https://github.com/antimomentum/haloce — MIT licensed,
# Copyright (c) 2019 Augie Luebbers. See ./LICENSE. Every iptables rule below
# is Augie's, unchanged in logic; this wrapper only:
#   1. hoists the interface name + admin/master IPs into config variables,
#   2. seeds your admin "backdoor" IPs into WHITELIST BEFORE any DROP loads,
#   3. refuses to run if no admin IP is set (structural lockout prevention),
#   4. validates the interface exists (a wrong interface = silently no-ops).
#
# ⚠  UNTESTED in this exact form. Verify on a fresh server with a console
#    session (Vultr/OVH web console) OPEN as a fallback before trusting it.
#    See README.md.
#
set -u

# ============================ CONFIG ============================
# Public network interface. A WRONG interface name means every rule
# silently matches nothing — you THINK you are protected while wide
# open. Confirm the real one with:   ip -br link
IFACE="${IFACE:-}"

# Halo CE master server IPs (hosthpc.com / s1.master.hosthpc.com).
# Must stay reachable or your server won't list. Defaults are the
# known hosthpc masters that Augie's scripts ship with.
MASTER_IPS="${MASTER_IPS:-34.197.71.170 54.82.252.156}"

# YOUR admin IPs — the SSH backdoor. Space-separated.
# Put a STATIC VPN exit IP (or small range) here, NOT a residential IP,
# so the backdoor survives ISP address changes. If this is empty the
# script REFUSES to run: applying the firewall with no admin IP
# whitelisted locks you out of SSH.
ADMIN_IPS="${ADMIN_IPS:-}"
# =================================================================

die() { echo "halo-firewall: FATAL: $*" >&2; exit 1; }

# --- Safety guards — these structurally prevent the SSH lockout ---
[ "$(id -u)" -eq 0 ] || die "must run as root."
[ -n "$ADMIN_IPS" ] || die "ADMIN_IPS is empty — refusing to run (this would lock you out of SSH). Set it to your VPN exit IP(s)."
[ -n "$IFACE" ] || die "IFACE is not set. Pick your public interface from: $(ip -br link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
ip link show "$IFACE" >/dev/null 2>&1 || die "interface '$IFACE' does not exist. Available: $(ip -br link 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"

echo "halo-firewall: applying — IFACE=$IFACE  MASTER_IPS='$MASTER_IPS'  ADMIN_IPS='$ADMIN_IPS'"

# --- Idempotent flush of any previous run (raw + mangle only) ---
# The brief window here is OPEN, not locked — safe. ipsets are kept
# (created with -exist below) so timeout-based learning survives.
iptables -t raw -F 2>/dev/null || true
iptables -t raw -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

# --- Kernel tuning (Augie's) ---
ip link set "$IFACE" mtu 9000 2>/dev/null || echo "halo-firewall: note: could not set MTU 9000 on $IFACE (non-fatal)"
sleep 1
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1
sysctl -w net.ipv4.ipfrag_low_thresh=0
sysctl -w net.ipv4.ipfrag_high_thresh=0
sysctl -w net.ipv4.ipfrag_time=0
sysctl -w net.core.netdev_max_backlog=4000

# --- ipsets, created BEFORE any iptables rule ---
ipset create LEGIT hash:ip,port timeout 20 -exist
ipset create TEST1 hash:ip timeout 80 -exist
ipset create BLOCK hash:ip timeout 300 -exist
ipset create BAN  hash:ip -exist
ipset create BAN2 hash:ip -exist
ipset create WHITELIST hash:ip -exist

# --- STEP ONE: seed the admin backdoor + master IPs into WHITELIST,
#     before a single DROP rule exists. This is the lockout fix. ---
for ip in $MASTER_IPS $ADMIN_IPS; do
    ipset add WHITELIST "$ip" -exist
done

ipset create TESTS list:set -exist
ipset add TESTS TEST1 -exist
ipset add TESTS WHITELIST -exist
ipset create BANS list:set -exist
ipset add BANS BAN -exist
ipset add BANS BAN2 -exist

# --- chains ---
iptables -t raw    -N pcheck
iptables -t mangle -N ctest2
iptables -t mangle -N reconnect
iptables -t mangle -N ban
iptables -t mangle -N ban2

# --- raw table: drop non-Halo-shaped packets before conntrack ---
iptables -t raw -A PREROUTING -i "$IFACE" -m set --match-set TESTS src -j ACCEPT
iptables -t raw -A PREROUTING -i "$IFACE" -m length --length 48 -j pcheck
iptables -t raw -A PREROUTING -i "$IFACE" -m length ! --length 67 -j DROP
iptables -t raw -A PREROUTING -i "$IFACE" -m u32 --u32 "28=0xfefe0100" -j pcheck
iptables -t raw -A PREROUTING -i "$IFACE" -j DROP
iptables -t raw -A pcheck -p udp --sport 53 -j DROP
iptables -t raw -A pcheck -m set --match-set BLOCK src -j DROP
iptables -t raw -A pcheck -m set --match-set BANS src -j DROP
iptables -t raw -A pcheck -p udp --sport 0 -j SET --exist --add-set BLOCK src
iptables -t raw -A pcheck -m set --match-set BLOCK src -j DROP
iptables -t raw -A pcheck ! -p udp -j SET --exist --add-set BLOCK src
iptables -t raw -A pcheck -p udp ! --dport 2302:2502 -j SET --exist --add-set BLOCK src
iptables -t raw -A pcheck -m length --length 48 -m u32 --u32 "42=0x1333360c" -j SET --exist --add-set TEST1 src
iptables -t raw -A pcheck -m length --length 67 -m u32 --u32 "28=0xfefe0100" -j SET --exist --add-set TEST1 src
iptables -t raw -A pcheck -m set --match-set TEST1 src -j ACCEPT
iptables -t raw -A pcheck -j DROP

# --- mangle table: stateful per-source DoS / scan protection ---
iptables -t mangle -A PREROUTING -i "$IFACE" -j SET --exist --add-set TEST1 src
iptables -t mangle -A PREROUTING -i "$IFACE" -m hashlimit --hashlimit-name DOSBAN2 --hashlimit-mode srcip --hashlimit-srcmask 32 --hashlimit-above 900/second --hashlimit-burst 300 -j ban
iptables -t mangle -A PREROUTING -i "$IFACE" -m set --match-set LEGIT src,src -j SET --exist --add-set LEGIT src,src
iptables -t mangle -A PREROUTING -i "$IFACE" -m length --length 31 -m set --match-set LEGIT src,src -m u32 --u32 "27&0x00FFFFFF=0x00fefe68" -j reconnect
iptables -t mangle -A PREROUTING -i "$IFACE" -m set --match-set LEGIT src,src -j ACCEPT
iptables -t mangle -A PREROUTING -i "$IFACE" -p tcp -m set --match-set WHITELIST src -j ACCEPT
iptables -t mangle -A PREROUTING -i "$IFACE" -m set --match-set BANS src -j DROP
iptables -t mangle -A PREROUTING -i "$IFACE" -m set --match-set TEST1 src -j ctest2
iptables -t mangle -A PREROUTING -i "$IFACE" -j DROP
iptables -t mangle -A ctest2 -m set --match-set BLOCK src -j DROP
for ip in $MASTER_IPS; do
    iptables -t mangle -A ctest2 -s "$ip" -j ACCEPT
done
iptables -t mangle -A ctest2 -p udp --sport 0 -j SET --exist --add-set BLOCK src
iptables -t mangle -A ctest2 ! -p udp -j SET --exist --add-set BLOCK src
iptables -t mangle -A ctest2 -p udp ! --dport 2302:2502 -j SET --exist --add-set BLOCK src
iptables -t mangle -A ctest2 -m recent --name badguy3 --set
iptables -t mangle -A ctest2 -m recent --update --name badguy3 --seconds 5 --hitcount 15 -j SET --exist --add-set BLOCK src
iptables -t mangle -A ctest2 -m connlimit --connlimit-above 5 --connlimit-mask 32 -j DROP
iptables -t mangle -A ctest2 -p udp --sport 53 -j SET --exist --add-set BLOCK src
iptables -t mangle -A ctest2 -m set --match-set BLOCK src -j DROP
iptables -t mangle -A ctest2 -m u32 --u32 "28=0xfefe0100" -j SET --exist --add-set LEGIT src,src
iptables -t mangle -A ctest2 -m set --match-set LEGIT src,src -j ACCEPT
iptables -t mangle -A ctest2 -m length --length 34 -m u32 --u32 "28=0x5C717565" -j ACCEPT
iptables -t mangle -A ctest2 -m length --length 48 -m u32 --u32 "42=0x1333360c" -j ACCEPT
iptables -t mangle -A ctest2 -m u32 --u32 "34&0xFFFFFF=0xFFFFFF" -j ACCEPT
iptables -t mangle -A ctest2 -j DROP
iptables -t mangle -A reconnect -j SET --del-set TEST1 src
iptables -t mangle -A reconnect -j SET --del-set LEGIT src,src
iptables -t mangle -A reconnect -j ACCEPT
iptables -t mangle -A ban -j SET --del-set TEST1 src
iptables -t mangle -A ban -j SET --del-set LEGIT src,src
iptables -t mangle -A ban -j SET --exist --add-set BAN src
iptables -t mangle -A ban -j DROP
iptables -t mangle -A ban2 -j SET --exist --add-set BAN2 src
iptables -t mangle -A ban2 -j SET --del-set TEST1 src
iptables -t mangle -A ban2 -j SET --del-set LEGIT src,src
iptables -t mangle -A ban2 -j DROP

# Augie's script also stops these (they conflict with the raw rules).
# Left commented — enable only if you understand the DNS/NTP impact.
# systemctl stop systemd-timesyncd && systemctl stop systemd-resolved

echo "halo-firewall: applied. Admin IPs whitelisted for SSH: $ADMIN_IPS"
echo "halo-firewall: VERIFY you still have SSH before closing your console session."
