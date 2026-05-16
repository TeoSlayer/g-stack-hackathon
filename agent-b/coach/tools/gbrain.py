"""gbrain bridge for the Coach.

Wraps the gbrain CLI so the LLM (or rule loop) can search semantic memory,
read specific pages, and write new summaries. Read-mostly; only the Coach
writes (one voice keeps the brain coherent).
"""

from __future__ import annotations

import json
import logging
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


log = logging.getLogger("coach.tools.gbrain")


class GbrainError(RuntimeError):
    pass


def _run(args: list[str], *, input_text: Optional[str] = None,
         timeout: float = 30.0) -> str:
    try:
        cp = subprocess.run(
            ["gbrain", *args],
            input=input_text,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return cp.stdout
    except subprocess.CalledProcessError as e:
        raise GbrainError(f"gbrain {args[0]} failed: {e.stderr.strip() or e}")
    except FileNotFoundError as e:
        raise GbrainError(f"gbrain CLI not on PATH: {e}")
    except subprocess.TimeoutExpired:
        raise GbrainError(f"gbrain {args[0]} timed out after {timeout}s")


# ─── Read ────────────────────────────────────────────────────────────────────

@dataclass
class SearchHit:
    slug: str
    type: str
    date: str
    title: str
    snippet: Optional[str] = None


def search(query: str, *, limit: int = 5) -> list[SearchHit]:
    """gbrain search — keyword (tsvector) search."""
    out = _run(["search", query, "--limit", str(limit)])
    hits = []
    for line in out.splitlines():
        if not line.strip() or line.startswith("[ai.gateway]"):
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        hits.append(SearchHit(slug=parts[0], type=parts[1], date=parts[2], title=parts[3]))
    return hits


def query(question: str, *, expand: bool = True) -> str:
    """gbrain query — hybrid search with RRF and (optional) query expansion.

    Returns the gbrain CLI's natural-language answer string.
    """
    args = ["query", question]
    if not expand:
        args.append("--no-expand")
    return _run(args, timeout=120.0)


def get(slug: str) -> str:
    """Return the full markdown for a page."""
    return _run(["get", slug])


def list_pages(*, type: Optional[str] = None, tag: Optional[str] = None,
                limit: int = 25) -> list[dict]:
    args = ["list", "-n", str(limit)]
    if type:
        args.extend(["--type", type])
    if tag:
        args.extend(["--tag", tag])
    out = _run(args)
    rows = []
    for line in out.splitlines():
        if not line.strip() or line.startswith("[ai.gateway]"):
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        rows.append({"slug": parts[0], "type": parts[1], "date": parts[2], "title": parts[3]})
    return rows


# ─── Write (Coach is the sole writer) ────────────────────────────────────────

def put(slug: str, markdown: str) -> None:
    """Create or overwrite a page. Frontmatter is your responsibility."""
    _run(["put", slug], input_text=markdown, timeout=60.0)


def append_summary(slug: str, *, heading: str, body: str) -> None:
    """Idempotent helper: append a new `## heading` section under an existing
    page, or create the page with that section if missing.

    Useful for the Coach's "what I observed today" notes.
    """
    try:
        existing = get(slug)
    except GbrainError:
        existing = ""
    block = f"\n## {heading}\n\n{body.strip()}\n"
    new = (existing.rstrip() + "\n" + block) if existing else block
    put(slug, new)


def import_dir(path: Path, *, embed: bool = True) -> None:
    """Import a directory of markdown into gbrain (used after calendar sync)."""
    _run(["import", str(path), "--no-embed"], timeout=600.0)
    if embed:
        _run(["embed", "--stale"], timeout=1200.0)
