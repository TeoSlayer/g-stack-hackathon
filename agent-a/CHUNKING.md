# Chunking, outbox, and retry strategy

Pilot's datagram payload is capped at **65,535 bytes** per `pilot.send`. Any
serious HK sync — first-launch backfill, large workouts, deep history walks —
exceeds that easily. The strategy below ships everything reliably while
staying on the simple datagram path (no streaming, no fragmentation magic).

## The shape

```
                                ┌──────────────────────────────┐
HKAnchoredObjectQuery page ───► │ Splitter                     │
(up to 1000 samples)            │  greedy fill ≤ 200 KB raw    │
                                │  flush → envelope            │
                                └────────────┬─────────────────┘
                                             │  1..N envelopes,
                                             │  shared anchor_marker
                                             ▼
                                ┌──────────────────────────────┐
                                │ OutboxStore (SQLite, atomic) │
                                │  rows = envelopes            │
                                │  state = pending|sending|    │
                                │          acked               │
                                └────────────┬─────────────────┘
                                             │
                                             ▼
                                ┌──────────────────────────────┐
                                │ OutboxWorker                 │
                                │  one in flight at a time     │
                                │  gzip → pilot.send → ack     │
                                │  backoff on failure          │
                                └────────────┬─────────────────┘
                                             │
                              ┌──────────────┴───────────────┐
                              │                              │
                              ▼                              ▼
                  all envelopes for                 envelope failed,
                  anchor_marker acked →             stays pending,
                  advance HK anchor,                retry on next tick
                  delete envelopes
```

## Why this layout

1. **Splitting is a pure function.** Given a sample list and a budget, the
   envelopes are deterministic. No I/O during splitting; no side effects.
2. **The outbox is the source of truth for "what's been sent".** Once
   envelopes are persisted there, the rest of the pipeline can crash
   anywhere — restart drains from the same rows.
3. **HK anchor advances only when a whole page is durable.** Pages map 1:N
   to envelopes; the `anchor_marker` ties them together. Partial-page
   acks don't lose data — they just leave one envelope retrying.
4. **Strictly synchronous, one envelope at a time, with deliberate pacing.**
   Pilot's datagram path degrades under rapid-fire — packets can drop,
   acks can get lost, the registry buffers more than it likes. We send
   one envelope, *wait for its ack*, *sleep a fixed pacing interval*, then
   send the next. No pipelining, no concurrency, no batched send loops.
   This is the load-bearing decision; everything else assumes it.

> **Speed is not a goal.** Health data is not time-sensitive at the
> envelope level — a sample that lands two minutes late is still a sample
> that lands. We trade throughput for reliability. A multi-hour backfill
> that completes without intervention beats a 10-minute backfill that
> needs a retry script.

## Budgets and ratios

Measured against the schema in [`SCHEMA.md`](SCHEMA.md):

| Element | Bytes (JSON) |
|---|---|
| Quantity sample, no per-sample location | ~300 |
| Quantity sample, with `location` | ~430 |
| Category sample with stage metadata | ~350 |
| Workout header (no route) | ~400 |
| Route point `[lat, lon, ele, ts, speed]` | ~55 |
| Envelope wrapper | ~250 |

Gzip ratio on this kind of repetitive JSON: **5–8×**.

**Splitter budget: 200 KB raw JSON per envelope.** Compresses to ~25–40 KB.
Leaves 25 KB of headroom under Pilot's 65 KB limit.

At 350 bytes/sample average, 200 KB ≈ **570 samples per envelope**.

For a paranoid floor, the iOS side enforces a hard cap of **800 samples per
envelope** even if the size budget would allow more. Catches the edge case
where the gzip ratio is bad (e.g. samples with many unique source bundle ids).

## Envelope identity and grouping

Each envelope:

| Field | Value | Why |
|---|---|---|
| `envelope_id` | UUIDv4 generated at split time | Idempotency key on retry |
| `anchor_marker` | UUIDv4 shared across envelopes from the same HK page | Lets Collector — and iOS — know when "all of this page" is durable |
| `page_anchor` | The HK `HKQueryAnchor` to commit after success | iOS stores it on each envelope so any envelope's row carries the recovery info |

`anchor_marker` and `page_anchor` are iOS-internal; they don't go on the
wire. The Collector only sees `batch_id` (= `envelope_id` here) and the
samples themselves.

