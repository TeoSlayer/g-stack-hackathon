"""
Main retrieval interface.

Two retrieval paths:

1. Alert-triggered (fast, exact)
   Given a list of TriggeredAlerts with metric_ids, return all intervention
   records that address those exact metrics. No embedding needed.
   Use this when you have structured alert data from the iOS app.

2. Semantic (embedding-based)
   Given a natural-language description of the user's situation, retrieve the
   most relevant interventions by cosine similarity.
   Use this for open-ended queries or when alert data is unavailable.

Both paths return RetrievedIntervention objects ranked by relevance.
"""

from __future__ import annotations
from dataclasses import dataclass

from .index import MetricIndex, InterventionRecord
from .embed import EmbeddingStore


@dataclass
class TriggeredAlert:
    """
    Represents one metric that has crossed its alert threshold.
    Mirror of what the iOS app computes on-device.
    """
    metric_id:   int
    metric_name: str
    value:       float        # current computed value
    threshold:   str          # human-readable alert condition from the spec
    band:        str          # "warn" | "bad"


@dataclass
class RetrievedIntervention:
    text:         str
    score:        float        # relevance: 1.0 = exact metric match, <1 = cosine sim
    paper_title:  str
    paper_url:    str
    journal:      str
    year:         int
    study_type:   str
    metric_names: list[str]
    source:       str          # "alert_match" | "semantic"


# Singleton index + store — initialised once per process
_index: MetricIndex | None = None
_store: EmbeddingStore | None = None


def _get_index() -> MetricIndex:
    global _index
    if _index is None:
        _index = MetricIndex()
    return _index


def _get_store() -> EmbeddingStore:
    global _store
    if _store is None:
        idx    = _get_index()
        _store = EmbeddingStore(idx.records)
    return _store


# ------------------------------------------------------------------ #
# Public API
# ------------------------------------------------------------------ #

def retrieve_for_alerts(
    alerts: list[TriggeredAlert],
    max_per_metric: int = 3,
    deduplicate: bool = True,
) -> list[RetrievedIntervention]:
    """
    Fast path: exact metric_id lookup, no embeddings required.

    Returns up to `max_per_metric` interventions per triggered metric,
    deduplicating across metrics so the same paper text doesn't appear twice.
    """
    idx  = _get_index()
    seen: set[str] = set()
    out:  list[RetrievedIntervention] = []

    for alert in alerts:
        records = idx.records_for(alert.metric_id)
        count   = 0
        for rec in records:
            if deduplicate and rec.id in seen:
                continue
            seen.add(rec.id)
            out.append(RetrievedIntervention(
                text=rec.text,
                score=1.0,
                paper_title=rec.paper_title,
                paper_url=rec.paper_url,
                journal=rec.journal,
                year=rec.year,
                study_type=rec.study_type,
                metric_names=rec.metric_names,
                source="alert_match",
            ))
            count += 1
            if count >= max_per_metric:
                break

    return out


def retrieve_semantic(
    query: str,
    top_k: int = 5,
    min_score: float = 0.30,
) -> list[RetrievedIntervention]:
    """
    Semantic path: embed the query and find nearest interventions.

    `query` should describe the user's situation, e.g.:
    "My workload ratio spiked to 1.7 after adding extra training this week."
    """
    store   = _get_store()
    results = store.query(query, top_k=top_k)
    out: list[RetrievedIntervention] = []
    for score, rec in results:
        if score < min_score:
            continue
        out.append(RetrievedIntervention(
            text=rec.text,
            score=round(float(score), 4),
            paper_title=rec.paper_title,
            paper_url=rec.paper_url,
            journal=rec.journal,
            year=rec.year,
            study_type=rec.study_type,
            metric_names=rec.metric_names,
            source="semantic",
        ))
    return out


def retrieve_interventions(
    alerts:    list[TriggeredAlert] | None = None,
    query:     str | None = None,
    top_k:     int = 5,
    min_score: float = 0.25,
) -> list[RetrievedIntervention]:
    """
    Combined retrieval. Alert path runs first; semantic fills gaps.

    Parameters
    ----------
    alerts : triggered metric alerts from the iOS device
    query  : optional free-text description of the situation
    top_k  : max results from semantic path
    """
    results: list[RetrievedIntervention] = []

    if alerts:
        results.extend(retrieve_for_alerts(alerts))

    if query:
        semantic = retrieve_semantic(query, top_k=top_k, min_score=min_score)
        # skip semantic results already covered by alert-exact matches
        covered_texts = {r.text for r in results}
        results.extend(r for r in semantic if r.text not in covered_texts)

    # sort: exact matches first, then by cosine score
    results.sort(key=lambda r: (0 if r.source == "alert_match" else 1, -r.score))
    return results
