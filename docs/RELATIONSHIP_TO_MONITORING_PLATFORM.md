# Relationship to `monitoring-platform`

A reviewer landing on this repo may also see the [`monitoring-platform`](https://github.com/julivnexe) repo and wonder whether they're duplicates. They aren't.

`game-server-sentry` is the **game-server-specific evolution** of `monitoring-platform`.

- **`monitoring-platform`** is the general observability stack — Prometheus + Grafana + a custom Python exporter — for **any** UDP service. Network-level metrics: packets per second, bandwidth, unique source IPs, conntrack health, sysctl/iptables counters. No game awareness, no Discord notifications.

- **`game-server-sentry`** layers **game-aware monitoring**, **Discord notifications**, **auto-banning**, **reputation feed integration**, and a **pluggable adapter pattern** for per-game player events on top of that observability spine.

## Which one do I want?

| Goal | Use |
|---|---|
| Network-level monitoring of a UDP service (any UDP, including non-game) | `monitoring-platform` |
| Game server with player-level events, auto-banning, Discord notifications, reputation feed integration | `game-server-sentry` |
| Both — game server *and* network monitoring | `game-server-sentry` (it includes the observability pieces from `monitoring-platform` and adds the game layer on top) |

## Why not merge them?

`monitoring-platform` is useful as a primitive for non-game contexts (a self-hosted Mumble server, a Pelican proxy, etc.) where the game-specific Lua adapters and CSV protocol are noise. Keeping them separate lets each repo carry only what its audience needs.

Neither repo is archived. Both stay public and maintained.