## OutboxStore (iOS, SQLite)

```sql
CREATE TABLE outbox_envelopes (
    envelope_id      TEXT    PRIMARY KEY,
    anchor_marker    TEXT    NOT NULL,
    page_anchor      BLOB    NOT NULL,
    payload          BLOB    NOT NULL,    -- gzipped envelope JSON, ready to send
    sample_uuids     TEXT    NOT NULL,    -- JSON array, for ack matching
    state            TEXT    NOT NULL,    -- 'pending' | 'sending' | 'acked'
    attempts         INTEGER NOT NULL DEFAULT 0,
    last_attempt_at  REAL,                -- epoch s
    last_error       TEXT,                -- short tag from previous failure
    created_at       REAL    NOT NULL,
    bytes_compressed INTEGER NOT NULL,
    bytes_raw        INTEGER NOT NULL
);

CREATE INDEX outbox_state_created ON outbox_envelopes(state, created_at);
CREATE INDEX outbox_anchor        ON outbox_envelopes(anchor_marker);
```

Writes are wrapped in transactions — either all envelopes from one page land
together, or none do. The HK anchor never advances unless every row for that
`anchor_marker` is `acked`.

## Splitter algorithm

```
fn split(samples: [HealthEvent], pageAnchor: Data) -> [OutboxEnvelope]:
    marker = UUID()
    envelopes = []
    current = []
    current_size = 0
    BUDGET = 200 * 1024     // raw bytes
    HARD_CAP = 800          // samples

    fn flush():
        if current is empty: return
        body = WireEnvelope(samples=current, batch_id=UUID()).to_json()
        compressed = gzip(body)
        if compressed.len > 60_000:
            // pathological case (very low gzip ratio). Halve and recurse.
            mid = current.len // 2
            tmp = current.suffix(from: mid)
            current = current.prefix(mid)
            flush()
            current = tmp
            flush()
            return
        envelopes.push(OutboxEnvelope(
            envelope_id = body.batch_id,
            anchor_marker = marker,
            page_anchor = pageAnchor,
            payload = compressed,
            sample_uuids = current.map(.uuid),
            state = 'pending',
            bytes_raw = body.len,
            bytes_compressed = compressed.len
        ))
        current = []
        current_size = 0

    for s in samples:
        estimated = estimate_size(s)   // 300–430 bytes typical
        if (current_size + estimated > BUDGET or current.len >= HARD_CAP) and current not empty:
            flush()
        current.append(s)
        current_size += estimated
    flush()

    return envelopes
```

`estimate_size` is conservative (uses upper bound per field) so we never
overshoot the budget by surprise. The "pathological halve and recurse" guard
catches any case where the estimate undershoots reality.

## OutboxWorker draining

The worker is a single, **synchronous, paced** loop. Pseudocode:

```
PACING_INTERVAL = 1.5 s         // mandatory wait between successful sends
ACK_TIMEOUT     = 30  s
PILOT_WARMUP    = 0.25 s        // short settle after pilot.send returns before
                                 // we start the ack wait

loop:
    env = OutboxStore.next(state='pending', orderBy='created_at asc')
    if env is null:
        sleep(5 s); continue

    // Don't even try if Pilot isn't healthy
    if PilotBoot.state != .running:
        sleep(2 s); continue

    OutboxStore.update(env.id, state='sending', last_attempt_at=now)

    try:
        pilot.send(to: collector_addr, port: 1001, data: env.payload)
        sleep(PILOT_WARMUP)
        ack = await pilot.awaitAck(port: 1002, batch_id: env.id, timeout: ACK_TIMEOUT)

        if ack.batch_id == env.id and all of env.sample_uuids in ack.accepted + ack.duplicates:
            OutboxStore.update(env.id, state='acked')
            if OutboxStore.allAckedForAnchorMarker(env.anchor_marker):
                HKAnchorStore.commit(env.page_anchor, type)
                OutboxStore.deleteAllForAnchorMarker(env.anchor_marker)

            // The deliberate pacing — DO NOT skip this even when the outbox
            // has a backlog. Pilot needs the breathing room.
            sleep(PACING_INTERVAL)
        else:
            // mixed result — treat as partial failure
            mark_partial(env, ack)
            sleep(backoff(env.attempts))
    catch (timeout | network):
        OutboxStore.update(env.id,
            state='pending',
            attempts=env.attempts + 1,
            last_error='timeout')
        sleep(backoff(env.attempts))
```

