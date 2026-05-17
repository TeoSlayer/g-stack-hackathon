"""Inbox-driven dispatcher.

Watches a directory (typically ~/.pilot/inbox) for *.json files and routes
each one based on its detected shape:

  envelope     → ingester.process_envelope        → Ack on ack_port
  route_chunk  → ingester.process_route_chunk     → Ack on ack_port
  query        → sql_gate.handle_query            → QueryResult on reply_port
  pilot reply  → passed through to a sink         (preserves the gbrain path)
  unknown      → left in place for the heartbeat agent

After successful processing, the file moves to <inbox>/.archive/. On error,
it moves to <inbox>/.unrecognized/ so it can be inspected.

This file's main() is the production entry point: a polling daemon that
sleeps `poll_interval_s` between scans (default 1.0s, well inside the
source's 30s ack budget).
"""

from __future__ import annotations

import json
import logging
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from .change_event import ChangeEventBroadcaster
from .ingester import process_envelope, process_route_chunk
from .schema import classify_message
from .sql_gate import handle_query
from .transport import Outgoing, Transport
from .trust import TrustPolicy
from .warehouse import Warehouse


log = logging.getLogger("collector.inbox")


# ─── Pilot transport wrapper unwrap ──────────────────────────────────────────

def unwrap_pilot_transport(obj: dict) -> tuple[dict, Optional[str]]:
    """Mirror of the JS ingester's unwrap.

    Pilot's inbox files commonly look like one of:
      { "agent": "...", "command": "...", "data": "<stringified-json>" }
      { "payload": { ... } }
      { "body": { ... } }
      { "from": "...", "type": "BINARY", "data_b64": "<base64>", "bytes": N }
                  ↑ iOS HealthSync envelope: gzipped → base64. We decode here.
      <inner payload directly>

    Returns (inner, sender_identity). sender_identity is the Pilot agent that
    sent the message, used as the source identity for trust checks AND as
    the reply target when sending Acks.
    """
    if not isinstance(obj, dict):
        return obj, None
    sender = obj.get("agent") or obj.get("from") or obj.get("sender")

    # iOS HealthSync ships envelopes as deflate-compressed JSON in base64.
    # Pilot's daemon writes them to disk as `BINARY-*.json` with shape
    # `{ from, bytes, data_b64, received_at, type: "BINARY" }`.
    #
    # iOS specifically uses RAW deflate (no zlib header) — wbits=-15. We also
    # try standard zlib, auto (gzip + zlib), and raw-bytes-as-JSON fallback so
    # other Pilot peers can send the same envelope shape without coordination.
    if isinstance(obj.get("data_b64"), str):
        try:
            import base64 as _b64
            import zlib as _zlib
            raw = _b64.b64decode(obj["data_b64"])
            decompressed = None
            for wbits in (-15, 15, 47):  # raw deflate (iOS), zlib, auto-detect
                try:
                    decompressed = _zlib.decompress(raw, wbits)
                    break
                except _zlib.error:
                    continue
            if decompressed is None:
                decompressed = raw  # fall through: maybe it's plain JSON bytes
            inner = json.loads(decompressed)
            if isinstance(inner, dict):
                return inner, sender
        except Exception as e:
            log.warning("BINARY decode failed: %s", e)

    if isinstance(obj.get("data"), str):
        try:
            inner = json.loads(obj["data"])
            if isinstance(inner, dict):
                return inner, sender
        except Exception:
            pass
    if isinstance(obj.get("payload"), dict):
        return obj["payload"], sender
    if isinstance(obj.get("body"), dict):
        return obj["body"], sender
    return obj, sender


# ─── Watcher ─────────────────────────────────────────────────────────────────

@dataclass
class WatcherConfig:
    inbox_dir: Path
    archive_dir: Path
    unrecognized_dir: Path
    poll_interval_s: float = 1.0
    # Optional callback for files classified as "pilot-reply" (the existing
    # gbrain archive path). Receives the raw obj and the source file path.
    pilot_reply_sink: Optional[Callable[[dict, Path], None]] = None
    # Optional callback after a successful envelope ingest, called with the
    # validated Envelope object and the raw dict. Generic post-ingest hook
    # for operators who want to wire side effects without forking the watcher.
    envelope_hook: Optional[Callable] = None


