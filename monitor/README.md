# Standalone monitor (legacy)

A single Python daemon that does the same join/leave Discord notifications + DDoS counter monitoring as the full [observability stack](../observability/), but without Docker, Prometheus, Grafana, or auto-banner.

Use this if you want:
- Minimal deps (Python 3 + `requests`)
- No Docker
- Just Discord notifications, no dashboards or auto-ban

Use the [Docker stack](../observability/) instead if you want:
- Auto-banning of attacker subnets
- Grafana dashboards
- Prometheus metrics
- Healthchecks and restart policies

The two deployments are mutually exclusive — both tail `/opt/halo-monitor/players.log` and would race on the bookmark file if you ran them simultaneously.

## Install

```bash
sudo mkdir -p /opt/halo-monitor
sudo install -m 755 halo_ddos_monitor.py /opt/halo-monitor/halo_ddos_monitor.py
sudo touch /opt/halo-monitor/players.log
```

Edit `halo-ddos-monitor.service` and replace `REPLACE_ME` with your Discord webhook URL plus any other `Environment=` settings (see comments in the file).

```bash
sudo install -m 644 halo-ddos-monitor.service /etc/systemd/system/halo-ddos-monitor.service
sudo systemctl daemon-reload
sudo systemctl enable --now halo-ddos-monitor
sudo journalctl -u halo-ddos-monitor -f
```

You should see a 🟢 **monitor online** embed in Discord.

## Configuration

All knobs are systemd `Environment=` lines. Full list:

| Variable | Default | Purpose |
|---|---|---|
| `DISCORD_WEBHOOK` | *(required)* | Webhook URL. |
| `HALO_SERVERS` | `2302:Server 1` | `port:name[:max]` list, comma-separated. |
| `WATCHED_SERVICES` | `halo-server` | systemd units for liveness watch. |
| `PROXYCHECK_KEY` | *(empty)* | proxycheck.io API key (free 100/day without). |
| `SERVER_PASSWORDS` | *(empty)* | `port:password` for connect-command embed. |
| `PPS_THRESHOLD` | `3000` | inbound packets/sec to alert on. |
| `BPS_THRESHOLD` | `8388608` | bytes/sec to alert on (8 Mbps). |
| `UNIQUE_IPS_THRESHOLD` | `40` | unique src IPs in window for flood-alert. |
| `UNIQUE_IPS_WINDOW_SEC` | `10` | flood-detection window. |
| `ALERT_COOLDOWN_SEC` | `60` | minimum gap between alerts of same kind. |
| `POLL_SEC` | `2` | main loop interval. |
| `IFACE` | *(autodetect)* | network interface name. |
| `PLAYER_LOG` | `/opt/halo-monitor/players.log` | CSV path. |
| `LOG_POS_FILE` | `/opt/halo-monitor/players.log.pos` | tail bookmark. |