### Invariants the worker enforces

| Invariant | How |
|---|---|
| **No two sends concurrent** | Single coroutine; no `Task.detached` parallelism inside the loop |
| **No send before ack** | `await pilot.awaitAck(...)` is a hard sync point; the next iteration cannot begin until it returns |
| **Minimum interval between successful sends** | `sleep(PACING_INTERVAL)` after every commit. The Pilot daemon gets a guaranteed quiet window between bursts. |
| **No work when Pilot is unhealthy** | The `PilotBoot.state == .running` check; otherwise idle until the daemon recovers |
| **FIFO across all envelopes** | `ORDER BY created_at ASC` on every fetch. A new HK observer firing mid-drain just appends; it can't jump the queue. |

### Tuning the pacing

`PACING_INTERVAL` is **1.5 s by default**. It's set as `OutboxWorker.pacingInterval`
on iOS and adjustable in `infra/.env`. Reasoning:

- ≤ 0.5 s: observed packet loss / dropped acks under Pilot load. **Avoid.**
- 1.0 s: borderline; OK for steady state, occasional retries during backfill
- **1.5 s: chosen default; comfortable margin in every test scenario**
- 2.0–3.0 s: deliberate "tortoise" mode; for unreliable links or remote
  backfills run with the screen off

A future adaptive mode could shrink the interval when N consecutive sends
succeed in <5 s round-trip and grow it when round-trips creep above 10 s.
For v1 keep it fixed — adaptive pacing is exactly the kind of cleverness
that bites you at 3 am.

### Real-world rate

At 1.5 s pacing with ~30 KB gzipped envelopes:

| Workload | Throughput | Wall-clock |
|---|---|---|
| Steady-state daily sync (~50 envelopes/day on a wrist that lives on you) | trivial — outbox is empty most of the time | ms per event |
| Hourly catchup after WiFi reconnect | ~3–10 envelopes drain in 5–15 s | seconds |
| First-launch backfill, 3 years of HK data (~5 M samples → ~10 000 envelopes) | ~40 envelopes/min | ~4 h |
| Pathological all-types deep history (~50 000 envelopes) | ~40 envelopes/min | ~20 h, runs across several foreground sessions and BG-task wakes |

The 4 h backfill happens once, in pieces, in the background, drained
across foregrounds and BG-task wakes. The user never blocks on it; they
see partial readiness immediately because models read HK directly while
the outbox drains in parallel.

## Backoff schedule

```
attempts → sleep
1     → 5 s
2     → 15 s
3     → 30 s
4     → 60 s
5     → 120 s
6+    → 300 s  (cap)
```

No max-attempts cutoff. HK data isn't urgent enough to drop on the floor;
we'd rather hold it until the network recovers. Eviction (below) handles
the worst case.

## Eviction (bounded outbox)

If the outbox grows past **200 MB total compressed payload** (~6 600
envelopes; weeks of data), evict oldest envelopes first:

```
while OutboxStore.totalBytesCompressed() > 200 * 1024 * 1024:
    oldest = OutboxStore.next(orderBy='created_at asc')
    log.warning("outbox eviction: env=%s age=%s anchor=%s samples=%d",
                oldest.id, now - oldest.created_at, oldest.anchor_marker,
                oldest.sample_uuids.length)
    // Force-advance the HK anchor for this group so we don't re-fetch
    // and re-evict the same samples next sync.
    HKAnchorStore.commit(oldest.page_anchor, type)
    OutboxStore.deleteAllForAnchorMarker(oldest.anchor_marker)
```

Evicted samples are lost. Surface a Notification on the iOS device if any
eviction happens in a 24-hour window — the user should know.

## Workout routes — separate flow

A workout's route can blow past the 200 KB budget on its own (5 000 GPS
points × 55 bytes ≈ 275 KB raw). Handled outside the sample splitter:

1. **Workout header** rides as a normal sample (kind: `"workout"`) inside
   the regular envelope flow. ~400 bytes; trivial.
2. **Route is split into `route_chunks`** — each chunk is its own envelope
   of `kind: "route_chunk"`, max 1500 points per chunk (~83 KB raw → ~12 KB
   gzipped). Schema is in `SCHEMA.md`.
