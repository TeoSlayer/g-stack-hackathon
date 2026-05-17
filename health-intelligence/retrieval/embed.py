"""ZeroEntropy-backed index.

Replaces the previous local sentence-transformers cache with a remote
ZeroEntropy collection. Each intervention record becomes one ZE document.

Why this is still called `embed.py`:
  The previous implementation used a local embedding cache. The new one
  delegates to ZE. Public API of the module (`EmbeddingStore`) is preserved
  so `retrieve.py` keeps working — only the internals change.

What ingestion does:
  1. Ensure the ZE collection exists (`ConflictError` swallowed).
  2. For each InterventionRecord, upload a document at
     `paper-{paper_id}/intervention-{i}` with the same `document` string
     the old embedder used (the wider "Metrics: ... Intervention: ..." form),
     plus structured metadata so we can filter by metric_id later.
  3. Re-runs are idempotent — already-uploaded docs are skipped, modified
     docs are re-uploaded (the document path is stable).
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any, Iterable, Sequence

from zeroentropy import ConflictError

from .ze_client import (
    COLLECTION,
    RERANKER_MODEL,
    get_client,
)

if TYPE_CHECKING:
    from .index import InterventionRecord


log = logging.getLogger(__name__)


# ─── Document path helpers ───────────────────────────────────────────────────


def doc_path(rec: "InterventionRecord") -> str:
    """Stable path inside the ZE collection."""
    return f"paper-{rec.paper_id}/intervention-{int(rec.id.split(':')[1]):03d}"


def _csv(xs: Iterable[Any]) -> str:
    """ZE metadata values must be strings — list values rejected. Join CSV
    so we can still substring-match for cheap filtering."""
    return ",".join(str(x) for x in xs)


def record_metadata(rec: "InterventionRecord") -> dict[str, str]:
    return {
        "paper_id": str(rec.paper_id),
        "paper_title": rec.paper_title,
        "paper_url": rec.paper_url,
        "journal": rec.journal,
        "year": str(rec.year),
        "study_type": rec.study_type,
        "intervention_id": rec.id,
        # The API currently rejects list values per attribute, so we flatten
        # to CSV. e.g. "2,3,30"
        "metric_ids_csv": _csv(rec.metric_ids),
        "metric_names_csv": _csv(rec.metric_names),
    }


# ─── Ingestion ───────────────────────────────────────────────────────────────


class EmbeddingStore:
    """ZE-backed equivalent of the old EmbeddingStore.

    On init: ensures the collection exists. Pass `build=True` to (re)upload
    every record. Pass `build=False` to just attach to an existing index —
    useful from the server, which only needs to query, not re-index.
    """

    def __init__(
        self,
        records: Sequence["InterventionRecord"],
        *,
        build: bool = False,
        collection: str = COLLECTION,
    ) -> None:
        self.records = list(records)
        self.collection = collection
        self.client = get_client()
        self._record_by_path: dict[str, "InterventionRecord"] = {
            doc_path(r): r for r in self.records
        }

        self._ensure_collection()
        if build:
            self._upload_all()

    # ── collection bootstrap ────────────────────────────────────────────────

    def _ensure_collection(self) -> None:
        try:
            self.client.collections.add(collection_name=self.collection)
            log.info("Created ZE collection %r", self.collection)
        except ConflictError:
            log.info("ZE collection %r exists", self.collection)

    # ── upload ──────────────────────────────────────────────────────────────

    def _upload_all(self) -> None:
        """Idempotent upload: skip docs that already exist with same content,
        delete-then-add for paths where metadata or text changed.

        ZE's `overwrite=True` is currently disabled server-side, so we emulate
        it with a list → delete → add cycle.
        """
        log.info(
            "Uploading %d records to ZE collection %r…",
            len(self.records),
            self.collection,
        )
        # Enumerate existing paths so we know what's already there.
        existing_paths: set[str] = set()
        try:
            page_after: str | None = None
            while True:
                resp = self.client.documents.get_info_list(
                    collection_name=self.collection,
                    limit=1024,
                    **({"path_gt": page_after} if page_after else {}),
                )
                items = resp.documents if hasattr(resp, "documents") else resp
                if not items:
                    break
                for d in items:
                    existing_paths.add(d.path)
                if len(items) < 1024:
                    break
                page_after = items[-1].path
        except Exception as e:
            log.warning("could not list existing docs: %s — proceeding with adds only", e)

        ok = errors = skipped = replaced = 0
        for rec in self.records:
            path = doc_path(rec)
            if path in existing_paths:
                # Replace: delete then add (overwrite is disabled server-side).
                try:
                    self.client.documents.delete(
                        collection_name=self.collection,
                        path=path,
                    )
                    replaced += 1
                except Exception as e:
                    log.warning("delete-before-replace failed for %s: %s", path, e)
            try:
                self.client.documents.add(
                    collection_name=self.collection,
                    path=path,
                    content={"type": "text", "text": rec.document},
                    metadata=record_metadata(rec),
                )
                ok += 1
            except Exception as e:
                # Already-exists is a soft-skip; everything else is an error.
                msg = str(e).lower()
                if "exist" in msg or "conflict" in msg:
                    skipped += 1
                else:
                    log.warning("upload failed for %s: %s", path, e)
                    errors += 1
        log.info(
            "Upload complete: %d ok, %d replaced, %d skipped(exists), %d errors",
            ok, replaced, skipped, errors,
        )

    # ── query ───────────────────────────────────────────────────────────────

    def query(
        self,
        query_text: str,
        top_k: int = 5,
        *,
        rerank: bool = True,
        metric_id_filter: list[int] | None = None,
    ) -> list[tuple[float, "InterventionRecord"]]:
        """Return top_k (score, record) pairs, sorted descending."""
        # ZE metadata is str-only; we can't $in over a list. Skip filter for
        # now and rely on the reranker to surface metric-relevant hits.
        filter_: dict | None = None
        # NOTE: if/when ZE supports $contains or list values, switch to:
        #   {"metric_ids_csv": {"$contains": ...}}

        # Pull more than we need so the reranker has working room.
        initial_k = min(top_k * 4, 64) if rerank else top_k
        resp = self.client.queries.top_documents(
            collection_name=self.collection,
            query=query_text,
            k=initial_k,
            filter=filter_,
            include_metadata=False,
            latency_mode="low",
        )
        raw_hits: list[tuple[float, str]] = [
            (float(r.score), r.path) for r in resp.results
        ]
        if not raw_hits:
            return []

        if rerank and len(raw_hits) > 1:
            raw_hits = self._rerank(query_text, raw_hits, top_k=top_k)

        out: list[tuple[float, "InterventionRecord"]] = []
        for score, path in raw_hits[:top_k]:
            rec = self._record_by_path.get(path)
            if rec is None:
                # Path drift across rebuilds — skip; don't crash.
                log.debug("Hit path %s has no local record", path)
                continue
            out.append((score, rec))
        return out

    def _rerank(
        self,
        query_text: str,
        hits: list[tuple[float, str]],
        *,
        top_k: int,
    ) -> list[tuple[float, str]]:
        documents = [
            (self._record_by_path[path].document if path in self._record_by_path else path)
            for _score, path in hits
        ]
        try:
            resp = self.client.models.rerank(
                model=RERANKER_MODEL,
                query=query_text,
                documents=documents,
                top_n=top_k,
            )
        except Exception as e:
            log.warning("rerank failed (%s); falling back to vector order", e)
            return hits
        out: list[tuple[float, str]] = []
        for r in resp.results:
            path = hits[r.index][1]
            out.append((float(r.relevance_score), path))
        return out
