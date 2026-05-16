"""
Loads and cross-references health_metrics.json + prescriptive_papers.json.
Produces flat intervention records that the embedding layer can index.
"""

from __future__ import annotations
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

_DATA = Path(__file__).parent.parent / "data"


def _load(filename: str) -> Any:
    with open(_DATA / filename, encoding="utf-8") as f:
        return json.load(f)


@dataclass
class InterventionRecord:
    """One addressable unit in the embedding index."""
    id: str                    # "{paper_id}:{intervention_index}"
    text: str                  # the intervention sentence itself
    metric_ids: list[int]
    metric_names: list[str]
    paper_id: int
    paper_title: str
    paper_url: str
    journal: str
    year: int
    study_type: str
    # pre-built context string used as the embedding document
    document: str = field(init=False)

    def __post_init__(self) -> None:
        # richer document = better embedding retrieval
        self.document = (
            f"Metrics: {', '.join(self.metric_names)}. "
            f"Intervention: {self.text} "
            f"(Source: {self.paper_title}, {self.journal} {self.year}, {self.study_type})"
        )


class MetricIndex:
    """
    Pre-built cross-reference between health metrics and prescriptive papers.

    Produces flat InterventionRecord list for the embedding layer, plus
    direct metric-id lookups for the alert-triggered retrieval path.
    """

    def __init__(self) -> None:
        metrics_raw = _load("health_metrics.json")
        papers_raw  = _load("prescriptive_papers.json")

        self._metrics: dict[int, dict] = {m["id"]: m for m in metrics_raw["metrics"]}
        self._papers:  dict[int, dict] = {p["id"]: p for p in papers_raw["papers"]}

        self.records: list[InterventionRecord] = []
        for paper in papers_raw["papers"]:
            mnames = [
                self._metrics[mid]["name"]
                for mid in paper.get("metric_ids", [])
                if mid in self._metrics
            ]
            for i, text in enumerate(paper.get("interventions", [])):
                self.records.append(InterventionRecord(
                    id=f"{paper['id']}:{i}",
                    text=text,
                    metric_ids=paper.get("metric_ids", []),
                    metric_names=mnames,
                    paper_id=paper["id"],
                    paper_title=paper["title"],
                    paper_url=paper.get("url", ""),
                    journal=paper.get("journal", ""),
                    year=paper.get("year", 0),
                    study_type=paper.get("study_type", ""),
                ))

        # metric_id → records that address it (for fast alert-triggered lookup)
        self._by_metric: dict[int, list[InterventionRecord]] = {}
        for rec in self.records:
            for mid in rec.metric_ids:
                self._by_metric.setdefault(mid, []).append(rec)

    def metric(self, metric_id: int) -> dict | None:
        return self._metrics.get(metric_id)

    def records_for(self, metric_id: int) -> list[InterventionRecord]:
        return self._by_metric.get(metric_id, [])

    def covered_metric_ids(self) -> set[int]:
        return set(self._by_metric.keys())

    def __repr__(self) -> str:
        return (
            f"MetricIndex({len(self._metrics)} metrics, "
            f"{len(self._papers)} papers, "
            f"{len(self.records)} intervention records)"
        )
