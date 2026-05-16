"""
example.py — demonstrates both retrieval paths.

    python example.py

Scenario: the iOS app reports three triggered alerts for a user.
We retrieve evidence-based interventions and format a prompt for an LLM.
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))

from retrieval import retrieve_interventions, TriggeredAlert, format_for_llm
from retrieval.format import format_as_dict
import json

# ── Simulated alert payload from the iOS device ─────────────────────────────
alerts = [
    TriggeredAlert(
        metric_id=2,
        metric_name="Workload Ratio (ACWR)",
        value=1.72,
        threshold="acwr > 1.5 (danger)",
        band="bad",
    ),
    TriggeredAlert(
        metric_id=1,
        metric_name="HRV Stability (CV)",
        value=0.38,
        threshold="hrv_cv > 0.3",
        band="warn",
    ),
    TriggeredAlert(
        metric_id=15,
        metric_name="Social Jetlag",
        value=1.4,
        threshold="sji_hours > 1.0",
        band="warn",
    ),
]

# ── Path 1: alert-triggered retrieval (no embeddings needed) ─────────────────
print("\n" + "=" * 70)
print("PATH 1 — Alert-triggered retrieval (exact metric_id match)")
print("=" * 70)

results_alert = retrieve_interventions(alerts=alerts)
for r in results_alert:
    print(f"\n[{r.source}  score={r.score:.3f}]  {r.paper_title} ({r.year})")
    print(f"  → {r.text}")

# ── Path 2: semantic retrieval ───────────────────────────────────────────────
print("\n" + "=" * 70)
print("PATH 2 — Semantic retrieval")
print("=" * 70)

query = (
    "My training load spiked this week and my HRV is all over the place. "
    "I also sleep in on weekends which is messing with my rhythm."
)
results_semantic = retrieve_interventions(query=query, top_k=5)
for r in results_semantic:
    print(f"\n[{r.source}  score={r.score:.3f}]  {r.paper_title} ({r.year})")
    print(f"  → {r.text}")

# ── Path 3: combined (alerts + semantic) ─────────────────────────────────────
print("\n" + "=" * 70)
print("PATH 3 — Combined retrieval → LLM prompt")
print("=" * 70)

combined = retrieve_interventions(alerts=alerts, query=query, top_k=4)
prompt   = format_for_llm(alerts, combined, user_context="Recreational runner, trains 5x/week.")
print(prompt)

# ── Structured dict for REST response ────────────────────────────────────────
print("\n" + "=" * 70)
print("Structured dict (for REST API / downstream agent)")
print("=" * 70)
print(json.dumps(format_as_dict(alerts, combined[:3]), indent=2))
