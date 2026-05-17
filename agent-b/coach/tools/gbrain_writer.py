"""Per-agent gbrain writer.

The existing `coach.tools.gbrain` module wraps the system `gbrain` CLI
using the caller's $HOME. For the *coach's own* gbrain we need HOME
pinned at the coach gbrain dir regardless of the caller's environment.

This wrapper exists so the rule engine + watch loop can write insights
into the coach's brain without leaking writes into the user's default
gbrain or (worse) the collector's gbrain.

Resolution order for the gbrain HOME:
  1. `COACH_GBRAIN_HOME` env var
  2. `/home/alexgodo/g-stack-hackathon/infra/data/gbrain-coach-home`
     (the canonical path on the VM)
  3. `~/g-stack-hackathon/infra/data/gbrain-coach-home`
     (local-dev path)
"""

from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path
from typing import Optional


log = logging.getLogger("coach.tools.gbrain_writer")


class GbrainCLIError(RuntimeError):
    pass


class GbrainCLI:
    """Thin shell over `HOME=<coach home> gbrain <subcommand>`.

    Methods:
        put(slug, markdown)   — write or overwrite a page
        get(slug) -> str|None — read a page; returns None if missing
        search(q) -> list[str] — slugs ranked by keyword search
    """

    def __init__(self, *, home: Optional[str] = None, binary: str = "gbrain"):
        self.home = home or _resolve_home()
        self.binary = binary

    def _run(self, args: list[str], *, input_text: Optional[str] = None,
             timeout: float = 60.0) -> str:
        env = {**os.environ, "HOME": self.home}
        try:
            cp = subprocess.run(
                [self.binary, *args],
                input=input_text,
                env=env,
                check=True,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            return cp.stdout
        except subprocess.CalledProcessError as e:
            raise GbrainCLIError(
                f"gbrain {args[0]} failed (rc={e.returncode}): {e.stderr.strip()[:200]}"
            )
        except subprocess.TimeoutExpired:
            raise GbrainCLIError(f"gbrain {args[0]} timed out after {timeout}s")
        except FileNotFoundError as e:
            raise GbrainCLIError(f"gbrain CLI not on PATH: {e}")

    def put(self, slug: str, markdown: str) -> None:
        self._run(["put", slug], input_text=markdown)

    def get(self, slug: str) -> Optional[str]:
        try:
            return self._run(["get", slug])
        except GbrainCLIError as e:
            if "not found" in str(e).lower() or "404" in str(e):
                return None
            raise


def _resolve_home() -> str:
    env = os.environ.get("COACH_GBRAIN_HOME")
    if env:
        return env
    for candidate in (
        "/home/alexgodo/g-stack-hackathon/infra/data/gbrain-coach-home",
        os.path.expanduser("~/g-stack-hackathon/infra/data/gbrain-coach-home"),
    ):
        if Path(candidate).exists():
            return candidate
    # Last resort — current HOME (will work in a freshly inited env).
    return os.path.expanduser("~")