class InboxWatcher:
    def __init__(
        self,
        *,
        config: WatcherConfig,
        warehouse: Warehouse,
        trust: TrustPolicy,
        transport: Transport,
        events: ChangeEventBroadcaster,
    ):
        self.config = config
        self.warehouse = warehouse
        self.trust = trust
        self.transport = transport
        self.events = events
        self._stop = False

        for p in (config.inbox_dir, config.archive_dir, config.unrecognized_dir):
            p.mkdir(parents=True, exist_ok=True)

    def stop(self):
        self._stop = True

    def tick(self) -> dict:
        """One pass over the inbox. Returns a small counters dict."""
        counters = {
            "envelopes": 0, "route_chunks": 0, "queries": 0,
            "pilot_replies": 0, "unknown": 0, "errors": 0,
        }
        for path in sorted(self.config.inbox_dir.iterdir()):
            if path.name.startswith(".") or not path.is_file() or path.suffix != ".json":
                continue
            try:
                obj = json.loads(path.read_text())
            except Exception as e:
                log.warning("unparseable %s: %s", path.name, e)
                self._move(path, self.config.unrecognized_dir)
                counters["errors"] += 1
                continue

            inner, sender = unwrap_pilot_transport(obj)
            kind = classify_message(inner)
            try:
                if kind == "envelope":
                    self._handle_envelope(inner, sender)
                    counters["envelopes"] += 1
                elif kind == "route_chunk":
                    self._handle_route_chunk(inner, sender)
                    counters["route_chunks"] += 1
                elif kind == "query":
                    self._handle_query(inner, sender)
                    counters["queries"] += 1
                elif self._looks_like_pilot_reply(inner):
                    counters["pilot_replies"] += 1
                    if self.config.pilot_reply_sink:
                        self.config.pilot_reply_sink(inner, path)
                        self._move(path, self.config.archive_dir)
                    else:
                        # Not our responsibility — leave for the existing
                        # gbrain JS ingester to handle on its next 5-min tick.
                        log.info("pilot-reply left for gbrain ingester: %s", path.name)
                    continue
                else:
                    log.info("leaving-in-inbox %s keys=%s", path.name, list(obj.keys())[:8])
                    counters["unknown"] += 1
                    # Do NOT move — leave for heartbeat/pilotctl inbox to surface.
                    continue
                self._move(path, self.config.archive_dir)
            except Exception as e:
                log.exception("error processing %s: %s", path.name, e)
                self._move(path, self.config.unrecognized_dir)
                counters["errors"] += 1
        return counters

    def run(self):
        log.info("collector watcher started on %s", self.config.inbox_dir)
        while not self._stop:
            self.tick()
            time.sleep(self.config.poll_interval_s)

    # ── handlers ────────────────────────────────────────────────────────────

    def _handle_envelope(self, raw: dict, sender: Optional[str]):
        result = process_envelope(
            raw, warehouse=self.warehouse, trust=self.trust, source_identity=sender,
        )
        if result.ack is not None:
            self.transport.send(Outgoing(
                target=sender, port=result.ack_port,
                body=result.ack.model_dump(), kind="ack",
            ))
        if result.change_event is not None:
            self.events.emit(result.change_event)
        # Post-ingest hook (e.g. gbrain markdown rollup)
        if result.ok and self.config.envelope_hook is not None:
            from .schema import Envelope
            try:
                env_obj = Envelope.model_validate(raw)
                self.config.envelope_hook(env_obj, raw)
            except Exception as e:
                log.warning("envelope_hook failed for batch=%s: %s",
                            raw.get("batch_id"), e)
        log.info(
            "envelope ok=%s batch=%s accepted=%d duplicates=%d rejected=%d dup_batch=%s",
            result.ok, raw.get("batch_id"),
            len(result.accepted_uuids), len(result.duplicate_uuids),
            len(result.rejected_uuids), result.duplicate_batch,
        )

    def _handle_route_chunk(self, raw: dict, sender: Optional[str]):
        result = process_route_chunk(
            raw, warehouse=self.warehouse, trust=self.trust, source_identity=sender,
        )
        if result.ack is not None:
            self.transport.send(Outgoing(
                target=sender, port=result.ack_port,
                body=result.ack.model_dump(), kind="ack",
            ))
        if result.change_event is not None:
            self.events.emit(result.change_event)
        log.info(
            "route_chunk ok=%s workout=%s chunk=%s",
            result.ok, raw.get("workout_uuid"), raw.get("chunk_idx"),
        )

    def _handle_query(self, raw: dict, sender: Optional[str]):
        result = handle_query(
            raw, warehouse=self.warehouse, trust=self.trust, coach_identity=sender,
        )
        reply_port = int(raw.get("reply_port", 0)) or 1005
        self.transport.send(Outgoing(
            target=sender, port=reply_port,
            body=result.model_dump(by_alias=True), kind="query_result",
        ))
        log.info(
            "query ok=%s rid=%s rows=%d ms=%d",
            result.ok, raw.get("request_id"), result.row_count, result.ms,
        )

    @staticmethod
    def _looks_like_pilot_reply(obj: dict) -> bool:
        return (
            isinstance(obj, dict)
            and isinstance(obj.get("agent"), str)
            and isinstance(obj.get("command"), str)
            and "samples" not in obj
            and "sql" not in obj
        )

    def _move(self, src: Path, dst_dir: Path):
        try:
            dst = dst_dir / src.name
            if dst.exists():
                dst.unlink()
            shutil.move(str(src), str(dst))
        except Exception as e:
            log.warning("move failed %s -> %s: %s", src, dst_dir, e)
