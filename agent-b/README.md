# agent-b — Coach

The front. The agent you actually talk to. Receives Telegram messages, calls
tools (Agent A's data, gbrain memory, gstack skills, Pilot specialists),
composes an answer, replies. Also runs a pro-active rule loop that pings you
when one of the seven models trips a band.

## Why a separate agent

Conversation has different needs than ingest: bursty, compute-heavy (an LLM
turn), can take seconds, and gets restarted whenever the LLM provider or
prompt changes. Splitting the chat agent off from the warehouse keeps Agent A
small, fast, and uncontaminated by LLM concerns.

Coach is the only thing in this system that talks to you. It's also the only
thing that talks to external services (Telegram, optionally hosted LLMs,
Pilot specialists). Concentrating outbound surface in one component bounds
the trust audit.

## What it owns

| Concern | How |
|---|---|
| Telegram conversation | OpenClaw's built-in Telegram channel adapter |
| LLM turn | OpenClaw's model layer (default: whatever you configured in `openclaw onboard`) |
| Reading user data | Tool: `query_collector(sql)` → Pilot port 1003 on Agent A |
| Reacting to new data | Subscriber on Pilot port 1004 (Agent A's change events) |
| Long-term recall | Tool: `gbrain_search(query)`, `gbrain_write(note)` via MCP |
| Multi-step reasoning | Tool: `gstack_run(skill, args)` shells out to `~/Development/openclaw/...` skills |
| External context | Tool: `pilot_specialist(name, query)` (~436 public agents on the overlay) |
| Pro-active nudges | Cron-style rule loop running the 7 models against Collector |
| Rate limiting | Per-rule cooldown (e.g. one wear-watch reminder per 4 h) + global mute via `/mute` Telegram command |

## Tool surface

The LLM sees these as native tools at every turn:

```
query_collector(sql: string) -> { rows: [...], schema: {...} }
   Read-only SQL against Agent A's DuckDB. The LLM composes the query.

gbrain_search(query: string, k?: int) -> [{ note, ts, score }]
   Semantic search over past summaries, observed patterns, user-flagged facts.

gbrain_write(note: string, tags?: [string]) -> { id }
   Persist a new fact / summary for future recall. Only Coach writes here —
   one voice keeps the brain coherent.

gstack_run(skill: string, args: object) -> { stdout, stderr, exit_code }
   Spawn an opinionated reasoning skill. E.g. gstack_run("investigate",
   {topic: "HRV crashed last Tuesday"}) → multi-step probe.

pilot_specialist(name: string, query: string) -> object
   Ask a Pilot directory specialist. E.g. weather, transit, dev metadata.
   Encrypted, identity-routed, no API keys.
```

## Pro-active rule loop

Runs every N minutes (default 15). For each rule:

1. Pull required data from Agent A (`query_collector`).
2. Compute the model (sleep regularity, autonomic balance, sedentary stress,
   cognitive recovery debt, burnout CUSUM, circadian drift, kalman HRV).
3. If band is `.warn` or `.bad` AND cooldown for this rule has expired:
   - compose a one-sentence Telegram message
   - send via Telegram channel
   - `gbrain_write` the nudge so we have history
   - stamp the cooldown timestamp

User can `/snooze 4h` any rule by replying to its message.

## Conversation examples

```
You:    how was my sleep this week
Coach:  Median 6h 12m, two nights under 5h (Tue, Thu). Your trailing-7d HRV is
        down 9% — looks like the short nights are the proximate cause.
        Want to look at when the late nights started?

You:    yes
Coach:  Bedtimes drifted later starting Sunday. Mann-Kendall p=0.03 on the
        last 14 nights — that's a real drift, not noise. The model says
        circadian drift; the fix is a fixed lights-out time.

You:    did this happen in march
Coach:  [searches gbrain] Yes — similar 2-week window in March, you flagged
        it as "post-launch crunch." HRV recovered the week after you cut
        evening screens. Want me to remind you of the protocol?
```

## Why OpenClaw and not custom

OpenClaw already does:

- Channel adapters (Telegram, plus Signal/Matrix/Slack/Discord/iMessage if
  you outgrow Telegram — same skill, different transport)
- LLM model selection + fallback (OAuth ChatGPT/Codex, API keys, local
  llama.cpp via the same interface)
- Tool calling + thread state + per-user message routing
- Process isolation per skill, daemon-managed restarts

If we wrote Coach from scratch we'd reimplement all of that. OpenClaw is the
substrate; Coach is a ~200-line skill on top.

## Recoverability story

- **Coach crashes mid-conversation:** OpenClaw restarts the skill. Thread
  state is in OpenClaw's session store; conversation resumes. The user's
  message is replayed if it was unacked.
- **Telegram unreachable:** Outbound replies fail; OpenClaw retries. User
  sees silence until Telegram recovers. Pro-active nudges that fire during
  outage are written to gbrain so they survive.
- **LLM provider down:** OpenClaw's model failover picks an alternate; if
  none available, Coach replies with a degraded "checking back in a few min"
  message instead of silence.
- **Agent A down:** `query_collector` returns an error; Coach tells the
  user the warehouse is offline rather than hallucinating data.

## Status

Not built yet. Phase 3 in the project plan, after Agent A is up.

Planned structure (when it lands):

```
agent-b/
├── README.md
├── skill.json               OpenClaw skill manifest
├── src/
│   ├── coach.ts             main skill: message handler + LLM glue
│   ├── tools/
│   │   ├── query-collector.ts
│   │   ├── gbrain.ts
│   │   ├── gstack.ts
│   │   └── pilot-specialist.ts
│   ├── rules/               pro-active rule loop
│   │   ├── sleep-regularity.ts
│   │   ├── autonomic-balance.ts
│   │   ├── sedentary-stress.ts
│   │   ├── cognitive-debt.ts
│   │   ├── burnout-cusum.ts
│   │   ├── circadian-drift.ts
│   │   └── kalman-hrv.ts
│   └── prompts/             system + rule-specific prompt templates
└── package.json
```

The seven rule files port the on-device models (currently in
`../health-sync/HealthSync/Models.swift`) to TypeScript so they can run
against Agent A's DuckDB.

## Where it sits in the bigger picture

```
                   You
                    ▲
                    │  Telegram
                    ▼
            ┌─────────────────────────────┐
            │  agent-b (this directory)   │
            │  ─────────────────────────  │
            │  OpenClaw skill             │
            │  Tools: query, gbrain,      │
            │          gstack, specialists│
            │  Rule loop on a schedule    │
            └─────┬───────────────────────┘
                  │
                  │ Pilot 1003 (query)
                  │ Pilot 1004 (events)
                  ▼
              agent-a (Collector)
```

See [../README.md](../README.md) for the full project, [../agent-a](../agent-a)
for the warehouse, and [../infra](../infra) for the shared setup.
