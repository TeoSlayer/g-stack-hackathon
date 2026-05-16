"""Schema model validation."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from collector.schema import (
    ACCEPTED_VERSIONS,
    CategorySample,
    ChangeEvent,
    Envelope,
    QuantitySample,
    Query,
    QueryResult,
    RouteChunkEnvelope,
    Workout,
    classify_message,
)


class TestQuantitySample:
    def test_valid(self):
        s = QuantitySample(
            kind="quantity", uuid="u1", type="heartRate", value=60.0,
            unit="count/min", start_utc=1.0, end_utc=2.0,
        )
        assert s.value == 60.0

    def test_rejects_nan(self):
        with pytest.raises(ValidationError):
            QuantitySample(
                kind="quantity", uuid="u1", type="hr", value=float("nan"),
                unit="bpm", start_utc=1.0, end_utc=2.0,
            )

    def test_rejects_inf(self):
        with pytest.raises(ValidationError):
            QuantitySample(
                kind="quantity", uuid="u1", type="hr", value=float("inf"),
                unit="bpm", start_utc=1.0, end_utc=2.0,
            )


class TestCategorySample:
    def test_valid(self):
        s = CategorySample(
            kind="category", uuid="u1", type="sleepAnalysis",
            category_value=5, category_name="asleepREM",
            start_utc=1.0, end_utc=2.0,
        )
        assert s.category_name == "asleepREM"

    def test_missing_category_value_rejected(self):
        with pytest.raises(ValidationError):
            CategorySample(
                kind="category", uuid="u1", type="sleepAnalysis",
                start_utc=1.0, end_utc=2.0,
            )


class TestEnvelope:
    def test_valid(self):
        e = Envelope.model_validate({
            "v": 1, "source": "ios.healthsync", "device_id": "iPhone-X",
            "batch_id": "b1", "sent_at": 1.0, "ack_port": 1002, "samples": [],
        })
        assert e.batch_id == "b1"
        assert e.ack_port == 1002

    def test_ack_port_defaults(self):
        e = Envelope.model_validate({
            "v": 1, "source": "ios.healthsync", "device_id": "iPhone-X",
            "batch_id": "b1", "sent_at": 1.0, "samples": [],
        })
        assert e.ack_port == 1002


class TestRouteChunk:
    def test_valid_minimal(self):
        c = RouteChunkEnvelope.model_validate({
            "batch_id": "b1", "workout_uuid": "w1",
            "chunk_idx": 0, "chunk_total": 3,
            "points": [[47.6, -122.3, 0.0, 1.0, 3.0]],
        })
        assert c.kind == "route_chunk"
        assert c.chunk_total == 3


class TestClassify:
    def test_envelope(self):
        assert classify_message({
            "source": "ios.healthsync", "batch_id": "b1", "samples": [],
        }) == "envelope"

    def test_route_chunk_by_marker(self):
        assert classify_message({
            "kind": "route_chunk", "batch_id": "b1",
            "workout_uuid": "w1", "chunk_idx": 0, "points": [],
        }) == "route_chunk"

    def test_route_chunk_by_shape(self):
        assert classify_message({
            "batch_id": "b1", "workout_uuid": "w1",
            "chunk_idx": 0, "points": [],
        }) == "route_chunk"

    def test_query(self):
        assert classify_message({
            "request_id": "r1", "reply_port": 1005,
            "sql": "SELECT 1", "kind": "sql",
        }) == "query"

    def test_unknown(self):
        assert classify_message({"random": "thing"}) == "unknown"
        assert classify_message("not a dict") == "unknown"


def test_accepted_versions_includes_current_and_prior():
    assert 1 in ACCEPTED_VERSIONS
    assert 0 in ACCEPTED_VERSIONS  # v-1


def test_query_result_serializes_schema_field():
    qr = QueryResult(request_id="r1", ok=True, rows=[], schema_=[{"name": "x", "type": "INT"}])
    dumped = qr.model_dump(by_alias=True)
    assert "schema" in dumped
    assert dumped["schema"] == [{"name": "x", "type": "INT"}]


def test_workout_round_trip():
    w = Workout.model_validate({
        "uuid": "w1", "activity_type": 37, "activity_name": "running",
        "start_utc": 1.0, "end_utc": 2.0, "duration_s": 1.0,
    })
    assert w.activity_name == "running"


def test_change_event_round_trip():
    ev = ChangeEvent(device_id="iPhone-X", by_type={"heartRate": 5}, ts=1.0)
    dumped = ev.model_dump()
    assert dumped["kind"] == "samples_added"
    assert dumped["by_type"] == {"heartRate": 5}
