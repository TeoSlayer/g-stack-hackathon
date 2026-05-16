"""Warehouse: dedupe, batches, samples, workouts, routes."""

from __future__ import annotations

from tests.helpers import make_envelope, make_quantity_sample, make_workout


def test_init_creates_tables(warehouse):
    rows = warehouse.connection().execute(
        "SELECT table_name FROM information_schema.tables WHERE table_schema='main'"
    ).fetchall()
    names = {r[0] for r in rows}
    assert "batches" in names
    assert "samples" in names
    assert "workouts" in names
    assert "route_points" in names
    assert "route_chunks_inflight" in names


def test_batch_insert_then_dedupe(warehouse):
    new = warehouse.upsert_batch(
        batch_id="b1", source="x", device_id="d1",
        device_model=None, os_version=None, app_version=None,
        sent_at=1.0, ingested_at=2.0, sample_count=0, workout_count=0,
        schema_v=1, raw_metadata=None,
    )
    assert new is True
    again = warehouse.upsert_batch(
        batch_id="b1", source="x", device_id="d1",
        device_model=None, os_version=None, app_version=None,
        sent_at=1.0, ingested_at=2.0, sample_count=0, workout_count=0,
        schema_v=1, raw_metadata=None,
    )
    assert again is False
    assert warehouse.has_batch("b1")
    assert not warehouse.has_batch("b2")


def test_sample_insert_then_dedupe(warehouse):
    warehouse.upsert_batch(
        batch_id="b1", source="x", device_id="d1",
        device_model=None, os_version=None, app_version=None,
        sent_at=1.0, ingested_at=2.0, sample_count=1, workout_count=0,
        schema_v=1, raw_metadata=None,
    )
    s = make_quantity_sample(uuid_="s1")
    first = warehouse.insert_sample(sample=s, batch_id="b1", device_id="d1", source="x")
    second = warehouse.insert_sample(sample=s, batch_id="b1", device_id="d1", source="x")
    assert first is True
    assert second is False
    assert warehouse.has_sample("s1")


def test_existing_sample_uuids(warehouse):
    warehouse.upsert_batch(
        batch_id="b1", source="x", device_id="d1",
        device_model=None, os_version=None, app_version=None,
        sent_at=1.0, ingested_at=2.0, sample_count=0, workout_count=0,
        schema_v=1, raw_metadata=None,
    )
    for u in ["a", "b", "c"]:
        warehouse.insert_sample(
            sample=make_quantity_sample(uuid_=u),
            batch_id="b1", device_id="d1", source="x",
        )
    existing = warehouse.existing_sample_uuids(["a", "b", "d", "e"])
    assert existing == {"a", "b"}


def test_workout_with_inline_route(warehouse):
    warehouse.upsert_batch(
        batch_id="b1", source="x", device_id="d1",
        device_model=None, os_version=None, app_version=None,
        sent_at=1.0, ingested_at=2.0, sample_count=0, workout_count=1,
        schema_v=1, raw_metadata=None,
    )
    w = make_workout(uuid_="w1", n_points=10)
    inserted = warehouse.insert_workout(workout=w, batch_id="b1", device_id="d1")
    assert inserted is True

    count = warehouse.connection().execute(
        "SELECT COUNT(*) FROM route_points WHERE workout_uuid='w1'"
    ).fetchone()[0]
    assert count == 10

    complete = warehouse.connection().execute(
        "SELECT route_complete FROM workouts WHERE uuid='w1'"
    ).fetchone()[0]
    assert complete is True


def test_route_chunk_buffer_and_assembly(warehouse):
    # No workout header yet; chunks should still buffer and assemble.
    warehouse.buffer_route_chunk(
        workout_uuid="w1", chunk_idx=0, chunk_total=3,
        batch_id="b1", points=[[47.0, -122.0, 0.0, 1.0, 3.0]],
        received_at=1.0,
    )
    assert warehouse.try_assemble_route("w1") is None  # 1 of 3

    warehouse.buffer_route_chunk(
        workout_uuid="w1", chunk_idx=1, chunk_total=3,
        batch_id="b1", points=[[47.1, -122.1, 0.0, 2.0, 3.5]],
        received_at=1.0,
    )
    assert warehouse.try_assemble_route("w1") is None  # 2 of 3

    warehouse.buffer_route_chunk(
        workout_uuid="w1", chunk_idx=2, chunk_total=3,
        batch_id="b1", points=[[47.2, -122.2, 0.0, 3.0, 4.0]],
        received_at=1.0,
    )
    total = warehouse.try_assemble_route("w1")
    assert total == 3

    count = warehouse.connection().execute(
        "SELECT COUNT(*) FROM route_points WHERE workout_uuid='w1'"
    ).fetchone()[0]
    assert count == 3
    # Buffer should be cleared
    remaining = warehouse.connection().execute(
        "SELECT COUNT(*) FROM route_chunks_inflight WHERE workout_uuid='w1'"
    ).fetchone()[0]
    assert remaining == 0


def test_route_chunk_duplicate_idx_ignored(warehouse):
    new1 = warehouse.buffer_route_chunk(
        workout_uuid="w1", chunk_idx=0, chunk_total=1,
        batch_id="b1", points=[[47.0, -122.0, 0.0, 1.0, 3.0]],
        received_at=1.0,
    )
    new2 = warehouse.buffer_route_chunk(
        workout_uuid="w1", chunk_idx=0, chunk_total=1,
        batch_id="b2", points=[[47.0, -122.0, 0.0, 1.0, 3.0]],
        received_at=2.0,
    )
    assert new1 is True
    assert new2 is False
