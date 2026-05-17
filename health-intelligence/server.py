"""
health-intelligence FastAPI server.

    .venv/bin/python server.py          # default: localhost:8741
    PORT=9000 .venv/bin/python server.py

Endpoints
---------
GET  /health          — liveness + index stats
GET  /help            — schema + usage examples (JSON)
POST /retrieve        — main retrieval endpoint
"""

from __future__ import annotations
import logging
import os
import sys
import time
from pathlib import Path

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse

sys.path.insert(0, str(Path(__file__).parent))

from schema import RetrieveRequest, RetrieveResponse, InterventionOutput
from retrieval.index import MetricIndex
from retrieval.embed import EmbeddingStore
import retrieval.retrieve as _retrieve_mod
from retrieval.retrieve import retrieve_interventions, TriggeredAlert
from retrieval.format import format_for_llm

logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(message)s")
log = logging.getLogger(__name__)

app = FastAPI(
    title="health-intelligence",
    description="Evidence-based intervention retrieval from 17 peer-reviewed papers.",
    version="1.0.0",
)

# ── Startup: load index + warm embedding model once ───────────────────────── #

_index: MetricIndex | None = None
_store: EmbeddingStore | None = None


@app.on_event("startup")
def _startup() -> None:
    global _index, _store
    log.info("Loading metric index…")
    _index = MetricIndex()
    log.info("Building/loading embedding store…")
    _store = EmbeddingStore(_index.records)
    # pre-warm the retrieve module's singletons so calls are instant
    _retrieve_mod._index = _index
    _retrieve_mod._store = _store
    log.info(
        "Ready — %d records indexed in ZE collection %r",
        len(_store.records),
        _store.collection,
    )


# ── Routes ────────────────────────────────────────────────────────────────── #

@app.get("/health")
def health() -> dict:
    if _index is None:
        raise HTTPException(503, "Index not loaded")
    return {
        "status": "ok",
        "papers": len(set(r.paper_id for r in _index.records)),
        "interventions": len(_index.records),
        "metrics_covered": len(_index.covered_metric_ids()),
    }


@app.get("/help")
def help_endpoint() -> dict:
    return {
        "description": (
            "Retrieve evidence-based interventions for health metric alerts. "
            "Supports exact metric_id matching and cosine-semantic retrieval."
        ),
        "endpoints": {
            "POST /retrieve": "Main retrieval endpoint — see request_schema below",
            "GET /health": "Liveness + index stats",
            "GET /help": "This page",
        },
        "request_schema": RetrieveRequest.model_json_schema(),
        "response_schema": RetrieveResponse.model_json_schema(),
        "examples": {
            "alerts_only": {
                "alerts": [
                    {
                        "metric_id": 2,
                        "metric_name": "Workload Ratio (ACWR)",
                        "value": 1.72,
                        "threshold": "acwr > 1.5 (danger)",
                        "band": "bad",
                    }
                ],
                "top_k": 5,
            },
            "semantic_only": {
                "query": "my HRV crashed after a hard training week",
                "top_k": 5,
            },
            "combined": {
                "alerts": [
                    {
                        "metric_id": 1,
                        "metric_name": "HRV Stability (CV)",
                        "value": 0.38,
                        "threshold": "hrv_cv > 0.3",
                        "band": "warn",
                    }
                ],
                "query": "my heart rate variability is unstable and sleep is broken",
                "top_k": 6,
            },
        },
    }


@app.post("/retrieve", response_model=RetrieveResponse)
def retrieve(req: RetrieveRequest) -> RetrieveResponse:
    if _index is None or _store is None:
        raise HTTPException(503, "Server still initialising — retry in a few seconds")

    t0 = time.perf_counter()

    # Map validated input → internal types
    triggered = [
        TriggeredAlert(
            metric_id=a.metric_id,
            metric_name=a.metric_name,
            value=a.value,
            threshold=a.threshold,
            band=a.band,
        )
        for a in req.alerts
    ]

    results = retrieve_interventions(
        alerts=triggered or None,
        query=req.query,
        top_k=req.top_k,
        min_score=req.min_score,
    )

    interventions = [
        InterventionOutput(
            rank=i,
            text=r.text,
            score=round(r.score, 4),
            source=r.source,
            paper_title=r.paper_title,
            paper_url=r.paper_url,
            journal=r.journal,
            year=r.year,
            study_type=r.study_type,
            metric_names=r.metric_names,
        )
        for i, r in enumerate(results, 1)
    ]

    llm_prompt = format_for_llm(triggered, results) if (triggered or req.query) else None

    elapsed_ms = round((time.perf_counter() - t0) * 1000)

    return RetrieveResponse(
        alerts=req.alerts,
        interventions=interventions,
        llm_prompt=llm_prompt,
        meta={
            "elapsed_ms": elapsed_ms,
            "alert_matches": sum(1 for r in results if r.source == "alert_match"),
            "semantic_matches": sum(1 for r in results if r.source == "semantic"),
            "total": len(results),
        },
    )


# ── Entrypoint ────────────────────────────────────────────────────────────── #

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8741))
    uvicorn.run("server:app", host="127.0.0.1", port=port, reload=False)
