"""
build_index.py — run once to upload every intervention record to ZeroEntropy.

    python build_index.py

This scans all 17 papers in `data/prescriptive_papers.json`, cross-references
metric names from `data/health_metrics.json`, builds one document per
intervention sentence, and uploads them to the ZE collection named
`health-intelligence` (overridable via `ZE_COLLECTION`).

Re-runs are idempotent — documents are overwritten by path so the index
always reflects the current JSON.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(message)s")
log = logging.getLogger(__name__)

sys.path.insert(0, str(Path(__file__).parent))

from retrieval.embed import EmbeddingStore
from retrieval.index import MetricIndex
from retrieval.ze_client import COLLECTION, get_client


def main() -> None:
    log.info("Loading metric index…")
    idx = MetricIndex()
    log.info("%r", idx)

    covered = idx.covered_metric_ids()
    all_ids = set(idx._metrics.keys())
    uncovered = all_ids - covered

    log.info("Metrics covered by at least one paper : %s", sorted(covered))
    log.info("Metrics with no papers yet             : %s", sorted(uncovered))
    log.info("")

    log.info("Ensuring ZE collection %r and uploading documents…", COLLECTION)
    store = EmbeddingStore(idx.records, build=True)

    log.info("")
    log.info("Querying ZE for collection status…")
    status = get_client().status.get_status(collection_name=COLLECTION)
    log.info(
        "  collection=%r  documents=%d  indexed=%d  parsing=%d  indexing=%d  failed=%d",
        COLLECTION,
        status.num_documents,
        status.num_indexed_documents,
        status.num_parsing_documents,
        status.num_indexing_documents,
        status.num_failed_documents,
    )

    # Smoke test: query each paper's title and confirm at least one of its
    # interventions surfaces in the top results.
    log.info("")
    log.info("=== Smoke test — querying each paper title ===")
    errors = 0
    paper_ids_with_records = sorted({r.paper_id for r in idx.records})
    for paper_id in paper_ids_with_records:
        paper_records = [r for r in idx.records if r.paper_id == paper_id]
        query = paper_records[0].paper_title
        hits = store.query(query, top_k=len(paper_records) + 3, rerank=False)
        hit_ids = {rec.paper_id for _score, rec in hits}
        ok = paper_id in hit_ids
        status_label = "OK" if ok else "MISS"
        if not ok:
            errors += 1
        log.info("  Paper %2d  %-7s  %s", paper_id, status_label, query[:70])

    log.info("")
    if errors == 0:
        log.info("All %d papers self-retrieve correctly. Index ready.", len(paper_ids_with_records))
    else:
        log.warning("%d paper(s) failed self-retrieval — investigate before relying on results.", errors)


if __name__ == "__main__":
    main()
