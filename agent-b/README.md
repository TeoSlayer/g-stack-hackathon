# agent-b — GSuite Ingest

Pulls data from Google Workspace (Calendar, Drive, Gmail) via OAuth, warehouses
it to DuckDB, and keeps a G-Brain rollup in sync with Agent A's health data.
Speaks to Agent A over Pilot Protocol for cross-source reasoning.

No LLM at the ingest layer. The ingest worker is durable and stateless;
reasoning happens above it.

## What it owns

| Concern | How |
|---|---|
| Google Calendar pull | OAuth 2.0 refresh token; incremental sync via `nextSyncToken` |
| Google Drive pull | Changed-files feed; metadata + plain-text extraction |
| Gmail pull | Label-filtered threads; sender + subject + snippet |
| Warehousing | DuckDB tables: `calendar_events`, `drive_files`, `gmail_threads` |
| Cross-source queries | Pilot port `1003` on Agent A — read-only SQL access to health samples |
| Change notifications | Listens on Pilot port `1004` from Agent A for health ChangeEvents |
| Long-term memory | G-Brain rollup: daily summaries written to shared gbrain instance alongside Agent A's health summaries |

## Why this agent exists

Health data alone is partial. Knowing that HRV dropped 15% is useful; knowing
it dropped on a week with 14 calendar events, a flight, and no recovery day is
actionable. Agent B brings the scheduling and context layer. Both agents write
to the same G-Brain so a reasoning step can pull "what was happening that week"
without joining across two separate systems.

## Why Pilot for agent-to-agent links

Both agents run on the homelab. Pilot gives them encrypted, identity-verified
channels to each other with no shared socket, no auth token, no internal HTTP
routing table. Agent B subscribes to Agent A's change events on port 1004;
Agent A queries Agent B's data on port 1003. Either agent can restart without
the other noticing beyond a brief reconnect.

## Status: spec + framework

| Concern | Status |
|---|---|
| `client.py` — query Agent A via Pilot | ✓ Done |
| `__main__.py` — CLI: `coach query`, `coach watch`, `coach readiness` | ✓ Done |
| `gbrain_rollup.py` — daily summary framework | ⚠ Partial (framework, not yet wired) |
| GSuite OAuth pull | ✗ Not yet built |
| Calendar / Drive / Gmail warehouse tables | ✗ Not yet built |
| G-Brain write from rollup | ✗ Not yet built |

## Running (what works today)

```sh
# Query Agent A's health warehouse
python -m coach query "SELECT type, COUNT(*) FROM samples GROUP BY type"

# Subscribe to Agent A's change events
python -m coach watch

# 7-day HRV readiness
python -m coach readiness
```

These work because `client.py` is complete. GSuite pull is the next phase.

## Planned data tables

```sql
-- calendar_events
CREATE TABLE calendar_events (
  event_id     VARCHAR PRIMARY KEY,
  calendar_id  VARCHAR NOT NULL,
  title        VARCHAR,
  start_utc    DOUBLE  NOT NULL,
  end_utc      DOUBLE,
  all_day      BOOLEAN,
  attendees    INTEGER,
  location     VARCHAR,
  synced_utc   DOUBLE  NOT NULL
);

-- drive_files
CREATE TABLE drive_files (
  file_id      VARCHAR PRIMARY KEY,
  name         VARCHAR NOT NULL,
  mime_type    VARCHAR,
  modified_utc DOUBLE,
  owner        VARCHAR,
  shared       BOOLEAN,
  snippet      TEXT,
  synced_utc   DOUBLE  NOT NULL
);

-- gmail_threads
CREATE TABLE gmail_threads (
  thread_id    VARCHAR PRIMARY KEY,
  subject      VARCHAR,
  sender       VARCHAR,
  snippet      TEXT,
  labels       JSON,
  date_utc     DOUBLE  NOT NULL,
  synced_utc   DOUBLE  NOT NULL
);
```

## G-Brain rollup

After each GSuite sync pass, `gbrain_rollup.py` writes a markdown summary
of the day's scheduling context ("3 back-to-back calls, travel block
7–10 Jun, 2 late-night emails sent after 22:00") to the shared G-Brain
instance. Agent A writes health summaries to the same store. Cross-source
reasoning — "HRV dropped on weeks with dense calendars" — is then a semantic
G-Brain query, not a join.

## Pilot ports

| Port | Direction | Message | Peer |
|---|---|---|---|
| 1003 | outbound | SQL Query | Agent A |
| 1003 | inbound | QueryResult | Agent A |
| 1004 | inbound | ChangeEvent (health data) | Agent A |

## What's next

1. Google OAuth flow + refresh token persistence (`.env` + infra secrets)
2. Incremental Calendar pull with `nextSyncToken`
3. Drive changed-files feed with plain-text extraction
4. Gmail label-filtered thread sync
5. DuckDB schema + ingestion for all three sources
6. G-Brain rollup outputs wired to actual daily summaries

## Where it fits

```
Google Workspace (OAuth pull)
    │
    ▼
┌───────────────────────────────────┐
│  agent-b  (this directory)        │
│  OAuth ← GSuite incremental sync  │
│  Pilot 1003 → query Agent A       │
│  Pilot 1004 ← health ChangeEvents │
│  DuckDB  gsuite.duckdb            │
│  G-Brain rollup                   │
└──────────┬────────────────────────┘
           │ Pilot
     ┌─────┴─────────────────────────┐
     │                               │
  agent-a                    health-intelligence
  (health ingest)             (RAG + ZeroEntropy)
```

See [`../README.md`](../README.md) for the full picture and
[`../infra`](../infra) for the shared setup (Pilot identity, G-Brain path,
DuckDB locations, OAuth credentials).
