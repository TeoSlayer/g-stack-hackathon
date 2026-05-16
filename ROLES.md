# Role contracts — Collector vs Coach

Two agents, two responsibilities, one wire protocol. This file is the
single source of truth for "who does what." When in doubt, defer here.

## Quick reference

|  | **Collector (agent-a)** | **Coach (agent-b)** |
|---|---|---|
| Tagline | the warehouse | the second-brain front-end |
| Pilot node | `193232` (`g-stack-agent-a`, `0:0000.0002.F2D0`) | `193233` (`g-stack-agent-b`, `0:0000.0002.F2D1`) |
| Container | `g-stack-agent-a` | `g-stack-agent-b` |
| Pilot endpoint | `35.224.83.34:4001` | `35.224.83.34:4002` |
| Owns DuckDB? | **Yes**, exclusive writer | No — read-only via Pilot |
| Owns gbrain? | Its own at `gbrain-collector-home/` | Its own at `gbrain-coach-home/` |
| LLM in the path? | Yes (claude-opus-4-7) for chat | Yes (claude-opus-4-7) for chat |
| Talks to user? | **Yes** (you talk to Collector) | Background — only fires nudges and is queried by Collector |
| Talks to iOS? | Yes (port 1001 envelopes) | No |
| Receives BINARY envelopes? | **Yes** (zlib + base64 decoded by `inbox_watcher`) | No |

## Pilot wire

```
   iPhone HealthSync          Collector (agent-a)             Coach (agent-b)
   ────────────────           ────────────────────            ────────────────
                              port 1001 ← Envelope            
                              port 1003 ← Query  ──────────── send Query
                              port 1004 → ChangeEvent ──────► subscribe

                              port (envelope.ack_port)
                              ────────► Ack
```

- **Source (iPhone) → Collector**: zlib-compressed JSON Envelope, base64 in
  Pilot BINARY message, on port 1001. Collector dedupes by sample UUID,
  writes to DuckDB, emits ChangeEvent.
- **Collector ↔ Coach**: SQL request/reply over Pilot ports 1003 / dynamic
  reply_port. The Coach has read-only access via the SQL gate (writes are
  rejected).
- **Coach ← ChangeEvent**: fire-and-forget broadcast from Collector after
  each batch commit. Coach uses it as a "go look again" hint.

## Collector — what it does

1. Listens for Pilot Envelopes on port 1001 (handles JSON + BINARY).
2. Decompresses BINARY envelopes (`base64.b64decode` → `zlib.decompress`).
3. Validates against `agent-a/SCHEMA.md`.
4. Dedupes per-UUID against DuckDB; rejected samples carry a reason.
5. Sends an Ack to `envelope.ack_port` listing `accepted / duplicates / rejected`.
6. Emits a `ChangeEvent` (`samples_added`) on port 1004 with the
   per-type histogram.
7. Reassembles route chunks (workout GPS).
8. Serves read-only SQL on port 1003 (the gate forbids writes).
9. When a human talks to it: queries warehouse + its own gbrain, returns a
   factual answer, can write observations to **its own** gbrain.

## Collector — what it does NOT do

- ❌ No LLM-driven nudging / coaching / interpretation
- ❌ No writes to the Coach's gbrain
- ❌ No `INSERT`/`UPDATE` on DuckDB from the SQL gate (writes only happen
  internally via the envelope pipeline)
- ❌ No Telegram surface

## Coach — what it does

1. Subscribes to ChangeEvents on port 1004.
2. Runs the seven rule models against the warehouse via SQL queries.
3. Composes one Telegram nudge per (rule × cooldown).
4. Writes derived insights to **its own** gbrain.
5. Calls Pilot specialists for external context (weather, transit, etc.).

## Coach — what it does NOT do

- ❌ No raw envelope ingestion (iOS never sends to it)
- ❌ No DuckDB writes (gate forbids)
- ❌ No writes to the Collector's gbrain

## gbrain isolation

Two PGLite DBs, two MCP servers, two CLI wrappers. The agents share the
calendar seed at install time and diverge from there. The OpenClaw
gateway exposes both MCP servers globally — but each agent's IDENTITY
prescribes which namespace is theirs:

| Agent | Allowed MCP namespace | Forbidden namespace |
|---|---|---|
| Collector | `gbrain-collector` | `gbrain-coach` |
| Coach | `gbrain-coach` | `gbrain-collector` |

There is no mechanical enforcement (yet); it's an agent-instruction rule.

## How the user interacts

- Default channel: `openclaw agent --agent collector --local --message …`
  via the `claw` shell function in `~/.zshrc`.
- For background work: the Coach runs `python -m coach watch` inside its
  container, drains ChangeEvents, fires nudges.

## Why this split exists

- **Ingest has different SLOs than conversation.** Envelope acks must
  return inside 30 s or the iOS outbox treats them as lost; LLM turns
  routinely take 5–20 s. Splitting prevents conversation latency from
  blocking ingest.
- **Trust scoping.** The Collector accepts writes from sources; the
  Coach is read-only over Pilot. Mixing identities mixes trust.
- **Restart isolation.** Either agent can crash without dropping the
  other's work — the wire protocol bridges them.

See:
- `agent-a/SCHEMA.md` — envelope / ack / query / change-event wire format
- `agent-a/CHUNKING.md` — iOS outbox + retry strategy
- `LIFECYCLE.md` — boot order, recovery, failure-mode table
- `IMPLEMENTATION.md` — current code map
