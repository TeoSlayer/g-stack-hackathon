"""ChangeEvent broadcast (port 1004).

The Collector fires a ChangeEvent after every batch commit with a `by_type`
histogram of what was newly accepted. Subscribed Coaches treat it as a hint
to re-query DuckDB — the event payload itself is informational.

Broadcast targets come from `TrustPolicy.subscribed_coaches()`. If the list
is empty, the event is still written to the file event log so a human (or
the heartbeat agent) can see that activity happened.
"""

from __future__ import annotations

from pathlib import Path
from typing import Iterable

from .schema import ChangeEvent
from .transport import FileTransport, Outgoing, Transport


CHANGE_EVENT_PORT = 1004


class ChangeEventBroadcaster:
    def __init__(
        self,
        *,
        transport: Transport,
        event_log_dir: str | Path,
        subscribers: Iterable[str] = (),
    ):
        self.transport = transport
        self.subscribers = list(subscribers)
        # Always tee to a local jsonl event log for observability.
        self._log = FileTransport(event_log_dir)

    def emit(self, event: ChangeEvent):
        body = event.model_dump()
        # Local audit log
        self._log.send(Outgoing(
            target=None, port=CHANGE_EVENT_PORT, body=body, kind="change_event",
        ))
        # Fan-out to subscribed coaches (no acks expected)
        for coach in self.subscribers:
            self.transport.send(Outgoing(
                target=coach, port=CHANGE_EVENT_PORT, body=body, kind="change_event",
            ))
