# Migration: legacy `monitor/` daemon → `observability/` Docker stack

If you were running the single-process `monitor/halo-ddos-monitor.service` systemd unit (deleted in the refactor that introduced this file), here's how to move to the supported Docker stack.

The CSV protocol and `players.log` location have not changed. Your Halo CE Lua adapter (`discord_notify.lua`) needs no edits — keep writing to the same path.

## Move

1. **Stop and disable the old daemon:**
   ```bash
   sudo systemctl disable --now halo-ddos-monitor
   sudo rm /etc/systemd/system/halo-ddos-monitor.service
   ```
2. **Deploy the Docker stack** per [`observability/STACK_README.md`](../observability/STACK_README.md). The compose file mounts `/opt/halo-monitor/` into the `netmon-alert` container, so the same `players.log` keeps flowing.
3. **Move your env vars.** The systemd unit's `Environment="KEY=VAL"` lines become entries in `observability/.env` (copy `.env.example` first). All names are preserved; only the location changes.
4. **Start the stack:**
   ```bash
   cd observability && docker compose up -d
   ```

You will lose nothing functional: the new `netmon-alert` container is a superset of the old standalone daemon (same join/leave/command/state Discord embeds, same DDoS spike alerts, plus a `/metrics` Prometheus endpoint and integration with the `auto-banner` container).

## Why the legacy path was removed

Two parallel deployments were running the same code path against the same `players.log`. They raced on the tail bookmark file, and one operator hit it in production — joins silently disappeared from Discord because both daemons fought over `players.log.pos`. Keeping a single supported deployment story prevents that footgun.

## If you really want a no-Docker deployment

The repo no longer ships one, but the bot code (`observability/netmon-alert/netmon_alert.py`) is a single Python file plus `requirements.txt`. Run it directly under systemd with the same `Environment=` lines you used before. You will lose the auto-banner, Prometheus metrics consumption, and Grafana dashboards — only the standalone Discord-notification subset will work.
