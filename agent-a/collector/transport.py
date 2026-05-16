"""Pluggable transport for Acks, QueryResults, and ChangeEvents.

Two backends:

  FileTransport    — writes messages to a directory on disk (used by tests
                     and by the watcher when no real Pilot peer is configured)
  PilotctlTransport — shells out to `pilotctl send-message <agent> --data <json>`
                      to deliver the message over the overlay network

A Transport doesn't know what message TYPE it's carrying — it just gets
(target, port, body) and either writes a file or hands it to pilotctl.
"""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Protocol


@dataclass
class Outgoing:
    target: Optional[str]  # Pilot identity to send to; None for broadcasts
    port: int
    body: dict
    kind: str              # "ack" | "query_result" | "change_event"


class Transport(Protocol):
    def send(self, msg: Outgoing) -> bool: ...


class FileTransport:
    """Append outgoing messages to a directory as JSON files.

    File name: <ts>-<kind>-<port>-<target_or_broadcast>-<seq>.json
    """

    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._seq = 0

    def send(self, msg: Outgoing) -> bool:
        self._seq += 1
        target = msg.target or "broadcast"
        safe_target = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in target)
        ts = f"{time.time():.6f}"
        path = self.root / f"{ts}-{msg.kind}-{msg.port}-{safe_target}-{self._seq}.json"
        payload = {
            "target": msg.target,
            "port": msg.port,
            "kind": msg.kind,
            "body": msg.body,
        }
        path.write_text(json.dumps(payload, indent=2, default=str))
        return True


class PilotctlTransport:
    """Send via `pilotctl send-message`. Best-effort; logs failures.

    Note: pilotctl does not surface a port flag in the standard CLI surface —
    the agent name is the routing key. We embed the intended port + kind
    inside the body so the receiving side can dispatch.
    """

    def __init__(self, binary: str = "pilotctl"):
        self.binary = binary

    def send(self, msg: Outgoing) -> bool:
        if msg.target is None:
            return False  # broadcasts not supported via pilotctl
        data = json.dumps({"__collector": {"kind": msg.kind, "port": msg.port},
                           **msg.body}, default=str)
        try:
            subprocess.run(
                [self.binary, "send-message", msg.target, "--data", data],
                check=True, capture_output=True, timeout=10,
            )
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
            return False


class TeeTransport:
    """Send to multiple transports — useful for keeping a file audit log
    while also dispatching via pilotctl."""

    def __init__(self, transports: list[Transport]):
        self.transports = transports

    def send(self, msg: Outgoing) -> bool:
        ok = False
        for t in self.transports:
            if t.send(msg):
                ok = True
        return ok
