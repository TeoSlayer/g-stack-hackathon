"""Thin wrapper around the ZeroEntropy SDK.

Centralises:
- API key resolution (supports both `ZEROENTROPY_API_KEY` — the SDK's default —
  and `ZERO_ENTROPY_API_KEY` — what our shared .env happens to use)
- The collection name (single source of truth)
- Default reranker model

All other modules import `get_client()` and `COLLECTION` from here.
"""

from __future__ import annotations

import os
from functools import lru_cache

from dotenv import load_dotenv
from zeroentropy import AsyncZeroEntropy, ZeroEntropy


# Pull in .env from the repo root if present (e.g. ~/g-stack-hackathon/.env).
load_dotenv()
load_dotenv(dotenv_path=os.path.expanduser("~/g-stack-hackathon/.env"), override=False)
load_dotenv(dotenv_path=os.path.expanduser("~/.env"), override=False)


COLLECTION = os.environ.get("ZE_COLLECTION", "health-intelligence")
RERANKER_MODEL = os.environ.get("ZE_RERANKER", "zerank-2")
EMBEDDING_MODEL = os.environ.get("ZE_EMBED_MODEL", "ze-default")


def _resolve_api_key() -> str:
    """Return the ZeroEntropy API key, mapping our project's env name to the
    SDK's expected one if needed."""
    key = os.environ.get("ZEROENTROPY_API_KEY") or os.environ.get("ZERO_ENTROPY_API_KEY")
    if not key:
        raise RuntimeError(
            "ZEROENTROPY_API_KEY (or ZERO_ENTROPY_API_KEY) is not set. "
            "Put it in ~/g-stack-hackathon/.env or export it in your shell."
        )
    # The SDK reads ZEROENTROPY_API_KEY only; make sure both are set.
    os.environ["ZEROENTROPY_API_KEY"] = key
    return key


@lru_cache(maxsize=1)
def get_client() -> ZeroEntropy:
    """Singleton sync ZeroEntropy client. Initialise lazily."""
    _resolve_api_key()
    return ZeroEntropy()


@lru_cache(maxsize=1)
def get_async_client() -> AsyncZeroEntropy:
    """Singleton async ZeroEntropy client. Use this in async/await code."""
    _resolve_api_key()
    return AsyncZeroEntropy()
