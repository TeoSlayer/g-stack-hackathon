# On-Device Health Metrics

All 27 models run entirely on the iOS device. No server, no network dependency for analysis.

## Original 7 (Models.swift)

| Model | Window | Key formula |
|---|---|---|
| Sleep Regularity Index | 14d | Pairwise minute-level agreement matrix (Phillips et al.) |
| Autonomic Balance | 14d | z(HRV) − z(RHR) composite |
| Sedentary Stress | 24h | Minutes with HR > RHR+20 AND steps < 200/hr |
| Cognitive Recovery Debt | 7d | EWMA of (8h − actual sleep), weighted toward recent nights |
| Burnout CUSUM | 60d | Page-Shewhart control chart on RHR |
| Circadian Drift | 14d | Mann-Kendall trend test on nightly bedtimes |
| HRV (Kalman-smoothed) | 30d | Local-level state-space smoother |

## Tier 1 — Autonomic (SpecMetrics.swift)

| ID | Model | Key formula | Alert |
|---|---|---|---|
| 23 | **RR Deviation** ⚠️ | EWMA(3) − EWMA(30) on respiratory rate | > 1.5 brpm |
| 33 | Vagal Rebound | HRV post-wake − HRV pre-sleep | < −5 ms |
| 5 | RHR Trajectory | 7d linear regression slope on resting HR | slope > 0 |
| 8 | Morning HR Surge | Max HR (+10 min after wake) − avg HR (−2h before wake) | > 40 bpm |
| 2 | ACWR | EWMA(7) / EWMA(28) on active energy | > 1.5 or < 0.8 |
| 1 | HRV Stability (CV) | stddev(HRV, 7d) / mean(HRV, 7d) | > 0.3 |

RR Deviation is marked HIGH PRIORITY in the spec — respiratory rate is extremely stable in health and deviates reliably early in illness or severe exhaustion.

## Tier 2 — Sleep Precision (SpecMetrics.swift)

| ID | Model | Key formula | Alert |
|---|---|---|---|
| 10 | Sleep Architecture Efficiency | (deep + REM seconds) / in-bed seconds | < 40% |
| 13 | WASO | Awake minutes strictly between first and last asleep | > 30 min |
| 12 | SOL Spike | Today's sleep onset latency z-score vs 30d baseline | z > 2.0 |
| 15 | Social Jetlag | \|avg weekend midpoint − avg weekday midpoint\| | > 1 hour |

Sleep Architecture Efficiency requires Series 9+ Apple Watch for reliable deep/REM detection. On older watches the model returns `.unknown` gracefully.

## Tier 3 — Metabolic / Behavioral (SpecMetrics.swift)

| ID | Model | Key formula | Alert |
|---|---|---|---|
| 24 | SpO2 Desaturation Density | Overnight SpO2 < 94% events / sleep hours | > 5 /hr |
| 17 | Acoustic Load | Σ (dB − 75) × hours, samples above 75 dBASPL | > 50 dB·h |
| 21 | Light Deficit | Σ max(0, 120 − daylight_min) over rolling 3d | > 120 min |
| 22 | Movement Rate (SFR) | Stand hours / awake hours | < 0.5 |
| 25 | Body Mass Volatility | 7d stddev of body mass | > 1.5 kg |
| 27 | VO2 Max Trend | (latest − 30d-ago value) / elapsed days | < −0.05 /day |
| 32 | Burnout Velocity | OLS slope on 7-night sleep deficit signal | > 0 for 3+ days |

## Readiness Score (Readiness.swift)

When ≥7 days of HRV, RHR, and sleep are cached, uses the weighted z-score formula from the spec:

```
raw   = 0.4 · z(HRV) − 0.3 · z(RHR) + 0.3 · z(sleep_hours)
score = clamp(50 + raw × 25, 1, 100)
```

Falls back to simple `today_HRV / 7d_baseline_HRV` ratio when cache is absent (first launch, insufficient data).

## Tier 4 — Added metrics (SpecMetrics.swift)

| ID | Model | Key formula | Alert |
|---|---|---|---|
| 3 | Training Monotony | mean(active_kcal, 7d) / stddev(active_kcal, 7d) | > 2.0 |
| 4 | Nocturnal HR Dip | (daytime_avg − nocturnal_min) / daytime_avg | < 5% |
| 29 | NEAT Proxy | total steps/kcal − steps/kcal during workout windows | low on heavy training days |

## Not yet implemented

These metrics require additional entitlements or hardware:

| ID | Model | Blocker |
|---|---|---|
| 16, 18, 19, 20 | Blue Light, Sensory Overload, Contextual Stress Peaks, Eye Strain | `DeviceActivityReport` framework (Screen Time entitlement) |
| 14 | Temperature Phase Shift | `appleSleepingWristTemperature` — Series 8+ only |
| 6, 7, 28 | HRR, CV Drift, Pacing Efficiency | GPS route chunks + user age in profile |
| 30, 26 | TRIMP, MET Minutes | User age required for max HR calculation |

## Data flow

```
HealthKit observer fires
        │
        ▼
HealthSyncManager.syncAll()
        │
        ├── TimeSeries.compute() × 4      → cachedSeries
        ├── Models.computeAll()            → modelReadings (24 models, all concurrent)
        └── Readiness.compute(cache:)      → readiness (weighted z-score when cache ready)
                │
                ▼
        WidgetSnapshot → Widget
        @Published → SwiftUI views
```

All metric functions are `static async` and run concurrently via `async let` in `computeAll`. No model blocks another.
