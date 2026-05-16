# Monitoring Platform — Halo CE Server Observability Stack

A containerized observability stack for Halo CE dedicated servers. Combines a custom Python exporter, Prometheus, and Grafana to deliver real-time alerting on DDoS attacks and player events, plus historical visibility into traffic and player activity.

> Designed as a portfolio piece demonstrating production patterns:
> containerization, declarative config, secrets hygiene, healthchecks,
> persistent volumes, network isolation, and the push/pull split between
> event-style alerting (Discord) and metric-style observability (Prometheus).

---

## Architecture

```
                              ┌──────────────────────────────────────┐
                              │              VPS host                │
                              │   (Ubuntu 22.04, Wine, SAPP, halo-* )│
                              │                                      │
        Halo player UDP       │   ┌────────────────────────────┐     │
        traffic ────────►─────┼──►│ haloceded.exe (per server) │     │
                              │   │   ↳ SAPP Lua writes        │     │
                              │   │     /opt/halo-monitor/     │     │
                              │   │     players.log            │     │
                              │   └─────────────┬──────────────┘     │
                              │                 │                    │
                              │   ┌─────────────▼──────────────────┐ │
                              │   │ Docker (compose-managed)       │ │
                              │   │                                │ │
                              │   │  ┌─────────────────────────┐   │ │
                              │   │  │ netmon-alert (host net) │   │ │
                              │   │  │ • iptables counters     │   │ │
                              │   │  │ • ss -uan flood detect  │   │ │
                              │   │  │ • players.log tail      │   │ │
                              │   │  │ • Discord webhook push  │───┼─┼──► Discord
                              │   │  │ • /metrics on :9100     │   │ │
                              │   │  └────────────▲────────────┘   │ │
                              │   │   scrape via  │                │ │
                              │   │   host.docker │                │ │
                              │   │   .internal   │                │ │
                              │   │  ┌────────────┴────────────┐   │ │
                              │   │  │ prometheus (bridge net) │   │ │
                              │   │  │ • 30d TSDB retention    │   │ │
                              │   │  │ • port 9090 (localhost) │   │ │
                              │   │  └────────────▲────────────┘   │ │
                              │   │               │                │ │
                              │   │  ┌────────────┴────────────┐   │ │
                              │   │  │ grafana   (bridge net)  │───┼─┼──► http://vps:3000
                              │   │  │ • auto-provisioned DS   │   │ │
                              │   │  │ • netmon-alert dashboard│   │ │
                              │   │  └─────────────────────────┘   │ │
                              │   └────────────────────────────────┘ │
                              └──────────────────────────────────────┘
```

---

## Why these choices

### Why containerize?

The original bot was a single Python script bound to systemd. Containerizing gets us:
- **Reproducible deploys** — same image runs anywhere Docker runs.
- **Dependency isolation** — Python + `requests` + `prometheus_client` shipped with the image; the host never grows package-manager debt.
- **Clean upgrade path** — `docker compose pull && docker compose up -d` is the entire upgrade procedure.
- **Easy rollback** — pin image tags; the previous version is still on disk.

### Why does netmon-alert need `network_mode: host`?

Because the bot reads **the host's** packet counters (`iptables -L INPUT -v -n`) and **the host's** open UDP sockets (`ss -uan`). A bridge-networked container has its own netns and would see *its own* iptables and *its own* sockets — both empty. Host networking is the only way to get a true view of the host's UDP traffic.

This decision also explains the `cap_add: NET_ADMIN` — the bot inserts an `iptables -I INPUT ... ACCEPT` rule per Halo port at startup. Doing that requires NET_ADMIN even from inside a container.

### Why bridge networking for Prometheus and Grafana?

Those services don't need host-level visibility. They communicate by name on a private Docker bridge (`prometheus:9090`, `grafana:3000`). That gives us:
- **DNS-based service discovery** — Grafana's datasource URL is `http://prometheus:9090`, no IP hardcoding.
- **Reduced attack surface** — Prometheus's port 9090 is bound to `127.0.0.1` on the host, not exposed publicly. Only Grafana (port 3000) is reachable from outside.

### Why is Prometheus reaching netmon-alert via `host.docker.internal`?

Because netmon-alert is on the host network and Prometheus is on a bridge — they can't address each other by Docker DNS. `extra_hosts: host.docker.internal:host-gateway` is the canonical Linux workaround. On macOS/Windows Docker Desktop adds this automatically; we set it explicitly for Linux parity.

### Why a Discord webhook AND Prometheus metrics?

They answer different questions:
- **Discord** is push-style, event-driven: "this happened right now, please look." Joins, leaves, DDoS spikes. One message per event, human-readable, mobile-pingable.
- **Prometheus** is pull-style, continuous: "what's the shape of traffic over the last 24 hours?" Time-series, queryable, dashboard-able.

Trying to put trend analysis into Discord (or alerts into Grafana) is the wrong tool for the job in both directions.

### Why `unless-stopped` over `always`?

`always` would override a deliberate `docker compose stop` and restart anyway. `unless-stopped` respects operator intent: Docker will restart on host reboot or container crash, but a manual stop stays stopped.

### Why persistent named volumes?

Prometheus's TSDB and Grafana's user/dashboard state need to survive `docker compose down` + `up`. Named volumes (`prometheus-data`, `grafana-data`) are managed by Docker, lifecycle-decoupled from containers. Bind mounts would also work but pollute the project directory and complicate permissions.

### Why pin image tags (`prom/prometheus:v2.55.1` not `latest`)?

`latest` is a moving target — a rebuild months later could pull a different version with breaking changes. Pinning makes deployments reproducible. Renovate/Dependabot can bump these via PR for auditable upgrades.

### Why 30-day retention?

