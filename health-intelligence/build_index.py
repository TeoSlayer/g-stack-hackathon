"""
build_index.py — run once to encode all intervention records and cache embeddings.

    python build_index.py

This scans all 17 papers in prescriptive_papers.json, embeds every intervention
sentence using all-MiniLM-L6-v2, and writes data/embed_cache.npz.

Subsequent calls to retrieve_interventions() load from cache instantly.
Re-run whenever either JSON file changes (cache is hash-invalidated automatically).
"""

import logging
import sys
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(levelname)s  %(message)s")
log = logging.getLogger(__name__)

sys.path.insert(0, str(Path(__file__).parent))

from retrieval.index import MetricIndex
from retrieval.embed import EmbeddingStore


def main() -> None:
    log.info("Loading metric index…")
    idx = MetricIndex()
    log.info("%r", idx)

    covered   = idx.covered_metric_ids()
    all_ids   = set(idx._metrics.keys())
    uncovered = all_ids - covered

    log.info("Metrics covered by at least one paper : %s", sorted(covered))
    log.info("Metrics with no papers yet             : %s", sorted(uncovered))
    log.info("")

    log.info("Building / loading embedding store…")
    store = EmbeddingStore(idx.records)
    log.info(
        "Embeddings ready: %d records, shape %s",
        len(store.records), store.embeddings.shape,
    )

    # Smoke-test: query each paper's own title and verify its interventions
    # land in the top results.
    log.info("")
    log.info("=== Smoke test — querying each paper against its own interventions ===")
    errors = 0
    for paper_id in range(1, 18):
        paper_records = [r for r in idx.records if r.paper_id == paper_id]
        if not paper_records:
            continue
        query = paper_records[0].paper_title
        hits  = store.query(query, top_k=len(paper_records) + 3)
        hit_ids = {h[1].paper_id for h in hits}
        ok = paper_id in hit_ids
        status = "OK" if ok else "MISS"
        if not ok:
            errors += 1
        log.info("  Paper %2d  %-7s  %s", paper_id, status, query[:70])

    log.info("")
    if errors == 0:
        log.info("All %d papers self-retrieve correctly. Index ready.", 17)
    else:
        log.warning("%d paper(s) failed self-retrieval — check embedding quality.", errors)


if __name__ == "__main__":
    main()
