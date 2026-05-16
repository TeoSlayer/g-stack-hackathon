"""Coach client core.

Two entry points:

  - `send_query(sql, ...) -> dict`        : fire-and-wait for a QueryResult
  - `watch_change_events(callback) -> ()` : long-running listener loop

Both use a `Pilot` abstraction (below) so the same client code works against
the real `pilotctl send-message` binary or a stub pilot (shared-volume file
drops). Selection is via the `COACH_PILOT_MODE` env var:
  - `pilotctl` — shells out to pilotctl (production)
  - `stub`     — drops files into a shared inbox/outbox volume (demo)
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional


log = logging.getLogger("coach.client")


# ─── Pilot abstraction ───────────────────────────────────────────────────────

class Pilot:
    """Send a message to a peer; receive messages from local inbox."""

    def send(self, target: str, body: dict) -> bool: ...
    def receive(self, predicate: Callable[[dict], bool], timeout_s: float) -> Optional[dict]: ...
    def inbox_iter(self): ...


class StubPilot(Pilot):
    """Shared-volume file-based pilot stand-in.

    Each container has its own inbox dir. To send to a peer, drop a file in
    the peer's inbox. The peer's daemon (collector or coach) picks it up.

    Layout (set via env):
      COACH_INBOX        — this Coach's inbox (where replies & events land)
      COLLECTOR_INBOX    — Collector's inbox (where queries get dropped)
    """

    def __init__(
        self,
        *,
        own_identity: str,
        own_inbox: Path,
        peer_inbox: Path,
    ):
        self.own_identity = own_identity
        self.own_inbox = Path(own_inbox)
        self.peer_inbox = Path(peer_inbox)
        self.own_inbox.mkdir(parents=True, exist_ok=True)
        self.peer_inbox.mkdir(parents=True, exist_ok=True)
        self._seq = 0

    def send(self, target: str, body: dict) -> bool:
        self._seq += 1
        # Mirror the Pilot wrapper shape: the receiver's unwrap_pilot_transport
        # will pull `data` (stringified JSON) and `agent` (sender).
        wrapped = {
            "agent": self.own_identity,
            "target": target,
            "command": "ingest" if "samples" in body else "query",
            "data": json.dumps(body),
        }
        name = f"{time.time():.6f}-from-{self.own_identity}-{self._seq}.json"
        (self.peer_inbox / name).write_text(json.dumps(wrapped))
        return True

    def receive(self, predicate: Callable[[dict], bool], timeout_s: float) -> Optional[dict]:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            for p in sorted(self.own_inbox.iterdir()):
                if p.name.startswith(".") or p.suffix != ".json" or not p.is_file():
                    continue
                try:
                    obj = json.loads(p.read_text())
                except Exception:
                    continue
                # Unwrap if needed
                inner = obj
                if isinstance(obj.get("data"), str):
                    try:
                        inner = json.loads(obj["data"])
                    except Exception:
                        pass
                elif "body" in obj and isinstance(obj["body"], dict):
                    inner = obj["body"]
                if predicate(inner):
                    p.unlink()
                    return inner
            time.sleep(0.05)
        return None

    def inbox_iter(self):
        for p in sorted(self.own_inbox.iterdir()):
            if p.name.startswith(".") or p.suffix != ".json" or not p.is_file():
                continue
            try:
                obj = json.loads(p.read_text())
            except Exception:
                continue
            inner = obj
            if isinstance(obj.get("data"), str):
                try:
                    inner = json.loads(obj["data"])
                except Exception:
                    pass
            elif "body" in obj and isinstance(obj["body"], dict):
                inner = obj["body"]
            yield inner, p


class PilotctlPilot(Pilot):
    """Send via `pilotctl send-message`; receive by tailing ~/.pilot/inbox."""

    def __init__(self, *, own_identity: str, own_inbox: Path, binary: str = "pilotctl"):
        self.own_identity = own_identity
        self.own_inbox = Path(own_inbox)
        self.binary = binary

    def send(self, target: str, body: dict) -> bool:
        try:
            subprocess.run(
                [self.binary, "send-message", target, "--data", json.dumps(body)],
                check=True, capture_output=True, timeout=10,
            )
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
            log.warning("pilotctl send failed: %s", e)
            return False

    def receive(self, predicate: Callable[[dict], bool], timeout_s: float) -> Optional[dict]:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            for obj, p in list(self._scan()):
                if predicate(obj):
                    try:
                        p.unlink()
                    except FileNotFoundError:
                        pass
                    return obj
            time.sleep(0.05)
        return None

    def inbox_iter(self):
        yield from self._scan()

    def _scan(self):
        if not self.own_inbox.exists():
            return
        for p in sorted(self.own_inbox.iterdir()):
            if p.name.startswith(".") or p.suffix != ".json" or not p.is_file():
                continue
            try:
                obj = json.loads(p.read_text())
            except Exception:
                continue
            inner = obj
            if isinstance(obj.get("data"), str):
                try:
                    inner = json.loads(obj["data"])
                except Exception:
                    pass
            yield inner, p


def make_pilot_from_env() -> Pilot:
    mode = os.environ.get("COACH_PILOT_MODE", "stub")
    identity = os.environ.get("COACH_IDENTITY", "coach.local")
    inbox = Path(os.environ.get("COACH_INBOX", "/var/coach_inbox"))
    if mode == "pilotctl":
        return PilotctlPilot(own_identity=identity, own_inbox=inbox)
    peer = Path(os.environ.get("COLLECTOR_INBOX", "/var/collector_inbox"))
    return StubPilot(own_identity=identity, own_inbox=inbox, peer_inbox=peer)


# ─── Coach API ───────────────────────────────────────────────────────────────

@dataclass
class CoachConfig:
    collector_identity: str = "collector"
    reply_port: int = 1005
    query_timeout_s: float = 30.0

    @classmethod
    def from_env(cls) -> "CoachConfig":
        # 90s default: Pilot's NAT-relay path (registry-mediated) regularly
        # adds 30–60s of latency on a query/result round-trip. 30s wasn't
        # enough in practice; bumping is the right call for now.
        return cls(
            collector_identity=os.environ.get("COLLECTOR_NODE_ID", "collector"),
            reply_port=int(os.environ.get("COACH_REPLY_PORT", 1005)),
            query_timeout_s=float(os.environ.get("COACH_QUERY_TIMEOUT_S", 90)),
        )


class Coach:
    def __init__(self, pilot: Pilot, config: Optional[CoachConfig] = None):
        self.pilot = pilot
        self.config = config or CoachConfig.from_env()

    def query(self, sql: str, params: Optional[list] = None,
              limit: Optional[int] = None) -> dict:
        """Send a SQL query to the Collector and wait for the result."""
        request_id = str(uuid.uuid4())
        body = {
            "v": 1,
            "request_id": request_id,
            "reply_port": self.config.reply_port,
            "kind": "sql",
            "sql": sql,
            "params": params or [],
        }
        if limit is not None:
            body["limit"] = limit
        self.pilot.send(self.config.collector_identity, body)
        result = self.pilot.receive(
            predicate=lambda m: isinstance(m, dict) and m.get("request_id") == request_id,
            timeout_s=self.config.query_timeout_s,
        )
        if result is None:
            return {"ok": False, "error": {"code": "timeout",
                                            "message": f"no reply within {self.config.query_timeout_s}s"}}
        return result

    def consume_change_events(self, callback: Callable[[dict], None]):
        """Drain any pending ChangeEvents from the inbox and pass to callback."""
        for msg, path in list(self.pilot.inbox_iter()):
            if isinstance(msg, dict) and msg.get("kind") == "samples_added":
                callback(msg)
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
