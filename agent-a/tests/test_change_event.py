"""ChangeEvent emission and broadcast."""

from __future__ import annotations

import json
from pathlib import Path

from collector.change_event import ChangeEventBroadcaster
from collector.schema import ChangeEvent
from collector.transport import FileTransport


def test_emit_writes_to_local_log(tmp_path: Path):
    bus = FileTransport(tmp_path / "out")
    events = ChangeEventBroadcaster(
        transport=bus, event_log_dir=tmp_path / "log", subscribers=[],
    )
    events.emit(ChangeEvent(
        device_id="iPhone-X",
        by_type={"heartRate": 5, "stepCount": 12},
        since_ts=100.0, until_ts=200.0, ts=300.0,
    ))
    log_files = list((tmp_path / "log").iterdir())
    assert len(log_files) == 1
    body = json.loads(log_files[0].read_text())
    assert body["kind"] == "change_event"
    assert body["body"]["device_id"] == "iPhone-X"
    assert body["body"]["by_type"]["heartRate"] == 5


def test_emit_fans_out_to_subscribers(tmp_path: Path):
    bus = FileTransport(tmp_path / "out")
    events = ChangeEventBroadcaster(
        transport=bus, event_log_dir=tmp_path / "log",
        subscribers=["coach.readiness", "coach.sleep"],
    )
    events.emit(ChangeEvent(device_id="iPhone-X", by_type={"heartRate": 1}, ts=1.0))
    out_files = list((tmp_path / "out").iterdir())
    targets = sorted(json.loads(f.read_text())["target"] for f in out_files)
    assert targets == ["coach.readiness", "coach.sleep"]
    # Plus a local event log entry
    assert len(list((tmp_path / "log").iterdir())) == 1


def test_no_subscribers_still_logs(tmp_path: Path):
    bus = FileTransport(tmp_path / "out")
    events = ChangeEventBroadcaster(
        transport=bus, event_log_dir=tmp_path / "log", subscribers=[],
    )
    events.emit(ChangeEvent(device_id="iPhone-X", by_type={"hr": 1}, ts=1.0))
    assert list((tmp_path / "out").iterdir()) == []
    assert len(list((tmp_path / "log").iterdir())) == 1
