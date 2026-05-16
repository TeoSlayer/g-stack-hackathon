# agent-a — Collector

The warehouse. Listens on Pilot for envelopes from any source (today: the
HealthSync iOS app), dedupes by sample UUID, writes to DuckDB, publishes a
"new facts" event so Agent B knows there's something to react to.

No LLM. No reasoning. No Telegram. Boring, durable, fast.

## Why a separate agent

Ingest has different SLOs than conversation: it must accept writes
continuously, never block on a slow reasoning step, restart cleanly, and
survive a crashed Coach without losing data. By splitting the warehouse off
from the chat agent, either side can be debugged, restarted, or rewritten
without touching the other. Coach treats Collector as just another tool.

## What it owns

| Concern | How |
|---|---|
| Receiving envelopes from sources | Pilot listener on port `1001` |
| Deduplication | sample UUID is the primary key in DuckDB; `INSERT OR IGNORE` |
| Durability | DuckDB file on disk (`~/.openclaw/workspace/health/facts.duckdb`) |
| Query API for Coach | Pilot port `1003`, SQL-string request → result-set reply |
| Change notification to Coach | Pilot port `1004`, emits `{table, new_count, since_ts}` after every batch commit |
| Acknowledgements | Pilot reply on the source's ack-port with the list of UUIDs accepted |

## The envelope format

Sources send length-prefixed JSON over Pilot port 1001:

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
      "source_name": "Apple Watch",
      "metadata": {"device": "Apple Watch Series 9"}
    }
  ],
  "metadata": {
    "location": {"lat": 47.61, "lon": -122.33, "accuracy_m": 12.5, "ts": 1701234560.0}
  }
}
```

Ack reply (Pilot back to source) carries the same `batch_id` and the array of
accepted UUIDs. Source advances its HK anchor only after the ack lands.

## DuckDB schema (sketch)

```sql
CREATE TABLE samples (
  uuid           VARCHAR PRIMARY KEY,
  source         VARCHAR  NOT NULL,
  device_id      VARCHAR  NOT NULL,
  type           VARCHAR  NOT NULL,
  value          DOUBLE,
  unit           VARCHAR,
  start_utc      DOUBLE   NOT NULL,
  end_utc        DOUBLE   NOT NULL,
  source_name    VARCHAR,
  metadata       JSON,
  ingested_utc   DOUBLE   NOT NULL DEFAULT epoch(current_timestamp)
);
CREATE INDEX samples_type_start ON samples (type, start_utc);

CREATE TABLE batches (
  batch_id       VARCHAR PRIMARY KEY,
  source         VARCHAR NOT NULL,
  device_id      VARCHAR NOT NULL,
  envelope_meta  JSON,
  ingested_utc   DOUBLE NOT NULL,
  sample_count   INTEGER NOT NULL
);
```

DuckDB is single-writer; the Collector serializes inserts. Reads (from Coach)
can run concurrently — DuckDB supports it.

## Why DuckDB

| Alternative | Why not |
|---|---|
| Postgres | Service to run + tune + back up. Overkill for one-writer analytical workload. |
| SQLite | No columnar storage; analytical aggregates over millions of HK samples get slow. |
| Parquet files | No transactional dedupe; you write the dedupe layer yourself. |
| Vector DB | Wrong shape — we want temporal range scans, not nearest-neighbour. |

DuckDB hits the sweet spot: one file on disk, columnar, transactional,
analytical, SQL, libraries in every language OpenClaw can shell out to.

## Recoverability story

- **Collector crashes mid-batch:** DuckDB transaction rolls back. Source's
  envelope isn't acked, so on its next retry the same UUIDs arrive again.
  `INSERT OR IGNORE` handles the dedupe.
- **Disk full:** Insert fails, no ack, source's outbox grows until disk
  comes back. Bounded by source's own outbox cap.
- **Schema migration:** DuckDB supports `ALTER TABLE`; one-shot migration
  script in `migrations/`. Sources don't care about Collector's schema.
- **Backup:** `cp facts.duckdb /backup/` while Collector is paused; or use
  DuckDB's online `COPY` to Parquet during a quiet window.

## Status

Not built yet. Phase 2 in the project plan.

Planned structure (when it lands):

```
agent-a/
├── README.md               this file
├── skill.json              OpenClaw skill manifest
├── src/
│   ├── ingest.ts           Pilot listener + envelope handler
│   ├── query.ts            SQL bridge for Coach
│   ├── events.ts           change-notification publisher
│   └── schema.sql          initial DuckDB schema
├── migrations/             SQL migrations, versioned
└── package.json
```

## Where it sits in the bigger picture

```
HealthSync iOS ──┐
                 │  Pilot 1001 (envelopes)
Future sources ──┤
                 ▼
            ┌─────────────────────────────┐
            │  agent-a (this directory)   │
            │  ─────────────────────────  │
            │  Pilot 1001 ← envelopes     │
            │  Pilot 1003 → query API     │
            │  Pilot 1004 → change events │
            │  DuckDB on disk             │
            └────────────┬────────────────┘
                         │
                         │ Pilot 1003 + 1004
                         ▼
                   agent-b (Coach)
```

See [../README.md](../README.md) for the full project, [../agent-b](../agent-b)
for the conversational front-end, and [../infra](../infra) for the shared
setup (DuckDB location, Pilot trust bootstrap, gbrain init).
