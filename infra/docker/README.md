# Dockerized two-node deployment

Runs the Collector and Coach as **separate Pilot identities in separate
containers**, each with its own `/root/.pilot/` directory and its own
`pilot-daemon` socket. This is the required topology — two pilot nodes on
the same host user would compete for `/tmp/pilot.sock`, so they're isolated
by container filesystem namespaces.

## Two transport modes

### Stub (default) — works out of the box

In stub mode, the Collector's inbox volume is mounted into the Coach
container and vice versa. Messages move between identities as JSON files on
a shared volume. This is **functionally identical** to Pilot's datagram
delivery from the apps' point of view — same `agent`/`data` wrapper, same
inbox semantics.

```bash
cd ~/yc_hackathon
docker compose -f docker/docker-compose.yml up --build
```

You should see:
- `hc-collector` running `python -m collector.server` against `/var/collector_inbox`
- `hc-coach` running `python -m coach watch` against `/var/coach_inbox`

To drop an envelope into the collector (simulating an iOS source):

```bash
docker compose exec collector ls /var/collector_inbox
# copy a JSON file in — see scripts/make_mock_envelopes.py
```

To run a one-shot Coach query against the live Collector:

```bash
docker compose run --rm coach query "SELECT COUNT(*) AS n FROM samples"
```

### Real pilot-daemon — production

Drop a Linux `pilot-daemon` binary at `/opt/pilot/bin/pilot-daemon` in each
container (uncomment the bind mounts in `docker-compose.yml`) and set the
`PILOT_*` env vars to point at the registry/beacon. The entrypoint scripts
detect the binary and start it before the Python app.

Required env vars per container:

```
PILOT_REGISTRY="34.71.57.205:9000"
PILOT_BEACON="34.71.57.205:9001"
PILOT_EMAIL="<address>"
PILOT_HOSTNAME="<unique-hostname>"
```

Each container gets a fresh identity under its own `/root/.pilot/` volume —
no collision with the host's Pilot daemon.

## Why two containers (not one process, not one identity)

| Concern | Why two containers |
|---|---|
| Identity isolation | Coach is read-only; Collector is the only writer. If they shared an identity, granting Coach trust to read would grant it trust to write too. |
| Socket isolation | One Pilot daemon per UNIX user can hold `/tmp/pilot.sock`. Containers give each daemon its own namespace. |
| Trust scoping | The Collector's source allowlist (iOS senders) and coach allowlist (Coach readers) are separate; mixing them on one identity confuses the trust graph. |
| Independent restart | Restarting the Coach for a code update doesn't bounce ingestion. |

## Volumes

| Volume | Owned by | Mounted into | Purpose |
|---|---|---|---|
| `collector_inbox` | collector | both | iOS Envelopes + Coach Queries land here |
| `collector_data` | collector | collector | DuckDB warehouse |
| `collector_pilot` | collector | collector | `/root/.pilot/` identity |
| `coach_inbox` | coach | both | Acks + QueryResults + ChangeEvents land here |
| `coach_pilot` | coach | coach | `/root/.pilot/` identity |

## End-to-end smoke test (stub mode)

`scripts/e2e_docker.sh` is the canonical run.
