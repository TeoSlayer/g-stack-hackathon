"""Pilot BINARY envelope (zlib + base64) round-trip through the unwrap path."""

from __future__ import annotations

import base64
import json
import zlib

from collector.inbox_watcher import unwrap_pilot_transport
from collector.schema import classify_message


def _wrap_binary(envelope: dict, sender: str = "0:0000.0002.F2D1") -> dict:
    raw = zlib.compress(json.dumps(envelope).encode("utf-8"))
    return {
        "from": sender,
        "type": "BINARY",
        "bytes": len(raw),
        "data_b64": base64.b64encode(raw).decode("ascii"),
        "received_at": "2026-05-16T22:30:00Z",
    }


def test_binary_envelope_decoded_to_envelope():
    envelope = {
        "v": 1,
        "source": "ios.healthsync",
        "device_id": "iPhone-Amelina",
        "batch_id": "bin-test-1",
        "sent_at": 1701234567.0,
        "ack_port": 1002,
        "samples": [
            {
                "kind": "quantity", "uuid": "bin-hr",
                "type": "heartRate", "value": 67, "unit": "count/min",
                "start_utc": 1701234560.0, "end_utc": 1701234560.0,
                "source_name": "Apple Watch",
            }
        ],
        "workouts": [],
    }
    wrapper = _wrap_binary(envelope)
    inner, sender = unwrap_pilot_transport(wrapper)
    assert sender == "0:0000.0002.F2D1"
    assert inner["batch_id"] == "bin-test-1"
    assert inner["samples"][0]["uuid"] == "bin-hr"
    assert classify_message(inner) == "envelope"


def test_binary_envelope_uncompressed_fallback():
    # A BINARY message that's *not* zlib-compressed (just raw JSON in base64).
    envelope = {"source": "ios.healthsync", "batch_id": "bin-test-2",
                "samples": [], "v": 1, "device_id": "iPhone-Test",
                "sent_at": 0.0, "ack_port": 1002}
    raw = json.dumps(envelope).encode("utf-8")
    wrapper = {
        "from": "test", "type": "BINARY", "bytes": len(raw),
        "data_b64": base64.b64encode(raw).decode("ascii"),
    }
    inner, sender = unwrap_pilot_transport(wrapper)
    assert inner["batch_id"] == "bin-test-2"


def test_binary_envelope_garbage_falls_through():
    # data_b64 present but undecodable → unwrap should not raise.
    wrapper = {"from": "test", "type": "BINARY",
               "data_b64": "this is not base64 !!!"}
    inner, sender = unwrap_pilot_transport(wrapper)
    # Falls through to "unknown" — inner is the original wrapper.
    assert inner is wrapper
