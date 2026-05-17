# Role contracts — Collector vs Coach

Two agents, two responsibilities, one wire protocol. This file is the
single source of truth for "who does what." When in doubt, defer here.

## Quick reference

|  | **Collector (agent-a)** | **Coach (agent-b)** |
|---|---|---|
| Tagline | the warehouse | the conversational front-end |
| Container | `g-stack-agent-a` (port 4001/udp Pilot) | `g-stack-agent-b` (port 4002/udp Pilot) |
| Owns DuckDB? | **Yes**, exclusive writer (`facts.duckdb` in Docker volume) | No — read-only via SQL query messages |
| Owns G-Brain? | `gbrain-collector-home` — factual observations | `gbrain-coach-home` — interpretations, nudges |
| LLM in the path? | Yes — OpenClaw agent (claude-opus-4-7) | Yes — OpenClaw agent (claude-opus-4-7) |
| Talks to user? | No human-facing surface | **Yes** — Telegram via OpenClaw channel binding |
| Talks to iOS? | Yes — receives envelopes, sends Acks back | No |
| Receives BINARY envelopes? | **Yes** (zlib + base64 decoded by `inbox_watcher`) | No |

## Pilot wire

All inter-node communication is one primitive: `pilotctl send-message <target-node-id> --data '<json>'`. The daemon delivers JSON to the target's `~/.pilot/inbox/` as a file. `inbox_watcher.py` classifies by **content shape**, not by port number.

```
   iPhone HealthSync          Collector (agent-a)             Coach (agent-b)
   ────────────────           ────────────────────            ────────────────
                              ← Envelope (samples array)
                              ← Query (sql field)  ──────────── send-message
                              → ChangeEvent (kind: samples_added) ──────────►
                              → Ack (to iPhone)
```

- **iPhone → Collector**: zlib-compressed JSON Envelope (base64 BINARY format), classified by presence of `samples` array. Collector dedupes by UUID, writes to DuckDB, sends Ack back.
- **Coach → Collector**: JSON with `sql` field. Collector's `sql_gate` executes read-only and sends `QueryResult` back. Correlated by `request_id`.
- **Collector → Coach**: `{kind: "samples_added", ...}` after each batch commit. Coach classifies by `kind` field.

Real Pilot built-in ports: 1001 (dataexchange/send-message), 7 (echo), 444 (handshake). The `reply_port: 1005` in query bodies is a correlation field, not a Pilot routing port.

## Collector — what it does

1. Polls `~/.pilot/inbox/` every 1 s; classifies messages by content shape.
2. Decompresses BINARY envelopes (`base64.b64decode` → `zlib.decompress`).
3. Validates against `agent-a/SCHEMA.md`.
4. Dedupes per-UUID against `facts.duckdb`; rejected samples carry a reason.
5. Sends an Ack back to the iPhone via `send-message` listing `accepted / duplicates / rejected`.
6. Emits a `{kind: "samples_added"}` ChangeEvent to the Coach via `send-message`.
7. Reassembles route chunks (workout GPS).
8. Executes read-only SQL queries from the Coach (sql_gate forbids writes).
9. OpenClaw LLM agent — can reason over its warehouse and write factual observations to its own G-Brain.

## Collector — what it does NOT do

- ❌ No LLM-driven nudging / coaching / interpretation
- ❌ No writes to the Coach's gbrain
- ❌ No `INSERT`/`UPDATE` on DuckDB from the SQL gate (writes only happen
  internally via the envelope pipeline)
- ❌ No Telegram surface

## Coach — what it does

1. Polls Pilot inbox for `{kind: "samples_added"}` ChangeEvents.
2. Runs 7 rule models against the Collector's DuckDB via SQL query messages.
3. Composes one Telegram nudge per (rule × cooldown) via OpenClaw channel binding.
4. Writes derived insights to **its own** G-Brain (`gbrain-coach-home`).
5. Pulls Google Calendar via OAuth; imports daily markdown into G-Brain.
6. Answers on-demand questions on Telegram — DuckDB + G-Brain recall + RAG evidence, ≤200 words.

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

- **Telegram** is the only user-facing interface. The Coach answers on the Telegram channel registered in the OpenClaw workspace (`coach-workspace/`).
- Proactive nudges fire from the Coach when a rule model triggers and cooldown has elapsed.
- The Collector has no human-facing surface — it is queried only by the Coach via `send-message`.

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