`--storage.tsdb.retention.time=30d` is a default that fits in <1GB of disk for this metric volume. Long enough to spot patterns, short enough to not bloat. Tune to your VPS disk and retention needs.

---

## Folder layout

```
monitoring-platform/
├── docker-compose.yml             # the entire stack
├── .env.example                   # template (commit this)
├── .env                           # real secrets (gitignored)
├── .gitignore
├── README.md
├── netmon-alert/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── netmon_alert.py            # bot with /metrics added
├── prometheus/
│   └── prometheus.yml             # scrape config
└── grafana/
    ├── provisioning/
    │   ├── datasources/
    │   │   └── prometheus.yml     # auto-add Prometheus datasource
    │   └── dashboards/
    │       └── dashboards.yml     # tell Grafana where dashboards live
    └── dashboards/
        └── netmon-alert.json      # the actual dashboard
```

---

## Deployment

### Prerequisites (on the VPS)

```bash
# Docker engine + compose plugin
curl -fsSL https://get.docker.com | sh
sudo apt install -y docker-compose-plugin

# Verify
docker --version
docker compose version
```

The Halo servers themselves (haloceded.exe / Wine / SAPP / `/opt/halo-monitor/players.log`) stay exactly where they are — outside Docker, on the host. The bot's container bind-mounts `/opt/halo-monitor/` so it can read what SAPP's Lua writes.

### Initial deploy

```bash
# 1. Clone the repo onto the VPS
git clone https://github.com/YOU/monitoring-platform.git
cd monitoring-platform

# 2. Fill in secrets
cp .env.example .env
$EDITOR .env        # set DISCORD_WEBHOOK, GRAFANA_ADMIN_PASSWORD, etc.

# 3. Build and bring it up
docker compose build
docker compose up -d

# 4. Verify
docker compose ps            # all services should be "Up (healthy)"
docker compose logs -f netmon-alert
curl http://localhost:9100/metrics | head      # sanity: bot exporting?
curl http://localhost:9090/-/healthy           # Prometheus healthy?
open http://YOUR_VPS_IP:3000                   # Grafana — login with .env creds
```

### Operations

```bash
# Tail one service's logs
docker compose logs -f netmon-alert

# Restart a single service after a config tweak
docker compose restart prometheus

# Rebuild the bot after editing netmon_alert.py
docker compose build netmon-alert && docker compose up -d netmon-alert

# Pull updated upstream images (Prometheus, Grafana)
docker compose pull && docker compose up -d

# Full teardown (keeps volumes)
docker compose down

# Wipe everything including TSDB and Grafana state
docker compose down -v
```

### Firewall recommendations (UFW)

```bash
sudo ufw allow 22/tcp                  # SSH (keep limited / key-only)
sudo ufw allow 2310:2312/udp           # Halo ports
sudo ufw allow from YOUR.HOME.IP to any port 3000 proto tcp  # Grafana, IP-restricted
sudo ufw deny 9090/tcp                 # Prometheus — internal only
sudo ufw deny 9100/tcp                 # /metrics — internal only
sudo ufw enable
```

For real production, put Grafana behind a reverse proxy (Caddy or nginx) with Let's Encrypt TLS, basic auth or OAuth, and bind Grafana itself to `127.0.0.1:3000` instead of `0.0.0.0:3000`.

---

## What's exposed

| Metric | Type | Labels | What it tells you |
|---|---|---|---|
| `netmon_pps` | Gauge | `server`, `port` | Inbound packets/sec to a Halo UDP port |
| `netmon_bps` | Gauge | `server`, `port` | Inbound bytes/sec |
| `netmon_unique_src_ips_window` | Gauge | `server`, `port` | Distinct source IPs in the flood-detection window |
| `netmon_players_online` | Gauge | `server` | Active players, derived from `players.log` replay |
| `netmon_player_joins_total` | Counter | `server` | Cumulative joins |
| `netmon_player_leaves_total` | Counter | `server` | Cumulative leaves |
| `netmon_vpn_detections_total` | Counter | `server` | Joins flagged by proxycheck.io as VPN/proxy |
| `netmon_alerts_fired_total` | Counter | `server`, `kind` | Discord alerts emitted (kind = pps / bps / flood) |
| `netmon_webhook_errors_total` | Counter | — | Failed Discord POSTs |
| `netmon_ip_lookups_total` | Counter | `status` | proxycheck.io call outcomes |

Useful PromQL one-liners:

```promql
# Sustained high-PPS server (over 5 min)
avg_over_time(netmon_pps[5m]) > 500

# Join rate (joins/minute) per server
rate(netmon_player_joins_total[5m]) * 60

# Has any DDoS alert fired in the last hour?
increase(netmon_alerts_fired_total[1h]) > 0

# VPN-join ratio (last hour)
increase(netmon_vpn_detections_total[1h])
  / clamp_min(increase(netmon_player_joins_total[1h]), 1)
```

---

## Known trade-offs

- **`network_mode: host` on netmon-alert** loses container-level network isolation. Justified because the bot's job *is* to inspect host networking. Alternatively: a sidecar approach with `--privileged` mount of `/proc/net/` — same security trade, more moving parts.
- **No Alertmanager (yet).** All threshold logic is still inside the bot. A future iteration could move PPS/BPS/flood thresholds into Prometheus rules + an Alertmanager Discord receiver, decoupling "what to alert on" from the bot. The push-style Discord events (join/leave) stay in the bot regardless.
- **No log aggregation (yet).** Container logs are JSON-file-driven with size caps. Plug in Loki + Promtail for centralized log querying if this becomes a multi-host deployment.
- **No metric authentication.** Prometheus and `/metrics` are bound to `127.0.0.1` / behind UFW. For multi-tenant or untrusted networks, put basic auth + TLS in front via a reverse proxy.

---

## License

MIT
