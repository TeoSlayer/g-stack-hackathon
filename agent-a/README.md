# agent-a — Collector

Receives HealthKit envelopes from the iOS app over Pilot Protocol, dedupes by
sample UUID, writes to DuckDB, answers SQL queries from the Coach, and
broadcasts ChangeEvents when new data lands.

Runs as Docker container `g-stack-agent-a` on the GCP deployment VM.
OpenClaw workspace at `../.openclaw/collector-workspace/`.

## What it owns

| Concern | How |
|---|---|
| Inbound envelopes | Pilot `send-message` → Collector node; inbox_watcher classifies by content shape |
| Deduplication | Sample UUID primary key; `INSERT OR IGNORE` |
| Durability | `facts.duckdb` in Docker volume `docker_agent_a_data` |
| SQL query surface | Coach sends JSON with `sql` field → Collector executes read-only → sends QueryResult back |
| Change notifications | After each batch commit: sends `{kind: "samples_added", ...}` to Coach via `send-message` |
| Acknowledgements | Sends Ack JSON (accepted/duplicate/rejected UUIDs) back to iOS source |
| G-Brain memory | `gbrain-collector-home` — calendar context, factual observations. Separate from Coach's G-Brain. |
| health-intelligence | Calls `http://127.0.0.1:8741/retrieve` for evidence-backed context on any health question |

## Why Pilot for the phone→agent link

The iOS app embeds `pilot-swift` — a precompiled Pilot daemon inside the
app sandbox. The iPhone is a Pilot node. Envelopes travel over an encrypted,
NAT-traversed tunnel directly to the Collector. No port forwarding, no VPN,
no public HTTP endpoint needed. Pilot handles NAT traversal, identity, and
delivery confirmation.

## How messaging actually works

All inter-node communication uses one primitive:

```sh
pilotctl send-message <target-node-id> --data '<json>'
```

The daemon delivers the JSON to the target's `~/.pilot/inbox/` as a file.
`inbox_watcher.py` polls that directory and classifies by content:

- `samples` present → HealthKit envelope → ingest path
- `sql` present → SQL query → sql_gate → QueryResult sent back
- `kind: "samples_added"` → ChangeEvent (outbound from Collector)
- Other → left for G-Brain ingester or heartbeat agent

There are no application-level virtual port numbers. Pilot's built-in services
are: dataexchange (port 1001, used by `send-message`), echo (port 7),
handshake (port 444).

## Status

| Module | Status | What it does |
|---|---|---|
| `schema.py` | ✓ Done | Pydantic models: Envelope, RouteChunk, Ack, Query, QueryResult, ChangeEvent. Version gating. |
| `warehouse.py` | ✓ Done | DuckDB single-writer, MVCC reads. Tables: batches, samples, workouts, route_points, route_chunks_inflight. |
| `ingester.py` | ✓ Done | `process_envelope()` — validates, dedupes by UUID + batch_id, returns IngestResult. |
| `inbox_watcher.py` | ✓ Done | Polls `~/.pilot/inbox`, classifies by content shape, dispatches to ingester or sql_gate. |
| `sql_gate.py` | ✓ Done | Read-only SQL gate. Rejects writes at parse time. Clamps LIMIT ≤ 10,000. |
| `change_event.py` | ✓ Done | Sends ChangeEvent to Coach after each batch commit. |
| `trust.py` | ✓ Done | Source/consumer allowlists + version gating. |
| `server.py` | ✓ Done | Entry point. Wires all modules. |
| `transport.py` | ✓ Done | `FileTransport` (tests), `PilotctlTransport` (production shells out to `pilotctl`), `TeeTransport`. |

**84 unit tests passing.** 8 E2E scenarios: clean ingest, bad samples, batch
replay, route assembly, SQL query, change events.

## Running (production)

```sh
# On the GCP VM:
docker compose -f infra/docker/docker-compose.yml up -d
docker logs g-stack-agent-a --follow
```

## Running (local dev)

```sh
# Tests:
pytest agent-a/tests/
./scripts/run_e2e.sh

# Daemon (file-inbox mode, no real Pilot):
python -m collector.server

# Query via Coach CLI:
python -m coach query "SELECT type, COUNT(*) FROM samples GROUP BY type"
python -m coach readiness
```

## Wire format (envelope)

```json
{
  "source": "ios.healthsync",
  "device_id": "iPhone-Calin",
  "app_version": "0.1.0",
  "batch_id": "uuid-v4",
  "samples": [
    {
      "uuid": "hk-sample-uuid",
      "type": "heartRateVariabilitySDNN",
      "value": 47.2,
      "unit": "ms",
      "start_utc": 1701234567.0,
      "end_utc":   1701234567.0,
      "source_name": "Apple Watch"
    }
  ]
}
```

Ack: `{batch_id, accepted: [...], duplicates: [...], rejected: [...]}`.

The iOS app advances its HealthKit anchor only after receiving this Ack.
This is the write barrier — a crash or network failure causes the same
samples to re-send, deduped on arrival by UUID.

## DuckDB schema

```sql
CREATE TABLE samples (
  uuid         VARCHAR PRIMARY KEY,
  source       VARCHAR NOT NULL,
  device_id    VARCHAR NOT NULL,
  type         VARCHAR NOT NULL,
  value        DOUBLE,
  unit         VARCHAR,
  start_utc    DOUBLE  NOT NULL,
  end_utc      DOUBLE  NOT NULL,
  source_name  VARCHAR,
  metadata     JSON,
  ingested_utc DOUBLE  NOT NULL DEFAULT epoch(current_timestamp)
);
CREATE INDEX samples_type_start ON samples (type, start_utc);

CREATE TABLE batches (
  batch_id      VARCHAR PRIMARY KEY,
  source        VARCHAR NOT NULL,
  device_id     VARCHAR NOT NULL,
  envelope_meta JSON,
  ingested_utc  DOUBLE  NOT NULL,
  sample_count  INTEGER NOT NULL
);
```

Single writer, MVCC reads. The Coach queries concurrently without blocking ingest.

## Recoverability

- **Crash mid-batch:** DuckDB rolls back. Envelope not acked; iOS retries
  with same UUIDs. `INSERT OR IGNORE` absorbs the replay.
- **Disk full:** Insert fails, ack withheld, iOS outbox queues until space recovers.
- **Coach down:** Collector keeps ingesting. ChangeEvents are best-effort
  `send-message` calls; the Coach catches up when it reconnects.

## What's next

- Source identity allowlist enforcement from config (currently hardcoded in `trust.py`).
- G-Brain rollup: write a markdown summary of each batch to `gbrain-collector-home`
  after commit (similar to `agent-b/coach/gbrain_rollup.py`).

## Where it fits

```
iPhone (health-sync)
    │  pilotctl send-message → Collector node
    ▼
┌─────────────────────────────────┐
│  g-stack-agent-a  (Collector)   │
│  inbox_watcher ← Pilot inbox    │
│  ingester → facts.duckdb        │
│  sql_gate ← Coach queries       │
│  change_event → Coach inbox     │
│  G-Brain: gbrain-collector-home │
└──────────┬──────────────────────┘
           │ send-message (SQL queries + ChangeEvents)
    ┌──────▼──────────────────────┐
    │  g-stack-agent-b  (Coach)   │
    └─────────────────────────────┘
```

See [`../README.md`](../README.md) for the full picture,
[`SCHEMA.md`](SCHEMA.md) for the wire format,
[`CHUNKING.md`](CHUNKING.md) for outbox/retry details.
