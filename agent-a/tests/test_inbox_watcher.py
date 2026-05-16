"""End-to-end test of the inbox watcher.

Drops files into a temporary inbox, runs one watcher tick, then asserts the
warehouse, ack output dir, event log, and archive/unrecognized dirs.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from collector.change_event import ChangeEventBroadcaster
from collector.inbox_watcher import InboxWatcher, WatcherConfig, unwrap_pilot_transport
from collector.transport import FileTransport
from collector.trust import TrustPolicy
from collector.warehouse import Warehouse
from tests.helpers import make_envelope, make_quantity_sample, make_workout


@pytest.fixture
def runtime(tmp_path: Path):
    inbox = tmp_path / "inbox"
    var = tmp_path / "var"
    inbox.mkdir()
    var.mkdir()
    wh = Warehouse(var / "warehouse.duckdb")
    trust = TrustPolicy()
    transport = FileTransport(var / "out")
    events = ChangeEventBroadcaster(
        transport=transport, event_log_dir=var / "events_log", subscribers=[],
    )
    watcher = InboxWatcher(
        config=WatcherConfig(
            inbox_dir=inbox,
            archive_dir=inbox / ".archive",
            unrecognized_dir=inbox / ".unrecognized",
            poll_interval_s=0.01,
        ),
        warehouse=wh, trust=trust, transport=transport, events=events,
    )
    yield {
        "watcher": watcher, "warehouse": wh, "inbox": inbox, "var": var,
        "transport_dir": var / "out", "events_dir": var / "events_log",
    }
    wh.close()


def _drop(inbox: Path, name: str, body: dict):
    (inbox / name).write_text(json.dumps(body))


# ─── unwrap helper ───────────────────────────────────────────────────────────

class TestUnwrap:
    def test_direct_inner(self):
        obj = {"source": "ios.healthsync", "samples": [], "batch_id": "b1"}
        inner, sender = unwrap_pilot_transport(obj)
        assert inner is obj
        assert sender is None

    def test_data_string_wrap(self):
        inner_payload = {"batch_id": "b1", "source": "x", "samples": []}
        obj = {"agent": "ios.alex", "command": "ingest", "data": json.dumps(inner_payload)}
        inner, sender = unwrap_pilot_transport(obj)
        assert inner == inner_payload
        assert sender == "ios.alex"

    def test_payload_wrap(self):
        inner_payload = {"batch_id": "b1"}
        obj = {"sender": "ios.x", "payload": inner_payload}
        inner, sender = unwrap_pilot_transport(obj)
        assert inner is inner_payload
        assert sender == "ios.x"


# ─── tick() routing ──────────────────────────────────────────────────────────

def test_envelope_routes_and_acks(runtime):
    inbox = runtime["inbox"]
    env = make_envelope(batch_id="b1", samples=[make_quantity_sample(uuid_="s1")])
    _drop(inbox, "0001.json", {"agent": "ios.alex", "command": "ingest", "data": json.dumps(env)})

    counters = runtime["watcher"].tick()
    assert counters["envelopes"] == 1

    # Warehouse has the sample
    n = runtime["warehouse"].connection().execute(
        "SELECT COUNT(*) FROM samples WHERE uuid='s1'"
    ).fetchone()[0]
    assert n == 1

    # Ack written
    out_files = list(runtime["transport_dir"].iterdir())
    acks = [json.loads(f.read_text()) for f in out_files if "ack" in f.name]
    assert len(acks) == 1
    assert acks[0]["target"] == "ios.alex"
    assert acks[0]["port"] == 1002
    assert acks[0]["body"]["batch_id"] == "b1"
    assert acks[0]["body"]["accepted"] == ["s1"]

    # ChangeEvent written
    events = list(runtime["events_dir"].iterdir())
    assert len(events) == 1

    # File archived
    assert not list(inbox.glob("*.json"))
    assert list((inbox / ".archive").iterdir())


def test_route_chunk_routes_and_acks(runtime):
    inbox = runtime["inbox"]
    chunk = {
        "v": 1, "kind": "route_chunk", "batch_id": "rb1",
        "workout_uuid": "w1", "chunk_idx": 0, "chunk_total": 1,
        "points": [[47.6, -122.3, 0.0, 1.0, 3.0]], "ack_port": 1002,
    }
    _drop(inbox, "0001.json", {"agent": "ios.alex", "data": json.dumps(chunk)})

    counters = runtime["watcher"].tick()
    assert counters["route_chunks"] == 1
    # Route assembled into route_points
    n = runtime["warehouse"].connection().execute(
        "SELECT COUNT(*) FROM route_points WHERE workout_uuid='w1'"
    ).fetchone()[0]
    assert n == 1


def test_query_routes_to_reply_port(runtime):
    # Seed
    inbox = runtime["inbox"]
    env = make_envelope(batch_id="b1", samples=[
        make_quantity_sample(uuid_=f"s{i}", value=60 + i) for i in range(3)
    ])
    _drop(inbox, "0001.json", {"agent": "ios.alex", "data": json.dumps(env)})
    runtime["watcher"].tick()

    # Now drop a query
    q = {
        "v": 1, "request_id": "rq1", "reply_port": 1005,
        "kind": "sql", "sql": "SELECT COUNT(*) AS n FROM samples",
    }
    _drop(inbox, "0002.json", {"agent": "coach.x", "data": json.dumps(q)})
    counters = runtime["watcher"].tick()
    assert counters["queries"] == 1

    out_files = list(runtime["transport_dir"].iterdir())
    qr_files = [f for f in out_files if "query_result" in f.name]
    assert len(qr_files) == 1
    body = json.loads(qr_files[0].read_text())
    assert body["target"] == "coach.x"
    assert body["port"] == 1005
    assert body["body"]["ok"] is True
    assert body["body"]["rows"][0]["n"] == 3


def test_unparseable_goes_to_unrecognized(runtime):
    inbox = runtime["inbox"]
    (inbox / "garbage.json").write_text("{ not valid json")
    counters = runtime["watcher"].tick()
    assert counters["errors"] == 1
    assert list((inbox / ".unrecognized").iterdir())


def test_unknown_shape_left_in_inbox(runtime):
    inbox = runtime["inbox"]
    _drop(inbox, "weird.json", {"random": "stuff", "nope": True})
    counters = runtime["watcher"].tick()
    assert counters["unknown"] == 1
    # Left in place — heartbeat agent should see it
    assert (inbox / "weird.json").exists()


def test_workout_with_route_persisted_via_watcher(runtime):
    inbox = runtime["inbox"]
    env = make_envelope(batch_id="b1", workouts=[
        make_workout(uuid_="w_inline", n_points=6),
    ])
    _drop(inbox, "0001.json", {"agent": "ios.alex", "data": json.dumps(env)})
    runtime["watcher"].tick()

    n = runtime["warehouse"].connection().execute(
        "SELECT COUNT(*) FROM route_points WHERE workout_uuid='w_inline'"
    ).fetchone()[0]
    assert n == 6