3. All route_chunks share an `anchor_marker` with the workout header so
   they commit together. If one chunk fails to ack, the workout header is
   ack-able but the anchor doesn't advance until all chunks land.
4. Collector reassembles route_chunks by `workout_uuid` + `chunk_idx`;
   stores complete routes in DuckDB once `chunk_total` chunks have arrived.

Future: switch route uploads to Pilot stream-mode (`pilot.dial`) for routes
> 5 000 points. v1 stays on datagrams.

## Backfill window — only what we actually analyse

Don't backfill years of history. The analysis the system performs has a
finite horizon; sending data older than that is pure overhead. The
on-device iOS app already declares its windows; the Collector uses the same
ceiling.

### Analysis-window coverage map

| Component | Reads back | Notes |
|---|---|---|
| Readiness baseline | 7 days | overnight HRV vs 7-day median |
| Cognitive Recovery Debt | 7 days | EWMA over last week |
| Sleep Regularity Index | 14 days | pairwise minute-state matrix |
| Autonomic Balance | 14 days | z(HRV) − z(RHR) over 14 d |
| Sedentary Stress | 14 days | RHR baseline window |
| Circadian Drift (Mann-Kendall) | 14 days | bedtime trend |
| Kalman-smoothed HRV | 30 days | state-space window |
| Trends (HRV/RHR/Sleep/Steps) | 30 days | daily aggregates + Holt forecast |
| Calendar grid | 35 days | 5-week heat-cells |
| Burnout CUSUM | **60 days ideal** | works degraded at 14+; full quality at 60 |
| Location heatmap | **90 days default**, configurable 7–365 | user can dial up |

### The default: 30 days

```
BACKFILL_WINDOW_DAYS = 30
```

Covers every on-device model + Trends + Calendar at full quality. CUSUM and
the Heatmap accept the trade-off:

- **CUSUM** computes against whatever window it has. At 30 days the
  reference half is 15 days — workable, with a higher false-alarm rate.
  As the system runs, more data accumulates and CUSUM sharpens.
- **Heatmap** caps at 30 days for the initial backfill, then grows
  forward as new location-tagged samples flow in. After three months of
  daily use, the user has the full 90-day default's worth of data.

This is a 30× reduction over an unbounded historical backfill, and ~3× over
the 90-day option.

### How the bound is enforced

iOS-side `anchoredQuery` adds a date predicate to every HK query — not
just the first one:

```swift
let cutoff = Date().addingTimeInterval(-Double(BACKFILL_WINDOW_DAYS) * 86400)
let predicate = HKQuery.predicateForSamples(
    withStart: cutoff,
    end:       nil,
    options:   .strictStartDate
)
HKAnchoredObjectQuery(type: t, predicate: predicate, anchor: savedAnchor, limit: pageSize) { … }
```

The predicate is permanent, not just for the first run. As "now" advances,
the window slides forward; samples that age out simply stop being reported
(we already shipped them when they were fresh). The HK anchor handles
"what's new" correctly within the predicate's scope.

### Real-world backfill rates with the 30-day bound

For a typical user wearing the Watch ~12 h/day:

| Type | ~Samples in 30 days |
|---|---|
| Heart rate (~5–10 min cadence when sedentary, ~5 s during workouts) | 5 000 – 25 000 |
| HRV (SDNN) | 100 – 400 |
| Resting HR | 30 |
| Respiratory rate | 200 – 600 |
| Steps (per-bucket) | 1 500 – 3 000 |
| Distance / Energy / Stand / Exercise | 1 000 – 3 000 each |
| Workouts | 5 – 30 |
| Sleep stages | 100 – 200 |
| Other (BodyTemp, VO2Max, BodyMass, etc.) | < 200 |
| **Total** | **~15 000 – 40 000 samples** |

At 500 samples per envelope → **30–80 envelopes**.
At 1.5 s pacing → **45 s – 2 min wall time**.

A heavy user with continuous workout HR could hit 80 000 samples → ~160
envelopes → ~4 minutes. Still trivial vs. the 4-hour 3-year backfill.

### Opt-in deep backfill

For a user who wants their full HK history available to the Coach (e.g.
"how did my HRV compare to last winter?"), expose a Settings toggle:

