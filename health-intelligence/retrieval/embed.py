"""
Embedding engine. Encodes all InterventionRecords once, caches to disk.
On subsequent runs loads from cache — no re-encoding needed.

Backend: sentence-transformers (local, no API key).
Model: all-MiniLM-L6-v2  — 384-dim, ~80 MB, fast on CPU, strong at
       sentence-level semantic similarity.

Cache: numpy .npz in health-intelligence/data/embed_cache.npz
       Invalidated automatically when the source JSON files change.
"""

from __future__ import annotations
import hashlib
import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from .index import InterventionRecord

log = logging.getLogger(__name__)

_DATA       = Path(__file__).parent.parent / "data"
_CACHE_FILE = _DATA / "embed_cache.npz"
_MODEL_NAME = "all-MiniLM-L6-v2"


def _source_hash() -> str:
    """SHA-256 over both source JSON files — cache key."""
    h = hashlib.sha256()
    for fname in sorted(["health_metrics.json", "prescriptive_papers.json"]):
        h.update((fname + ":").encode())
        h.update((_DATA / fname).read_bytes())
    return h.hexdigest()


class EmbeddingStore:
    """
    Loads or builds embeddings for every InterventionRecord.

    Attributes
    ----------
    embeddings : np.ndarray  shape (N, 384), float32, L2-normalised
    records    : list[InterventionRecord]  same order as embeddings
    """

    def __init__(self, records: list["InterventionRecord"]) -> None:
        self.records = records
        self.embeddings = self._load_or_build(records)

    # ------------------------------------------------------------------ #

    def _load_or_build(self, records: list["InterventionRecord"]) -> np.ndarray:
        current_hash = _source_hash()

        if _CACHE_FILE.exists():
            cache = np.load(_CACHE_FILE, allow_pickle=False)
            if cache.get("hash", np.array([""]))[0] == current_hash:
                log.info("Loaded embeddings from cache (%d records).", len(records))
                return cache["embeddings"].astype(np.float32)
            log.info("Cache invalidated — rebuilding embeddings.")

        return self._build_and_cache(records, current_hash)

    def _build_and_cache(
        self,
        records: list["InterventionRecord"],
        source_hash: str,
    ) -> np.ndarray:
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as exc:
            raise ImportError(
                "sentence-transformers is required. "
                "Run: pip install sentence-transformers"
            ) from exc

        log.info("Encoding %d intervention records with %s…", len(records), _MODEL_NAME)
        model  = SentenceTransformer(_MODEL_NAME)
        docs   = [r.document for r in records]
        raw    = model.encode(docs, batch_size=64, show_progress_bar=True,
                              convert_to_numpy=True, normalize_embeddings=True)
        embs   = raw.astype(np.float32)

        np.savez_compressed(
            _CACHE_FILE,
            embeddings=embs,
            hash=np.array([source_hash]),
        )
        log.info("Embeddings cached to %s.", _CACHE_FILE)
        return embs

    # ------------------------------------------------------------------ #

    def query(self, query_text: str, top_k: int = 5) -> list[tuple[float, "InterventionRecord"]]:
        """
        Encode query_text, return top_k (score, record) pairs sorted desc.
        Scores are cosine similarities in [0, 1] (embeddings are L2-normalised).
        """
        qvec  = self._model().encode([query_text], normalize_embeddings=True,
                                      convert_to_numpy=True)[0].astype(np.float32)
        scores = (self.embeddings @ qvec).tolist()
        ranked = sorted(zip(scores, self.records), key=lambda x: x[0], reverse=True)
        return ranked[:top_k]

    def _model(self):
        """Lazy-load and cache the SentenceTransformer — one instance per store."""
        if not hasattr(self, "_cached_model"):
            try:
                from sentence_transformers import SentenceTransformer
            except ImportError as exc:
                raise ImportError("pip install sentence-transformers") from exc
            self._cached_model = SentenceTransformer(_MODEL_NAME)
        return self._cached_model
