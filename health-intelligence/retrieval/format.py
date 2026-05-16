"""
Formats retrieved interventions into a prompt-ready string for an LLM,
or a clean structured dict for a REST response.
"""

from __future__ import annotations
from .retrieve import RetrievedIntervention, TriggeredAlert


def format_for_llm(
    alerts: list[TriggeredAlert],
    interventions: list[RetrievedIntervention],
    user_context: str = "",
) -> str:
    """
    Returns a system + user prompt block ready to send to any LLM.
    The LLM's job is to synthesise the retrieved interventions into
    personalised, prioritised advice for the specific alert values.
    """
    alert_block = "\n".join(
        f"- {a.metric_name}: {a.value} ({a.band.upper()}) — alert: {a.threshold}"
        for a in alerts
    ) or "None (semantic query only)"

    evidence_block = ""
    for i, r in enumerate(interventions, 1):
        evidence_block += (
            f"\n[{i}] {r.paper_title} ({r.journal}, {r.year}, {r.study_type})\n"
            f"    Metrics: {', '.join(r.metric_names)}\n"
            f"    Intervention: {r.text}\n"
            f"    URL: {r.paper_url}\n"
        )

    context_block = f"\nUser context: {user_context}\n" if user_context else ""

    return f"""You are a health coach synthesising evidence-based interventions for a user's specific metrics.

## Triggered alerts
{alert_block}
{context_block}
## Retrieved evidence ({len(interventions)} interventions)
{evidence_block}
## Your task
Write 3–5 concise, prioritised, actionable recommendations for this user.
- Lead with the highest-impact intervention for their worst alert.
- Be specific: include numbers (duration, frequency, intensity) from the evidence.
- Cite the source paper inline, e.g. "(BMC Sports Science, 2025)".
- Do NOT mention metrics the user did not trigger.
- Tone: direct, practical, not alarming.
"""


def format_as_dict(
    alerts: list[TriggeredAlert],
    interventions: list[RetrievedIntervention],
) -> dict:
    """Structured response for a REST API or downstream agent."""
    return {
        "alerts": [
            {
                "metric_id":   a.metric_id,
                "metric_name": a.metric_name,
                "value":       a.value,
                "band":        a.band,
                "threshold":   a.threshold,
            }
            for a in alerts
        ],
        "interventions": [
            {
                "rank":         i,
                "text":         r.text,
                "score":        r.score,
                "source":       r.source,
                "paper_title":  r.paper_title,
                "paper_url":    r.paper_url,
                "journal":      r.journal,
                "year":         r.year,
                "study_type":   r.study_type,
                "metric_names": r.metric_names,
            }
            for i, r in enumerate(interventions, 1)
        ],
    }
