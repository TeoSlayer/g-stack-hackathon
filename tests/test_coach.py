"""Coach client — end-to-end via the StubPilot transport.

The Coach drops a query into the Collector's inbox; the watcher processes
it and the QueryResult lands in the Coach's inbox. We run one watcher tick
manually here instead of starting a daemon thread.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from coach.client import Coach, CoachConfig, StubPilot
from collector.change_event import ChangeEventBroadcaster
from collector.inbox_watcher import InboxWatcher, WatcherConfig
from collector.transport import FileTransport
from collector.trust import TrustPolicy
from collector.warehouse import Warehouse
from tests.helpers import make_envelope, make_quantity_sample


@pytest.fixture
def two_node_setup(tmp_path: Path):
    """Mirror the docker-compose two-container layout in a single test process.

    - Collector inbox:  tmp/collector_inbox/
    - Coach inbox:      tmp/coach_inbox/
    - Each side's pilot drops into the other's inbox.
    """
    collector_inbox = tmp_path / "collector_inbox"
    coach_inbox = tmp_path / "coach_inbox"
    var = tmp_path / "var"
    for p in (collector_inbox, coach_inbox, var):
        p.mkdir()

    # Collector side
    wh = Warehouse(var / "warehouse.duckdb")
    trust = TrustPolicy()

    # Collector's outgoing transport: drop into the coach's inbox (Pilot stand-in)
    class _PeerInboxTransport:
        def __init__(self, peer_inbox: Path):
            self.peer_inbox = peer_inbox
            self._seq = 0

        def send(self, msg):
            self._seq += 1
            wrapped = {
                "agent": "collector",
                "target": msg.target,
                "command": msg.kind,
                "data": json.dumps(msg.body, default=str),
            }
            name = f"{time.time():.6f}-from-collector-{self._seq}.json"
            (self.peer_inbox / name).write_text(json.dumps(wrapped))
            return True

    transport = _PeerInboxTransport(coach_inbox)
    events = ChangeEventBroadcaster(
        transport=transport, event_log_dir=var / "events_log",
        subscribers=["coach.readiness"],  # broadcast to coach
    )
    watcher = InboxWatcher(
        config=WatcherConfig(
            inbox_dir=collector_inbox,
            archive_dir=collector_inbox / ".archive",
            unrecognized_dir=collector_inbox / ".unrecognized",
            poll_interval_s=0.01,
        ),
        warehouse=wh, trust=trust, transport=transport, events=events,
    )

    # Coach side
    coach_pilot = StubPilot(
        own_identity="coach.readiness",
        own_inbox=coach_inbox,
        peer_inbox=collector_inbox,
    )
    coach = Coach(coach_pilot, CoachConfig(
        collector_identity="collector", reply_port=1005, query_timeout_s=5.0,
    ))

    yield {
        "watcher": watcher, "warehouse": wh, "coach": coach,
        "collector_inbox": collector_inbox, "coach_inbox": coach_inbox,
        "var": var,
    }
    wh.close()


def test_coach_can_query_collector(two_node_setup):
    s = two_node_setup
    # Seed via direct ingestion to keep this test focused on the query path.
    env = make_envelope(batch_id="b1", samples=[
        make_quantity_sample(uuid_=f"s{i}", value=60 + i, type="heartRate")
        for i in range(5)
    ])
    (s["collector_inbox"] / "seed.json").write_text(json.dumps({
        "agent": "ios.alex", "data": json.dumps(env),
    }))
    s["watcher"].tick()

    # Run the watcher in a background thread so query/reply happens concurrently
    def watcher_loop():
        for _ in range(50):
            s["watcher"].tick()
            time.sleep(0.05)
    t = threading.Thread(target=watcher_loop, daemon=True)
    t.start()

    result = s["coach"].query(
        "SELECT type, COUNT(*) AS n FROM samples GROUP BY type",
        limit=10,
    )
    assert result.get("ok") is True
    rows = result["rows"]
    by_type = {row["type"]: row["n"] for row in rows}
    assert by_type.get("heartRate") == 5


def test_coach_receives_change_event(two_node_setup):
    s = two_node_setup

    # Drop an envelope into the collector inbox and run a tick.
    env = make_envelope(batch_id="b1", samples=[
        make_quantity_sample(uuid_="s1"),
    ])
    (s["collector_inbox"] / "drop.json").write_text(json.dumps({
        "agent": "ios.alex", "data": json.dumps(env),
    }))
    s["watcher"].tick()

    # The change_event should have been routed to the coach's inbox.
    events_seen = []
    s["coach"].consume_change_events(events_seen.append)
    assert len(events_seen) == 1
    assert events_seen[0]["kind"] == "samples_added"
    assert events_seen[0]["by_type"] == {"heartRate": 1}
