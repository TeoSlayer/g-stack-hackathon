# agent-a — Health Ingest

Receives HealthKit envelopes from the iOS app over Pilot Protocol, dedupes by
sample UUID, writes to DuckDB, and broadcasts change events so downstream
consumers know new data has landed. No LLM, no reasoning, no conversation.

## What it owns

| Concern | How |
|---|---|
| Inbound envelopes | Pilot listener on port `1001` |
| Deduplication | Sample UUID is the primary key; `INSERT OR IGNORE` |
| Durability | DuckDB file on disk (`infra/data/health.duckdb`) |
| Query API | Pilot port `1003` — SQL-string request → result-set reply |
| Change notifications | Pilot port `1004` — `{table, new_count, since_ts}` after every batch commit |
| Acknowledgements | Pilot reply to source's ack-port with accepted/duplicate/rejected UUIDs |
| Long-term memory | G-Brain rollup: derives daily markdown summaries, writes to shared gbrain instance |

## Why Pilot for the phone→agent link

The iOS app embeds `pilot-swift` — a precompiled Go Pilot daemon inside the
app sandbox. This means the iPhone itself is a Pilot node. Envelopes travel
over an encrypted, NAT-traversed tunnel directly to Agent A. No homelab port
forwarding, no VPN configuration, no public HTTP endpoint needed. Pilot
handles NAT traversal, identity, and delivery confirmation.

## Why a separate agent

Ingest has different SLOs than reasoning: it must accept writes continuously,
never block on a slow LLM step, and survive consumer crashes without losing
data. Keeping the warehouse isolated means either side restarts independently.

## Status: core built

| Module | Status | What it does |
|---|---|---|
| `schema.py` | ✓ Done | Pydantic models: Envelope, RouteChunk, Ack, Query, QueryResult, ChangeEvent. Version gating (accepts v and v-1). |
| `warehouse.py` | ✓ Done | DuckDB single-writer, MVCC-read. Tables: batches, samples, workouts, route_points, route_chunks_inflight. |
| `ingester.py` | ✓ Done | `process_envelope()` — validates, dedupes by UUID + batch_id, returns IngestResult. |
| `inbox_watcher.py` | ✓ Done | Polls inbox, classifies messages, dispatches to ingester or sql_gate. |
| `sql_gate.py` | ✓ Done | Read-only SQL gate. Rejects writes at parse time. Clamps LIMIT ≤ 10,000. |
| `change_event.py` | ✓ Done | Broadcasts ChangeEvent after each batch commit. |
| `trust.py` | ✓ Done | Source/consumer allowlists + version gating. |
| `server.py` | ✓ Done | Entry point. Wires all modules; CLI args for inbox, warehouse path, trust config. |
| `transport.py` | ⚠ Partial | `FileTransport` (test mode) done; `PilotctlTransport` (production) stubbed. |
| `gbrain_rollup.py` | ⚠ Partial | Framework present; summaries not yet connected. |

**84 unit tests passing.** 8 E2E scenarios verified: clean ingest, bad
samples, batch replay, route assembly, SQL query, change events.

## Running

```sh
# Unit + integration tests
pytest agent-a/tests/

# E2E with mock envelopes
./scripts/run_e2e.sh

# Real-time daemon
python -m collector.server

# Query the warehouse via stub Pilot
python -m coach query "SELECT type, COUNT(*) FROM samples GROUP BY type"
python -m coach readiness   # 7-day HRV average
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
  ],
  "metadata": {
    "location": {"lat": 47.61, "lon": -122.33, "accuracy_m": 12.5}
  }
}
```

Ack: `{batch_id, accepted: [...], duplicates: [...], rejected: [...]}`.
The iOS app advances its HealthKit anchor only after receiving this ack.

## Pilot ports

| Port | Direction | Message | Peer |
|---|---|---|---|
| 1001 | inbound | Envelope | iOS health-sync |
| 1002 | outbound | Ack | iOS health-sync |
| 1003 | bidirectional | SQL Query + QueryResult | Agent B, health-intelligence |
| 1004 | outbound | ChangeEvent | Agent B |

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

Single writer, MVCC reads. Agent B and health-intelligence query concurrently
without blocking ingest.

## G-Brain rollup

After each batch commit, `gbrain_rollup.py` derives a markdown summary of the
new data (e.g. "HRV trended down 9% over 5 nights, sleep median 6h") and
appends it to the shared G-Brain instance. Both agents share this memory;
patterns can be recalled semantically without re-querying raw DuckDB.

## Recoverability

- **Crash mid-batch:** DuckDB rolls back. Envelope not acked; iOS retries
  with same UUIDs. `INSERT OR IGNORE` absorbs the replay.
- **Disk full:** Insert fails, ack withheld, iOS outbox queues until disk
  recovers. Outbox is bounded by `CHUNKING.md` cap.
- **Consumer down:** Agent A keeps ingesting; ChangeEvents queue until
  consumers reconnect via Pilot.

## What's next

- `PilotctlTransport`: replace file-based test stub with real `pilotctl`
  subprocess calls for production overlay use.
- Source identity allowlist enforcement from config file.
- G-Brain rollup outputs wired to actual daily summaries.

## Where it fits

```
iPhone (health-sync)
    │  Pilot 1001 — encrypted envelope, NAT-traversed
    ▼
┌───────────────────────────────────┐
│  agent-a  (this directory)        │
│  Pilot 1001 ← envelopes           │
│  Pilot 1002 → acks                │
│  Pilot 1003 ↔ SQL query API       │
│  Pilot 1004 → change events       │
│  DuckDB  facts.duckdb             │
│  G-Brain rollup                   │
└──────────┬────────────────────────┘
           │ Pilot 1003 / 1004
     ┌─────┴─────────────────────────┐
     │                               │
  agent-b                    health-intelligence
  (GSuite ingest)             (RAG + ZeroEntropy)
```

See [`../README.md`](../README.md) for the full picture,
[`SCHEMA.md`](SCHEMA.md) for the wire format,
[`CHUNKING.md`](CHUNKING.md) for outbox/retry details.
