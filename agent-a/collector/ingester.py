"""Envelope ingestion pipeline.

The core entry point is `process_envelope(raw_envelope, ...) -> IngestResult`.
The result carries everything the inbox watcher needs to:
  1. send the Ack on the envelope's ack_port
  2. emit a ChangeEvent for the batch
  3. log/observe what happened

`process_envelope` is a pure function of (raw_envelope, warehouse) — it does
not perform any I/O outside of the warehouse, which makes it easy to test.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Optional

from pydantic import ValidationError

from . import __version__ as COLLECTOR_VERSION
from .schema import (
    ACCEPTED_VERSIONS,
    Ack,
    CategorySample,
    ChangeEvent,
    Envelope,
    QuantitySample,
    RejectedSample,
    RouteChunkEnvelope,
    Workout,
    WorkoutSample,
)
from .trust import TrustPolicy, TrustRejected, VersionRejected, check_schema_version
from .warehouse import Warehouse


@dataclass
class IngestResult:
    """Outcome of processing a single envelope."""

    ok: bool
    ack: Optional[Ack] = None
    change_event: Optional[ChangeEvent] = None
    ack_port: int = 1002
    source_identity: Optional[str] = None  # Pilot identity to reply to
    error: Optional[str] = None             # set when ok=False (e.g. trust/version reject)
    duplicate_batch: bool = False
    accepted_uuids: list[str] = field(default_factory=list)
    duplicate_uuids: list[str] = field(default_factory=list)
    rejected_uuids: list[str] = field(default_factory=list)


# ─── Sample validation ───────────────────────────────────────────────────────

_QUANTITY_KIND = "quantity"
_CATEGORY_KIND = "category"
_WORKOUT_KIND = "workout"


def _validate_sample(raw: dict) -> tuple[Optional[dict], Optional[RejectedSample]]:
    """Validate one sample against the pydantic schema.

    Returns (normalized_dict, None) on success, or (None, RejectedSample) on
    failure. The normalized dict is the model's `model_dump()` which includes
    fields the warehouse needs.
    """
    uuid = raw.get("uuid")
    if not isinstance(uuid, str) or not uuid:
        return None, RejectedSample(
            uuid=str(uuid) if uuid is not None else "<missing>",
            reason="schema_error",
            message="missing or invalid 'uuid'",
        )
    kind = raw.get("kind")
    try:
        if kind == _QUANTITY_KIND:
            model = QuantitySample.model_validate(raw)
        elif kind == _CATEGORY_KIND:
            model = CategorySample.model_validate(raw)
        elif kind == _WORKOUT_KIND:
            model = WorkoutSample.model_validate(raw)
        else:
            return None, RejectedSample(
                uuid=uuid,
                reason="schema_error",
                message=f"unknown sample kind: {kind!r}",
            )
    except ValidationError as e:
        first = e.errors()[0]
        loc = ".".join(str(p) for p in first.get("loc", ()))
        return None, RejectedSample(
            uuid=uuid,
            reason="schema_error",
            message=f"{loc}: {first.get('msg')}",
        )
    return model.model_dump(by_alias=False), None


def _validate_workout(raw: dict) -> tuple[Optional[dict], Optional[str]]:
    try:
        return Workout.model_validate(raw).model_dump(by_alias=False), None
    except ValidationError as e:
        first = e.errors()[0]
        loc = ".".join(str(p) for p in first.get("loc", ()))
        return None, f"workout {raw.get('uuid')!r}: {loc}: {first.get('msg')}"


# ─── Public API ──────────────────────────────────────────────────────────────

def process_envelope(
    raw_envelope: dict,
    *,
    warehouse: Warehouse,
    trust: TrustPolicy,
    source_identity: Optional[str] = None,
    now: Optional[float] = None,
) -> IngestResult:
    """Ingest one Envelope. See module docstring for guarantees."""
    now = time.time() if now is None else now

    # 1. Identity check first — the envelope might fail schema parsing too,
    #    but if we don't trust the sender we shouldn't even look at the body.
    try:
        trust.check_source(source_identity)
    except TrustRejected as e:
        return IngestResult(
            ok=False, error=f"trust_rejected: {e}",
            ack_port=raw_envelope.get("ack_port", 1002) if isinstance(raw_envelope, dict) else 1002,
            source_identity=source_identity,
        )

    # 2. Schema-version gate.
    v = raw_envelope.get("v") if isinstance(raw_envelope, dict) else None
    try:
        if v is None:
            raise VersionRejected("missing 'v' field")
        check_schema_version(int(v))
    except VersionRejected as e:
        return IngestResult(
            ok=False, error=f"version_rejected: {e}",
            ack_port=raw_envelope.get("ack_port", 1002),
            source_identity=source_identity,
        )

    # 3. Envelope-shape validation (the wrapper, not the samples — those
    #    we validate one by one so a single bad sample doesn't kill the batch).
    try:
        env = Envelope.model_validate(raw_envelope)
    except ValidationError as e:
        first = e.errors()[0]
        loc = ".".join(str(p) for p in first.get("loc", ()))
        return IngestResult(
            ok=False,
            error=f"envelope_schema_error: {loc}: {first.get('msg')}",
            ack_port=raw_envelope.get("ack_port", 1002),
            source_identity=source_identity,
        )

    # 4. Duplicate batch fast-path: if the batch_id is already in `batches`,
    #    rebuild the ack from the existing samples table. Required by the
    #    contract: replays must return the same accepted/duplicate split.
    if warehouse.has_batch(env.batch_id):
        sample_uuids = [
            s.get("uuid") for s in env.samples if isinstance(s, dict) and s.get("uuid")
        ]
        workout_uuids = [w.get("uuid") for w in env.workouts if isinstance(w, dict) and w.get("uuid")]
        existing = warehouse.existing_sample_uuids(sample_uuids) | warehouse.existing_workout_uuids(workout_uuids)
        all_uuids = sample_uuids + workout_uuids
        duplicates = [u for u in all_uuids if u in existing]
        rejected = [
            RejectedSample(uuid=u, reason="schema_error", message="missing on replay")
            for u in all_uuids if u not in existing
        ]
        ack = Ack(
            batch_id=env.batch_id,
            accepted=[],
            duplicates=duplicates,
            rejected=rejected,
            ingested_at=now,
            collector_version=COLLECTOR_VERSION,
        )
        return IngestResult(
            ok=True,
            ack=ack,
            change_event=None,
            ack_port=env.ack_port,
            source_identity=source_identity,
            duplicate_batch=True,
            duplicate_uuids=duplicates,
            rejected_uuids=[r.uuid for r in rejected],
        )

    # 5. Validate and persist samples + workouts inside a single transaction.
    accepted: list[str] = []
    duplicates: list[str] = []
    rejected: list[RejectedSample] = []
    by_type: dict[str, int] = {}
    min_start: Optional[float] = None
    max_end: Optional[float] = None

    with warehouse.transaction() as con:
        warehouse.upsert_batch(
            batch_id=env.batch_id,
            source=env.source,
            device_id=env.device_id,
            device_model=env.device_model,
            os_version=env.os_version,
            app_version=env.app_version,
            sent_at=env.sent_at,
            ingested_at=now,
            sample_count=len(env.samples),
            workout_count=len(env.workouts),
            schema_v=env.v,
            raw_metadata=env.metadata.model_dump() if env.metadata else None,
            con=con,
        )

        for raw_sample in env.samples:
            normalized, rej = _validate_sample(raw_sample)
            if rej is not None:
                rejected.append(rej)
                continue
            inserted = warehouse.insert_sample(
                sample=normalized,
                batch_id=env.batch_id,
                device_id=env.device_id,
                source=env.source,
                con=con,
            )
            uuid = normalized["uuid"]
            if inserted:
                accepted.append(uuid)
                t = normalized.get("type")
                if t:
                    by_type[t] = by_type.get(t, 0) + 1
                s = normalized.get("start_utc")
                e_ = normalized.get("end_utc")
                if s is not None:
                    min_start = s if min_start is None else min(min_start, s)
                if e_ is not None:
                    max_end = e_ if max_end is None else max(max_end, e_)
            else:
                duplicates.append(uuid)

        for raw_workout in env.workouts:
            normalized_w, err = _validate_workout(raw_workout)
            if err is not None:
                uuid = raw_workout.get("uuid", "<missing>") if isinstance(raw_workout, dict) else "<missing>"
                rejected.append(RejectedSample(
                    uuid=str(uuid), reason="schema_error", message=err,
                ))
                continue
            inserted = warehouse.insert_workout(
                workout=normalized_w,
                batch_id=env.batch_id,
                device_id=env.device_id,
                con=con,
            )
            uuid = normalized_w["uuid"]
            if inserted:
                accepted.append(uuid)
                by_type["workout"] = by_type.get("workout", 0) + 1
            else:
                duplicates.append(uuid)

    ack = Ack(
        batch_id=env.batch_id,
        accepted=accepted,
        duplicates=duplicates,
        rejected=rejected,
        ingested_at=now,
        collector_version=COLLECTOR_VERSION,
    )
    change_event = ChangeEvent(
        device_id=env.device_id,
        by_type=by_type,
        since_ts=min_start,
        until_ts=max_end,
        ts=now,
    ) if accepted else None

    return IngestResult(
        ok=True,
        ack=ack,
        change_event=change_event,
        ack_port=env.ack_port,
        source_identity=source_identity,
        accepted_uuids=accepted,
        duplicate_uuids=duplicates,
        rejected_uuids=[r.uuid for r in rejected],
    )


def process_route_chunk(
    raw_chunk: dict,
    *,
    warehouse: Warehouse,
    trust: TrustPolicy,
    source_identity: Optional[str] = None,
    now: Optional[float] = None,
) -> IngestResult:
    """Ingest a single route_chunk envelope."""
    now = time.time() if now is None else now
    try:
        trust.check_source(source_identity)
    except TrustRejected as e:
        return IngestResult(
            ok=False, error=f"trust_rejected: {e}",
            ack_port=raw_chunk.get("ack_port", 1002),
            source_identity=source_identity,
        )

    v = raw_chunk.get("v", 1)
    try:
        check_schema_version(int(v))
    except VersionRejected as e:
        return IngestResult(
            ok=False, error=f"version_rejected: {e}",
            ack_port=raw_chunk.get("ack_port", 1002),
            source_identity=source_identity,
        )

    try:
        chunk = RouteChunkEnvelope.model_validate(raw_chunk)
    except ValidationError as e:
        first = e.errors()[0]
        loc = ".".join(str(p) for p in first.get("loc", ()))
        return IngestResult(
            ok=False,
            error=f"route_chunk_schema_error: {loc}: {first.get('msg')}",
            ack_port=raw_chunk.get("ack_port", 1002),
            source_identity=source_identity,
        )

    is_new = warehouse.buffer_route_chunk(
        workout_uuid=chunk.workout_uuid,
        chunk_idx=chunk.chunk_idx,
        chunk_total=chunk.chunk_total,
        batch_id=chunk.batch_id,
        points=chunk.points,
        received_at=now,
    )
    assembled = warehouse.try_assemble_route(chunk.workout_uuid)

    accepted_id = f"{chunk.workout_uuid}#chunk{chunk.chunk_idx}"
    ack = Ack(
        batch_id=chunk.batch_id,
        accepted=[accepted_id] if is_new else [],
        duplicates=[accepted_id] if not is_new else [],
        rejected=[],
        ingested_at=now,
        collector_version=COLLECTOR_VERSION,
    )
    change_event = None
    if assembled is not None:
        change_event = ChangeEvent(
            device_id=chunk.device_id or "unknown",
            by_type={"route_points": assembled},
            ts=now,
        )

    return IngestResult(
        ok=True,
        ack=ack,
        change_event=change_event,
        ack_port=chunk.ack_port,
        source_identity=source_identity,
        accepted_uuids=ack.accepted,
        duplicate_uuids=ack.duplicates,
    )
