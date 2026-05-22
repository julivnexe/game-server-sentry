# antimomentum/haloce firewall (vendored + parameterized)

A raw-table, **Halo-CE-protocol-aware** DDoS firewall. Unlike a generic
rate-limiter, it validates that each packet *looks like real Halo CE
traffic* — exact packet lengths and protocol signature bytes — and drops
everything else in the `raw` table, **before conntrack**. A booter-style
UDP flood of generic large packets fails the byte checks and is dropped
at the cheapest possible point in the kernel.

## Credit & license

All scripts under [`upstream/`](upstream/) are the work of **Augie Luebbers**,
copied verbatim from <https://github.com/antimomentum/haloce> (`firewalls/`).
They are **MIT licensed** — see [`LICENSE`](LICENSE). This directory retains
that license as required.

`halo-firewall.sh` and `halo-firewall.service` in this folder are a
**derivative work** of Augie's `upstream/firewall-newtest.sh` — same MIT
license, same copyright. The rule *logic* is unchanged; the wrapper only
adds configuration variables and lockout protection (see below).

## What's here

| File | What it is |
|---|---|
| `upstream/firewall.sh` | Augie's original — verbatim, unmodified |
| `upstream/firewall-newtest.sh` | Augie's original (DoS + scan protections) — verbatim |
| `upstream/flusher.sh` | Augie's original — tears down the rules |
| `upstream/README.md` | Augie's original README |
| `halo-firewall.sh` | **Parameterized** derivative of `firewall-newtest.sh` |
| `halo-firewall.service` | systemd unit for `halo-firewall.sh` |
| `LICENSE` | Augie's MIT license |

## Why a parameterized version

Augie's scripts hardcode `eth0` and only whitelist the master-server IPs.
Running them as-is on a VPS with a different interface, or without your
own IP whitelisted, is the exact mistake that locks you out of SSH. The
advice that came with these scripts, baked into `halo-firewall.sh`:

1. **It drops packets before conntrack** — faster, cheaper than a
   filter-table firewall.
2. **Whitelist your own IP first, or you lock yourself out.** The danger
   isn't *forgetting to autorun* it — it's *running it without your IP
   whitelisted*. `halo-firewall.sh` seeds `ADMIN_IPS` into the `WHITELIST`
   ipset **before the first DROP rule loads**, and **refuses to run** if
   `ADMIN_IPS` is empty. That makes the lockout structurally impossible.
3. **Whitelist a VPN IP too.** Put a *static VPN exit IP* in `ADMIN_IPS`,
   not just your residential IP. Residential IPs rotate; if yours changes
   while the firewall is up, the VPN IP is your guaranteed way back in.
4. **Use the correct public interface.** A wrong interface name means
   every rule silently matches nothing — you look protected but you're
   wide open. `halo-firewall.sh` validates the interface exists and
   aborts with the list of real ones if not. Confirm with `ip -br link`.
5. **It coexists with UFW.** This lives in the `raw` table at PREROUTING;
   UFW lives in `filter`/INPUT. Traffic hits this *first*. They don't
   conflict — this drops the garbage early, UFW governs whatever survives.
   Keep UFW for normal host hygiene.

## Configure

Create `/etc/halo-firewall.conf`:

```sh
IFACE=ens3                                  # YOUR public iface — check: ip -br link
MASTER_IPS=34.197.71.170 54.82.252.156      # Halo CE master servers (hosthpc)
ADMIN_IPS=203.0.113.10 198.51.100.20        # your static VPN exit IP(s) — SSH backdoor
```

`ADMIN_IPS` is space-separated and **must not be empty**.

## Install

```sh
sudo apt install ipset
sudo install -m 755 halo-firewall.sh   /usr/local/sbin/halo-firewall.sh
sudo install -m 755 upstream/flusher.sh /usr/local/sbin/halo-flush.sh
sudo install -m 644 halo-firewall.service /etc/systemd/system/halo-firewall.service
sudo nano /etc/halo-firewall.conf        # fill in IFACE / ADMIN_IPS
sudo systemctl daemon-reload
```

**First run — do this with a web console (Vultr/OVH) tab open as a fallback:**

```sh
sudo systemctl start halo-firewall
# now CONFIRM you still have SSH from a second terminal.
# if SSH works:
sudo systemctl enable halo-firewall      # safe to autostart — backdoor is seeded first
```

To tear it down: `sudo systemctl stop halo-firewall` (or run `halo-flush.sh`).

## ⚠ Status: untested in this exact form

The `upstream/` files are Augie's, proven in his deployment. `halo-firewall.sh`
is a faithful but **untested** parameterization — there is currently no live
server to verify it against. Before trusting it on a real box: run it once
by hand with a console session open, confirm SSH survives, *then* enable the
unit. The `raw`/u32 byte offsets assume a standard Ethernet/IP/UDP layout —
verify against your provider's networking.

## Not included

Augie's repo also has `tc/`, `vpngateway/`, and `xdp-ebpf/` directories
(traffic shaping, NAT-gateway, and XDP/eBPF variants). Only the iptables
firewall scripts are vendored here. Grab the rest from
<https://github.com/antimomentum/haloce> if you need them.
