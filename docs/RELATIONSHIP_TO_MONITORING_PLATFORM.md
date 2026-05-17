# Relationship to `monitoring-platform`

A reviewer landing on this repo may also see the [`monitoring-platform`](https://github.com/julivnexe) repo and wonder whether they're duplicates. They aren't.

`halo-ce-command-center` is the **Halo CE-specific evolution** of `monitoring-platform`.

- **`monitoring-platform`** is the general observability stack — Prometheus + Grafana + a custom Python exporter — for any UDP service. Network-level metrics: packets per second, bandwidth, unique source IPs, conntrack health, sysctl/iptables counters. No game awareness, no Discord notifications.

- **`halo-ce-command-center`** layers SAPP-aware monitoring, Discord notifications, auto-banning, reputation feed integration, and a per-IP KDA stat tracker on top of that observability spine. Halo CE specific.

## Which one do I want?

| Goal | Use |
|---|---|
| Network-level monitoring of an arbitrary UDP service | `monitoring-platform` |
| Halo CE server with player events, KDA tracking, auto-banning, Discord notifications, reputation feeds | `halo-ce-command-center` |
| Both — Halo CE *and* deeper network monitoring | `halo-ce-command-center` (it includes the observability pieces from `monitoring-platform` and adds the Halo CE layer on top) |

## Why not merge them?

`monitoring-platform` is useful as a primitive for non-game contexts (a self-hosted Mumble server, a Pelican proxy, etc.) where SAPP scripts and the CSV protocol are noise. Keeping them separate lets each repo carry only what its audience needs.

Neither repo is archived. Both stay public and maintained.
