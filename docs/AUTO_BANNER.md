# Auto-banner

The `auto-banner` container is the most operationally risky component in the stack: it adds entries to the `halo-banlist` ipset, which an `iptables -j DROP` rule references. A bad ban removes legitimate players from the server until the entry expires.

Read this before deploying to production.

## What it does

```
loop every 30 seconds:
  pps = prometheus.query("sum(netmon_pps)")    ← total inbound across game ports
  if pps < 1500:
      sleep & continue
  capture = tcpdump for 15 seconds on game ports
  count source IPs by packet count
  group source IPs by /24 subnet
  for each /24 with ≥ 3 distinct source IPs:
      if any IP in the /24 is a known player    ← veto
      or the /24 is RFC1918 / loopback           ← veto
      → skip
      otherwise → ipset add <subnet>/24 timeout 24h
  for each individual IP with ≥ 300 pps that isn't already covered by a banned /24:
      same veto rules apply
      otherwise → ipset add <ip>/32 timeout 24h
  post Discord alert listing what was banned and what was skipped
```

Source: [`observability/auto-banner/auto_banner.py`](../observability/auto-banner/auto_banner.py).

## Default thresholds

All from `observability/.env` (override per-environment); defaults baked into [`auto_banner.py`](../observability/auto-banner/auto_banner.py) match these.

| Env var | Default | Meaning |
|---|---|---|
| `PPS_TRIGGER` | `1500` | **Investigation threshold.** Total inbound pps across all `HALO_PORTS` summed. Below this, the loop sleeps and does nothing. |
| `CHECK_INTERVAL_SEC` | `30` | Time between Prometheus queries. |
| `CAPTURE_DURATION_SEC` | `15` | How long `tcpdump` runs once the trigger fires. Longer = more accurate attribution, more memory used by the capture. |
| `MIN_IPS_PER_SUBNET` | `3` | A /24 only becomes a ban candidate if at least N distinct IPs from it appeared in the capture. Below this, the script treats it as legitimate variance. |
| `SINGLE_IP_PPS` | `300` | An individual IP needs to be sending at least this many pps during the capture to get a /32 ban. Only applies if the IP isn't already covered by a banned /24. |
| `BAN_TTL_SEC` | `86400` (24h) | How long each entry stays in `halo-banlist`. False positives self-correct after this window. |
| `IPSET_NAME` | `halo-banlist` | The ipset the iptables DROP rule references. |
| `PERMANENT_WHITELIST` | `127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16` | CIDRs that never get banned regardless of behaviour. RFC1918 and loopback by default. |

## TTL: why 24 hours?

Long enough that a determined attacker who bounces across the botnet can't immediately retry from the same subnets; short enough that an unlucky CG-NAT carrier or VPN exit shared with the booter gets unstuck without operator action overnight.

If you operate a scrims-only server and want shorter rebans, drop to 3600 (1h). If you've been under sustained attack for days and the banlist is working, push to 604800 (7d).

## Unbanning manually

```bash
# Remove a specific subnet
sudo ipset del halo-banlist 1.2.3.0/24

# Remove a specific IP
sudo ipset del halo-banlist 1.2.3.4/32

# Inspect what's banned and how long each entry has left
sudo ipset list halo-banlist

# Nuke everything (player connections that were blocked recover immediately)
sudo ipset flush halo-banlist
```

The auto-banner does not re-add entries you removed unless they appear in a new capture. If you keep needing to remove the same /24, it probably belongs in `PERMANENT_WHITELIST`.

## False-positive scenarios

Each of these has produced a real-world false-positive in similar setups. Operator action listed.

**Matchmaking spike / Discord event / content creator goes live with the server IP visible.** A burst of legitimate players from many /24s in a short window can look exactly like a small botnet. The 3-IPs-per-/24 floor catches most of it, but a popular streamer's viewers tend to come from many networks at once.
- *Action:* check the Discord auto-ban embed. If the listed subnets correlate with your community (e.g. residential ISPs in your region), `ipset flush halo-banlist` and consider raising `MIN_IPS_PER_SUBNET` to 5.

**New game release / sequel announcement.** Same dynamics as above but bigger.
- *Action:* raise `PPS_TRIGGER` to `3000` for 24–48h around the launch, or stop the container temporarily (`docker compose stop auto-banner`).

**Legitimate flood from a single dedicated player on a fast connection (e.g. someone on gigabit fiber spamming reload).** Real player traffic can hit 50–80 pps; sustained, that can rarely reach `SINGLE_IP_PPS=300` if the engine is misconfigured.
- *Action:* their IP should already be in `halo-allowlist` (auto-managed from `players.log`). If not, add manually: `sudo ipset add halo-allowlist <ip>`.

**LAN party / shared IP.** Twenty friends behind one NAT submit one IP, look like a heavy hitter.
- *Action:* add that IP to `PERMANENT_WHITELIST` and restart the container.

**CG-NAT carrier.** Mobile carriers route many real users through few IPs. One booter behind the same carrier can drag the whole CG-NAT /24 into the banlist.
- *Action:* `ipset del halo-banlist <subnet>/24` immediately. Consider whitelisting the carrier's known CG-NAT ranges in `PERMANENT_WHITELIST`.

## How to disable the auto-banner

Three options, in order of how surgical:

1. **Stop the container:** `docker compose stop auto-banner` from inside `observability/`. The ipset and iptables rule stay in place; manual `ipset add` still works.
2. **Disable triggering without losing the ipset wiring:** set `PPS_TRIGGER=99999999` in `.env` and `docker compose up -d auto-banner`. The container runs, polls Prometheus, never fires.
3. **Remove entirely:** `docker compose rm -fs auto-banner` and delete the `auto-banner:` service block from `docker-compose.yml`. The iptables `-j DROP -m set --match-set halo-banlist src` rule stays — `ipset flush halo-banlist` clears any active bans.

## Metrics

The auto-banner **does not expose its own Prometheus `/metrics` endpoint.** It only *reads* `netmon_pps` from Prometheus. Visibility into its behaviour:

| Signal | How to observe |
|---|---|
| Whether the trigger is firing | `docker logs --tail 200 auto-banner` — every loop iteration logs `total halo pps=X trigger>1500` |
| What's currently banned | `sudo ipset list halo-banlist` |
| When the last ban fired | Discord channel (search for "🛡️ Auto-ban fired") |
| Capture quality | `docker logs auto-banner` shows `capture empty — nothing to ban` when tcpdump finds no traffic during a triggered window |

If you want first-class metrics (ban count, last-ban-age, capture duration histogram), it would be a small addition to `auto_banner.py` — see [#TODO](../) issue when filed.

## Operational checklist

Before turning auto-banner loose on a production server, confirm:

- [ ] `players.log` exists at the path mounted into the container (`/opt/halo-monitor` by default) and contains recent join entries — these are your veto list
- [ ] `iptables -L INPUT -n` shows the `-m set --match-set halo-banlist src -j DROP` rule
- [ ] `ipset list halo-banlist` works (set exists, type `hash:net`, timeout entries supported)
- [ ] `DISCORD_WEBHOOK` is set in `.env` so you see when bans fire
- [ ] You know the ipset commands to unban manually before you need them