```
Settings → Storage → Deep historical sync
   ☐  Enabled (default off)
   Window: [ 30 ] days
   [ Run backfill now ]
```

Setting this to e.g. 730 days and tapping the button triggers one
unbounded `HKAnchoredObjectQuery` with the wider predicate. The same
splitter + outbox + pacing apply; backfill just takes longer (hours,
spread across foreground sessions). The system goes back to the 30-day
rolling window for ongoing sync once the historical pull completes.

### Edge case: long offline period

If iOS is offline for **N > BACKFILL_WINDOW_DAYS** days, samples added to
HK during that gap that aged outside the window before iOS came back will
be missed. For N=30, that requires being completely offline for 30+ days
on the home network — unusual. The "Deep historical sync" button is the
recovery for this case.

We could detect it (last successful ack > 25 days ago → bump the window
temporarily) but won't in v1 — keep the rule simple.

## What the Collector sees

Each envelope arrives as if it were independent. The Collector doesn't know
about `anchor_marker` or splitting — that's an iOS-internal invariant.

Collector's contract:

- Each envelope's `batch_id` is unique. `INSERT OR IGNORE` on the `batches`
  table catches replays.
- Each sample's `uuid` is the dedupe key on `samples`. Replays land as
  duplicates — counted in the ack and otherwise no-ops.
- Ack reply includes the per-sample disposition (accepted / duplicate /
  rejected). iOS uses those to decide whether the envelope row can be
  marked `acked`.
- An envelope where ALL samples are duplicates is still a success for
  iOS's purposes; the outbox row marks `acked` and gets cleaned up.

## What we don't do (and why)

- **No multi-envelope reassembly.** Each datagram is atomic on the wire.
  Splitting an envelope into smaller ones to get under the 65 KB limit is
  done at the sample-stream layer, not the transport layer. The Collector
  only sees self-contained envelopes.
- **No streams in v1.** Streams hide acks and complicate the outbox model
  (where does "I sent half a stream" land?). v1 uses datagrams everywhere
  except for the route-chunks-overflow path (still datagrams, just split).
- **No client-side compression negotiation.** Always gzip. Wire is one
  format. Saves 5 lines of code at every endpoint.
- **No parallel sends. Ever.** Two in flight gives ~2× the bandwidth but
  quadruples the cases where reasoning about "what's been acked" breaks,
  and — crucially — Pilot's datagram path doesn't like rapid-fire from a
  single peer. Acks get dropped, retries pile up, the registry gets
  unhappy. **The worker is synchronous by design; do not "optimise" this
  away.**
- **No "kick the worker" on every observer fire.** The worker drains in
  its own thread on its own schedule. New HK pages append outbox rows;
  the worker picks them up FIFO. Forcing the worker to wake-and-send-now
  defeats the pacing.
- **No adaptive concurrency.** No "double the parallelism when things are
  going well." If pacing turns out to be too conservative in production,
  the lever is `PACING_INTERVAL`, not a worker-pool size.

## Observable state

The iOS app should surface (and the Status tab can show):

- `outbox.pending` — count of envelopes waiting to send
- `outbox.totalBytes` — disk pressure indicator
- `outbox.oldestAge` — if this exceeds an hour, something's wrong
- `outbox.recentEvictions` — count over last 24h; nonzero is a red flag
- `outbox.lastAck` — when did we last hear from the Collector

These rolling values drive the iOS UI's "sync healthy?" indicator and the
widget's status colour.

## Summary

| Decision | Value |
|---|---|
| **Backfill window** | **30 days rolling (`BACKFILL_WINDOW_DAYS`), opt-in deeper** |
| Wire ceiling | 65,535 B (Pilot datagram) |
| Splitter budget per envelope | 200 KB raw / ~30 KB gzipped |
| Hard sample cap per envelope | 800 |
| **Concurrency** | **1 envelope in flight, strictly synchronous** |
| **Pacing between successful sends** | **1.5 s minimum (`PACING_INTERVAL`)** |
| Ack timeout | 30 s |
| Backoff on failure | 5, 15, 30, 60, 120, 300 s |
| Outbox size cap | 200 MB compressed payload |
| Anchor advance | Whole `anchor_marker` group acked |
| Compression | Always gzip |
| Routes | Split into `route_chunk` envelopes, max 1 500 points each |
| Pilot health check | Worker idles if `PilotBoot.state ≠ .running` |
