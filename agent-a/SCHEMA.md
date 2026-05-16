# Wire schema

The data shape that iOS HealthSync (and future sources) put on the wire to
Agent A through Pilot. JSON, length-prefixed, UTF-8.

Five message types across four Pilot ports:

| Direction | Port | Message |
|---|---|---|
| Source → Collector | 1001 | `Envelope` — a batch of samples |
| Collector → Source | (envelope's `ack_port`) | `Ack` — what was accepted / rejected / duplicated |
| Coach → Collector | 1003 | `Query` — SQL request |
| Collector → Coach | (query's `reply_port`) | `QueryResult` — rows + schema |
| Collector → Coach | 1004 | `ChangeEvent` — broadcast that new facts landed |

## Envelope (1001)

```json
{
  "v": 1,
  "source": "ios.healthsync",
  "device_id": "iPhone-Calin",
  "device_model": "iPhone 15 Pro Max",
  "os_version": "iOS 17.6",
  "app_version": "0.1.0",
  "batch_id": "0b1f2c5a-…uuid v4",
  "sent_at": 1701234567.123,
  "ack_port": 1002,
  "samples":  [ … see Sample below … ],
  "workouts": [ … see Workout below … ],
  "metadata": {
    "location": { "lat": 47.6097, "lon": -122.3331,
                  "accuracy_m": 12.5, "altitude_m": 53.2, "ts": 1701234560.0 },
    "network":       "wifi",
    "battery_level": 0.82,
    "wake_window":   [7, 23]
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `v` | int | ✓ | Schema version. Bump on incompatible change. Start at `1`. |
| `source` | string | ✓ | Stable source id. `ios.healthsync` for now. |
| `device_id` | string | ✓ | Stable across reinstalls if user keeps it. Default `<model>-<name>`. |
| `device_model` | string |  | `UIDevice.current.model`. Useful for plot facetting. |
| `os_version` | string |  | iOS version string. |
| `app_version` | string |  | CFBundleShortVersionString. |
| `batch_id` | string (uuid) | ✓ | Unique per envelope. Same id is replayed verbatim on retry. |
| `sent_at` | float (epoch s) | ✓ | When the envelope was put on the wire. |
| `ack_port` | int | ✓ | Source's Pilot port to receive the `Ack`. Default 1002. |
| `samples` | array | ✓ | Zero or more HK samples. May be empty if envelope is metadata-only (rare). |
| `workouts` | array |  | Workouts separated because they carry routes + sub-totals. |
| `metadata` | object |  | Envelope-level context. Per-sample location goes in the sample, not here. |

**Limits.** Max envelope ≤ 1 MB after JSON encoding. Source must chunk; iOS today chunks at 200 samples per envelope.

## Sample (quantity)

```json
{
  "kind": "quantity",
  "uuid": "9a5e…HK-sample-uuid",
  "type": "heartRateVariabilitySDNN",
  "value": 47.2,
  "unit": "ms",
  "start_utc": 1701234560.0,
  "end_utc":   1701234560.0,
  "source_name":   "Apple Watch",
  "source_bundle": "com.apple.health.5C2E…",
  "device":        "Apple Watch Series 9",
  "location": {
    "lat": 47.6097, "lon": -122.3331,
    "accuracy_m": 12.5, "source": "photo_join", "offset_s": -480
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `kind` | enum | ✓ | `"quantity"`, `"category"`, or `"workout"`. |
| `uuid` | string | ✓ | The HKSample UUID. Primary dedupe key. |
| `type` | string | ✓ | Canonical HK identifier minus prefix: `heartRate`, `stepCount`, `bodyTemperature`, etc. |
| `value` | float | ✓ | Always finite. `NaN` and `Inf` filtered at source. |
| `unit` | string | ✓ | HK unit string. e.g. `bpm`, `ms`, `count`, `m`, `kcal`. |
| `start_utc` / `end_utc` | float (epoch s) | ✓ | UTC seconds with millisecond precision. |
| `source_name` | string |  | Human-readable. `"Apple Watch"`, `"iPhone"`, third-party app names. |
| `source_bundle` | string |  | The bundle id of the writing app. |
| `device` | string |  | `HKDevice.name` if available. |
| `location` | object |  | See [Location](#location). Optional — many samples won't have one. |

### Quantity type catalogue (current iOS app)

| HK type | Sent unit |
|---|---|
| `heartRate`, `restingHeartRate`, `respiratoryRate` | `count/min` |
| `heartRateVariabilitySDNN` | `ms` |
| `oxygenSaturation` | `%` |
| `bodyTemperature` | `degC` |
| `stepCount`, `flightsClimbed` | `count` |
| `distanceWalkingRunning`, `distanceCycling` | `m` |
| `activeEnergyBurned`, `basalEnergyBurned` | `kcal` |
| `appleExerciseTime`, `appleStandTime`, `timeInDaylight` | `min` |
| `vo2Max` | `ml/kg*min` |
| `bodyMass` | `kg` |

## Sample (category)

```json
{
  "kind": "category",
  "uuid": "…",
  "type": "sleepAnalysis",
  "category_value": 5,
  "category_name":  "asleepREM",
  "start_utc": 1701208800.0,
  "end_utc":   1701209820.0,
  "source_name": "Apple Watch",
  "device":      "Apple Watch Series 9",
  "metadata": {
    "HKWasUserEntered": "0",
    "HKSleepAnalysisOriginalSubject": "1"
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `kind` | enum (`"category"`) | ✓ | |
| `uuid` | string | ✓ | |
| `type` | string | ✓ | `sleepAnalysis`, `mindfulSession`, `appleStandHour`. |
| `category_value` | int | ✓ | Raw `HKCategoryValue*` enum value. |
| `category_name` | string |  | Human-readable map of `category_value`. E.g. `asleepCore`, `asleepDeep`, `asleepREM`, `inBed`, `awake`. |
| `metadata` | object |  | HK sample metadata stringified (HK metadata can hold types JSON can't). |

## Workout

Workouts carry sub-totals and an optional route (GPS polyline). Routes are
inline if small; large routes (>5 000 points) are split: the workout
references a `route_chunks` count and the remaining chunks follow in
sequential envelopes carrying only `{ batch_id, workout_uuid, chunk_idx, points: [] }`.

```json
{
  "uuid": "…",
  "activity_type": 37,
  "activity_name": "running",
  "start_utc": 1701180000.0,
  "end_utc":   1701183600.0,
  "duration_s": 3600,
  "total_energy_kcal": 450.2,
  "total_distance_m":  10500.3,
  "source_name": "Apple Watch",
  "device": "Apple Watch Series 9",
  "route": {
    "point_count": 1234,
    "inline": true,
    "points": [
      [47.610, -122.333,   0.0, 1701180000.0, 3.1],
      [47.611, -122.332,  10.5, 1701180003.0, 3.5],
      …
    ]
  }
}
```

Route point tuple: `[lat, lon, elevation_m, ts_utc, speed_mps]`. `null` for
missing fields.

## Location

Used as `metadata.location` on the envelope (device location at sync time)
and as `sample.location` on individual quantity samples (where the sample
was *recorded*, derived two different ways).

```json
{
  "lat": 47.6097,
  "lon": -122.3331,
  "accuracy_m": 12.5,
  "altitude_m": 53.2,
  "source": "core_location",
  "offset_s": 0,
  "ts": 1701234560.0
}
```

| Field | Type | Notes |
|---|---|---|
| `lat`, `lon` | float | Degrees, WGS84. |
| `accuracy_m` | float | Horizontal accuracy. `-1` means unknown. |
| `altitude_m` | float | Optional. |
| `source` | enum | `"core_location"` (CL fix at sync time) or `"photo_join"` (matched a geotagged photo within `offset_s`). |
| `offset_s` | int | Seconds between the sample's timestamp and the location's timestamp. Negative if the location is earlier. |
| `ts` | float | Location's own timestamp. |

## Ack (reply on envelope's `ack_port`)

```json
{
  "v": 1,
  "batch_id": "0b1f2c5a-…",
  "accepted":         ["uuid1", "uuid2", … ],
  "duplicates":       ["uuid3", "uuid4"],
  "rejected": [
    {"uuid": "uuid5", "reason": "schema_error", "message": "missing 'type'"}
  ],
  "ingested_at": 1701234600.123,
  "collector_version": "0.1.0"
}
```

Source's contract on receiving an `Ack`:

- Treat `accepted` ∪ `duplicates` as durable. Advance HK anchor / drop from outbox for those.
- `rejected` are *also* durable in the sense that retrying won't fix them — drop them too, log the reason.
- Missing UUIDs (the request had them but they're not in any of the three arrays) → retry.
- No ack within `T = 30 s` → outbox retains the batch, exponential backoff retry.

## Query (Coach → Collector on port 1003)

```json
{
  "v": 1,
  "request_id": "8c2d…uuid",
  "reply_port": 1005,
  "kind": "sql",
  "sql": "SELECT date_trunc('day', to_timestamp(start_utc)) AS day, AVG(value) AS hrv FROM samples WHERE type='heartRateVariabilitySDNN' AND start_utc > ? GROUP BY 1 ORDER BY 1",
  "params": [1700000000],
  "limit": 1000
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `kind` | enum | ✓ | Currently only `"sql"`. Future: `"types"`, `"latest"` shorthand kinds. |
| `sql` | string | ✓ when `kind="sql"` | Read-only DuckDB SQL. Collector rejects writes. |
| `params` | array |  | Positional parameters. |
| `limit` | int |  | Hard cap; Collector clamps to ≤ 10 000 rows. |
| `reply_port` | int | ✓ | Where the QueryResult lands. |

## QueryResult (Collector → Coach on `reply_port`)

```json
{
  "v": 1,
  "request_id": "8c2d…",
  "ok": true,
  "rows": [
    {"day": "2024-12-01", "hrv": 47.2},
    {"day": "2024-12-02", "hrv": 49.1}
  ],
  "schema": [
    {"name": "day", "type": "TIMESTAMP"},
    {"name": "hrv", "type": "DOUBLE"}
  ],
  "row_count": 2,
  "ms": 14,
  "truncated": false
}
```

On error: `ok: false`, `error: {code, message}`.

## ChangeEvent (Collector → Coach on port 1004)

Fired after every batch commit. Coach subscribes and may decide to act.

```json
{
  "v": 1,
  "kind": "samples_added",
  "device_id": "iPhone-Calin",
  "by_type": {
    "heartRate": 38,
    "heartRateVariabilitySDNN": 1,
    "stepCount": 12
  },
  "since_ts": 1701234567.0,
  "until_ts": 1701234599.0,
  "ts": 1701234600.123
}
```

The event is informational only — no ack expected, no retry. Coach's rule
loop re-derives state from DuckDB on each tick anyway.

## Versioning

Top-level `v` on every message. Collector accepts the current version and
the one prior. iOS bumps `v` only when a field becomes required or its
semantics change.

## What's deliberately not in the schema

- **Raw photo files.** Only the geotag's lat/lon, captured at iOS-side as a
  `location.source: "photo_join"`. Photo contents never leave the phone.
- **Workout per-second HR.** Already in `samples` as individual `heartRate`
  rows. The workout entry doesn't duplicate them; it just brackets the time
  window.
- **HRV/RHR baselines, readiness, model outputs.** These are *derived*.
  Collector stores raw; Coach (or any reader) computes derivations from
  DuckDB. Keeps the warehouse honest.
- **App-level events.** Crashes, screen views, button taps — not relevant
  to the loop. If we ever want them, a separate `kind: "app_event"` slot.
- **PII beyond what HK gives you.** No name, no email, no auth token. The
  Pilot identity is the only identifier; `device_id` is a user-chosen label.

## See also

- [README.md](README.md) — Agent A overview
- [../health-sync/HealthSync/HealthSyncManager.swift](../health-sync/HealthSync/HealthSyncManager.swift) — where envelopes are currently encoded (HTTP) and will be converted to Pilot
- [../infra/README.md](../infra/README.md) — Pilot trust + bot + DuckDB setup
