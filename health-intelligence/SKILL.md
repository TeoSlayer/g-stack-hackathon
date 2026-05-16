---
name: health-intelligence
version: 1.0.0
description: |
  Evidence-based intervention retrieval for health metric alerts.
  Given triggered alerts (metric_id + value + band from the iOS app) or a
  free-text query, returns ranked intervention recommendations sourced from
  17 peer-reviewed systematic reviews and meta-analyses.
  ZeroEntropy reranking is planned but not yet integrated; results are
  currently ranked by cosine similarity (semantic path) or score=1.0 (alert match).
  Use when the user asks about health interventions, when a metric alert fires,
  or when a reasoning agent needs evidence-backed recommendations.
tags:
  - health
  - retrieval
  - rag
  - interventions
  - coach
allowed-tools:
  - Bash
---

# health-intelligence — intervention retrieval tool

## What it does

Two retrieval paths, results formatted for LLM consumption:

| Path | Trigger | Speed | Notes |
|---|---|---|---|
| `alert_match` | `alerts` list with `metric_id` | <5 ms | Exact lookup, score=1.0 — no embeddings needed |
| `semantic` | `query` string | ~10 ms warm | Cosine similarity over 384-dim `all-MiniLM-L6-v2` embeddings |

Results are sorted alert-first then by cosine score. **ZeroEntropy reranking is planned** — the architecture reserves a reranking stage between retrieval and formatting, but the integration is not yet implemented. The server currently returns retrieval scores directly.

## Starting the server

```bash
cd /Users/calinteodor/Development/g-stack-hackathon/health-intelligence
.venv/bin/python server.py        # default: http://127.0.0.1:8741
```

Check liveness: `curl http://127.0.0.1:8741/health`

The server loads the embedding model once at startup (~3 s); all subsequent
calls are fast. Keep it running as a sidecar next to agent-b.

## Calling the tool

### POST /retrieve

```bash
curl -s -X POST http://127.0.0.1:8741/retrieve \
  -H "Content-Type: application/json" \
  -d '{
    "alerts": [
      {
        "metric_id": 2,
        "metric_name": "Workload Ratio (ACWR)",
        "value": 1.72,
        "threshold": "acwr > 1.5 (danger)",
        "band": "bad"
      }
    ],
    "query": "my training load spiked this week",
    "top_k": 5
  }' | jq '.interventions[] | {rank, text, score, source}'
```

### Python (direct import, no server needed)

```python
from retrieval.retrieve import retrieve_interventions, TriggeredAlert
from retrieval.format import format_for_llm

alerts = [TriggeredAlert(metric_id=2, metric_name="ACWR", value=1.72,
                         threshold="acwr > 1.5", band="bad")]
results = retrieve_interventions(alerts=alerts, query="overtraining risk", top_k=5)
prompt  = format_for_llm(alerts, results, user_context="Recreational runner")
```

## Request schema

```json
{
  "alerts": [
    {
      "metric_id":   1,
      "metric_name": "string",
      "value":       1.72,
      "threshold":   "string",
      "band":        "warn|bad"
    }
  ],
  "query":     "optional free-text string (min 3, max 1000 chars)",
  "top_k":     5,
  "min_score": 0.25
}
```

**At least one of `alerts` or `query` must be provided.**

`metric_id` values are defined in `data/health_metrics.json` (IDs 1–50).
`band` must be `"warn"` or `"bad"`.

## Response schema

```json
{
  "alerts": [...],
  "interventions": [
    {
      "rank":         1,
      "text":         "Maintain ACWR within 0.8–1.3 safe zone…",
      "score":        1.0,
      "source":       "alert_match|semantic",
      "paper_title":  "string",
      "paper_url":    "https://...",
      "journal":      "string",
      "year":         2025,
      "study_type":   "systematic review and meta-analysis",
      "metric_names": ["Acute-to-Chronic Workload Ratio"]
    }
  ],
  "llm_prompt": "You are a health coach…",
  "meta": {
    "elapsed_ms":       12,
    "alert_matches":    3,
    "semantic_matches": 2,
    "total":            5
  }
}
```

## Rails / constraints

- **Input validation**: Pydantic enforces types; `metric_id` 1–50, `top_k` 1–20,
  `min_score` 0–1, `band` enum. Malformed requests return HTTP 422.
- **Empty results**: Valid — returns `interventions: []` if nothing scores above
  `min_score`. Never hallucinated content; only indexed paper text is returned.
- **Deduplication**: Alert-path deduplicates across metrics; semantic path
  skips texts already returned by alert path.
- **LLM prompt guardrail**: The included `llm_prompt` instructs the LLM not to
  mention metrics the user didn't trigger and to cite paper sources inline.
- **No external calls at query time**: Embeddings are cached locally. Model
  loads once at server startup. No API keys, no rate limits.
- **Papers coverage**: 17 papers, 89 interventions, 25 metric IDs covered.
  Semantic path can surface relevant context even for uncovered metric IDs.

## Metric IDs quick reference

| ID | Metric | Alert condition |
|---|---|---|
| 1 | HRV Stability (CV) | hrv_cv > 0.3 |
| 2 | Acute-to-Chronic Workload Ratio | acwr > 1.5 or < 0.8 |
| 3 | Training Monotony | monotony > 2.0 |
| 4 | RHR Dip Amplitude | dip < 5% |
| 7 | Vagal Tone Rebound | rebound < −5 ms |
| 8 | RHR Slope | slope > 0 bpm/day |
| 10 | Sleep Efficiency | efficiency < 40% |
| 11 | WASO | awake > 30 min |
| 12 | Sleep Onset Latency Spike | z > 2.0 |
| 15 | Social Jetlag Index | sji > 1.0 h |
| 16 | SpO₂ Density | >5 events/hr below 94% |
| 17 | Acoustic Load | >75 dBASPL·h |
| 18 | Light Deficit | >120 min shortage/3d |
| 22 | VO₂max Trend | slope < −0.05/day |
| 29 | NEAT Proxy | below baseline |

Full list: `data/health_metrics.json`

## Error codes

| HTTP | Meaning |
|---|---|
| 422 | Validation error — check request schema |
| 503 | Server still initialising — retry in ~5 s |
