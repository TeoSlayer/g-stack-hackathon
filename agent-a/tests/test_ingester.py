"""Ingester + Ack contract tests."""

from __future__ import annotations

import math

from collector.ingester import process_envelope, process_route_chunk
from tests.helpers import (
    make_category_sample,
    make_envelope,
    make_quantity_sample,
    make_workout,
)


def test_clean_batch_all_accepted(warehouse, trust_open):
    samples = [make_quantity_sample(uuid_=f"s{i}") for i in range(5)]
    env = make_envelope(batch_id="b1", samples=samples)
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok
    assert result.ack is not None
    assert result.ack.batch_id == "b1"
    assert len(result.ack.accepted) == 5
    assert result.ack.duplicates == []
    assert result.ack.rejected == []
    assert result.change_event is not None
    assert result.change_event.by_type == {"heartRate": 5}


def test_replay_returns_duplicates_not_accepted(warehouse, trust_open):
    s = make_quantity_sample(uuid_="dup1")
    env = make_envelope(batch_id="b1", samples=[s])
    process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    # Replay same envelope (same batch_id, same samples)
    result2 = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result2.ok
    assert result2.duplicate_batch is True
    assert result2.ack.accepted == []
    assert "dup1" in result2.ack.duplicates


def test_partial_duplicates_within_new_batch(warehouse, trust_open):
    # First batch lands sample 's_shared'
    env1 = make_envelope(batch_id="b1", samples=[make_quantity_sample(uuid_="s_shared")])
    process_envelope(env1, warehouse=warehouse, trust=trust_open, source_identity="ios")

    # Second batch carries the same sample plus two new ones — different batch_id
    env2 = make_envelope(batch_id="b2", samples=[
        make_quantity_sample(uuid_="s_shared"),
        make_quantity_sample(uuid_="s_new1"),
        make_quantity_sample(uuid_="s_new2"),
    ])
    result = process_envelope(env2, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok
    assert set(result.ack.accepted) == {"s_new1", "s_new2"}
    assert result.ack.duplicates == ["s_shared"]


def test_bad_sample_rejected_without_killing_batch(warehouse, trust_open):
    samples = [
        make_quantity_sample(uuid_="good"),
        {"kind": "quantity", "uuid": "bad", "type": "heartRate", "value": math.nan,
         "unit": "bpm", "start_utc": 1.0, "end_utc": 1.0},  # NaN → schema_error
        {"kind": "unknown_kind", "uuid": "weird", "type": "x", "start_utc": 1.0, "end_utc": 1.0},
    ]
    env = make_envelope(batch_id="b1", samples=samples)
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok
    assert result.ack.accepted == ["good"]
    rejected_uuids = {r.uuid for r in result.ack.rejected}
    assert rejected_uuids == {"bad", "weird"}


def test_missing_uuid_classified_as_rejection(warehouse, trust_open):
    env = make_envelope(batch_id="b1", samples=[
        {"kind": "quantity", "type": "hr", "value": 60, "unit": "bpm",
         "start_utc": 1.0, "end_utc": 1.0},
    ])
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok
    assert len(result.ack.rejected) == 1
    assert result.ack.rejected[0].reason == "schema_error"


def test_category_sample_persisted(warehouse, trust_open):
    env = make_envelope(batch_id="b1", samples=[
        make_category_sample(uuid_="cat1"),
    ])
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok
    assert "cat1" in result.ack.accepted
    row = warehouse.connection().execute(
        "SELECT category_value, category_name FROM samples WHERE uuid='cat1'"
    ).fetchone()
    assert row == (5, "asleepREM")


def test_workout_with_inline_route(warehouse, trust_open):
    w = make_workout(uuid_="w1", n_points=4)
    env = make_envelope(batch_id="b1", workouts=[w])
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok
    assert "w1" in result.ack.accepted
    count = warehouse.connection().execute(
        "SELECT COUNT(*) FROM route_points WHERE workout_uuid='w1'"
    ).fetchone()[0]
    assert count == 4


def test_trust_rejected(warehouse, trust_strict):
    env = make_envelope(batch_id="b1", samples=[make_quantity_sample(uuid_="s1")])
    result = process_envelope(env, warehouse=warehouse, trust=trust_strict, source_identity="stranger")
    assert not result.ok
    assert "trust_rejected" in result.error


def test_trust_accepted_when_allowlisted(warehouse, trust_strict):
    env = make_envelope(batch_id="b1", samples=[make_quantity_sample(uuid_="s1")])
    result = process_envelope(env, warehouse=warehouse, trust=trust_strict, source_identity="ios.healthsync.alex")
    assert result.ok


def test_version_rejected(warehouse, trust_open):
    env = make_envelope(batch_id="b1", samples=[make_quantity_sample()], v=99)
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert not result.ok
    assert "version_rejected" in result.error


def test_version_prior_accepted(warehouse, trust_open):
    env = make_envelope(batch_id="b1", samples=[make_quantity_sample()], v=0)
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ok


def test_ack_port_carried_through(warehouse, trust_open):
    env = make_envelope(batch_id="b1", samples=[], ack_port=9999)
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.ack_port == 9999


def test_change_event_carries_time_window(warehouse, trust_open):
    env = make_envelope(batch_id="b1", samples=[
        make_quantity_sample(uuid_="s1", start=100.0, end=100.0),
        make_quantity_sample(uuid_="s2", start=200.0, end=205.0),
    ])
    result = process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert result.change_event.since_ts == 100.0
    assert result.change_event.until_ts == 205.0


def test_route_chunk_buffer_and_complete(warehouse, trust_open):
    # Three chunks for workout w1, no inline route on the workout header.
    env = make_envelope(batch_id="b1", workouts=[
        make_workout(uuid_="w1", inline_route=False, n_points=0)
    ])
    # Persist the workout header without inline points.
    env["workouts"][0]["route"] = {"point_count": 6, "inline": False, "points": [],
                                    "chunk_total": 3}
    process_envelope(env, warehouse=warehouse, trust=trust_open, source_identity="ios")

    for i in range(3):
        chunk = {
            "v": 1,
            "kind": "route_chunk",
            "batch_id": f"b_route_{i}",
            "workout_uuid": "w1",
            "chunk_idx": i,
            "chunk_total": 3,
            "points": [[47.6 + 0.001 * i, -122.3, 0.0, 100.0 + i, 3.0]],
            "ack_port": 1002,
        }
        result = process_route_chunk(chunk, warehouse=warehouse, trust=trust_open, source_identity="ios")
        assert result.ok

    # After the 3rd chunk, the route should be assembled.
    count = warehouse.connection().execute(
        "SELECT COUNT(*) FROM route_points WHERE workout_uuid='w1'"
    ).fetchone()[0]
    assert count == 3
    complete = warehouse.connection().execute(
        "SELECT route_complete FROM workouts WHERE uuid='w1'"
    ).fetchone()[0]
    assert complete is True


def test_route_chunk_duplicate_returns_duplicate(warehouse, trust_open):
    chunk = {
        "batch_id": "b1", "workout_uuid": "w1", "chunk_idx": 0,
        "chunk_total": 1, "points": [[47.0, -122.0, 0.0, 1.0, 3.0]],
    }
    r1 = process_route_chunk(chunk, warehouse=warehouse, trust=trust_open, source_identity="ios")
    r2 = process_route_chunk(chunk, warehouse=warehouse, trust=trust_open, source_identity="ios")
    assert r1.ack.accepted and not r1.ack.duplicates
    assert r2.ack.duplicates and not r2.ack.accepted
