"""
Input/output contracts for the health-intelligence retrieval tool.
These Pydantic models are the single source of truth for validation —
used by the FastAPI server, the CLI, and the tool manifest generator.
"""

from __future__ import annotations
from typing import Literal, Optional
from pydantic import BaseModel, Field, model_validator


# ── Input ─────────────────────────────────────────────────────────────────── #

class AlertInput(BaseModel):
    metric_id: int = Field(..., ge=1, le=50, description="HealthKit metric ID from health_metrics.json")
    metric_name: str = Field(..., min_length=1, max_length=120)
    value: float
    threshold: str = Field(..., max_length=200, description="Human-readable threshold description")
    band: Literal["warn", "bad"] = Field(..., description="Alert severity band")


class RetrieveRequest(BaseModel):
    alerts: list[AlertInput] = Field(
        default_factory=list,
        max_length=20,
        description="Triggered metric alerts from the iOS app",
    )
    query: Optional[str] = Field(
        None,
        min_length=3,
        max_length=1000,
        description="Free-text semantic query (e.g. 'my HRV crashed after a hard week')",
    )
    top_k: int = Field(5, ge=1, le=20, description="Max number of interventions to return")
    min_score: float = Field(
        0.25,
        ge=0.0,
        le=1.0,
        description="Minimum cosine similarity for semantic results (0 = any, 1 = exact)",
    )

    @model_validator(mode="after")
    def at_least_one_signal(self) -> "RetrieveRequest":
        if not self.alerts and self.query is None:
            raise ValueError("Provide at least one of: alerts, query")
        return self


# ── Output ────────────────────────────────────────────────────────────────── #

class InterventionOutput(BaseModel):
    rank: int
    text: str
    score: float = Field(..., ge=0.0, le=1.0)
    source: Literal["alert_match", "semantic"]
    paper_title: str
    paper_url: str
    journal: str
    year: int
    study_type: str
    metric_names: list[str]


class RetrieveResponse(BaseModel):
    alerts: list[AlertInput]
    interventions: list[InterventionOutput]
    llm_prompt: Optional[str] = Field(
        None,
        description="Ready-to-send LLM prompt (included when query or alerts present)",
    )
    meta: dict = Field(default_factory=dict, description="Timing and source stats")
