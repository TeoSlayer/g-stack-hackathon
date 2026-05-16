"""Pydantic models for the wire schema.

Mirrors the shapes defined in the project SCHEMA.md:

- Envelope (port 1001)              — batch of samples + workouts
- RouteChunk envelope (port 1001)   — continuation of a workout's GPS polyline
- Ack (envelope.ack_port reply)
- Query (port 1003)
- QueryResult (query.reply_port)
- ChangeEvent (port 1004)

Validation is permissive on the inbound side and strict on the warehouse side:
malformed samples become `rejected` entries in the Ack rather than crashing
the batch.
"""

from __future__ import annotations

from typing import Annotated, Any, Literal, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, model_validator


CURRENT_VERSION = 1
ACCEPTED_VERSIONS = {CURRENT_VERSION, CURRENT_VERSION - 1}  # accept v and v-1


# ─── Location ────────────────────────────────────────────────────────────────

class Location(BaseModel):
    model_config = ConfigDict(extra="allow")
    lat: float
    lon: float
    accuracy_m: Optional[float] = None
    altitude_m: Optional[float] = None
    source: Optional[str] = None  # "core_location" | "photo_join"
    offset_s: Optional[int] = None
    ts: Optional[float] = None


# ─── Samples ─────────────────────────────────────────────────────────────────

class _SampleBase(BaseModel):
    model_config = ConfigDict(extra="allow")
    uuid: str
    type: str
    start_utc: float
    end_utc: float
    source_name: Optional[str] = None
    source_bundle: Optional[str] = None
    device: Optional[str] = None
    location: Optional[Location] = None


class QuantitySample(_SampleBase):
    kind: Literal["quantity"]
    value: float
    unit: str

    @model_validator(mode="after")
    def _finite_value(self):
        import math
        if not math.isfinite(self.value):
            raise ValueError("value must be finite")
        return self


class CategorySample(_SampleBase):
    kind: Literal["category"]
    category_value: int
    category_name: Optional[str] = None
    metadata: Optional[dict[str, Any]] = None


# A workout MAY also appear as a sample (kind="workout") per the iOS outbox doc.
# Full workouts (with route info) ride in the Envelope.workouts array.
class WorkoutSample(_SampleBase):
    kind: Literal["workout"]
    activity_type: Optional[int] = None
    activity_name: Optional[str] = None


Sample = Annotated[
    Union[QuantitySample, CategorySample, WorkoutSample],
    Field(discriminator="kind"),
]


# ─── Workout (full, with route) ──────────────────────────────────────────────

class Route(BaseModel):
    model_config = ConfigDict(extra="allow")
    point_count: int
    inline: bool = True
    points: list[list[Optional[float]]] = Field(default_factory=list)
    # When inline=False, the workout references chunks via chunk_total.
    chunk_total: Optional[int] = None


class Workout(BaseModel):
    model_config = ConfigDict(extra="allow")
    uuid: str
    activity_type: int
    activity_name: Optional[str] = None
    start_utc: float
    end_utc: float
    duration_s: Optional[float] = None
    total_energy_kcal: Optional[float] = None
    total_distance_m: Optional[float] = None
    source_name: Optional[str] = None
    device: Optional[str] = None
    route: Optional[Route] = None


# ─── Envelope (port 1001) ────────────────────────────────────────────────────

class EnvelopeMetadata(BaseModel):
    model_config = ConfigDict(extra="allow")
    location: Optional[Location] = None
    network: Optional[str] = None
    battery_level: Optional[float] = None
    wake_window: Optional[list[int]] = None


class Envelope(BaseModel):
    """A batch of samples on port 1001."""

    model_config = ConfigDict(extra="allow")

    v: int
    source: str
    device_id: str
    device_model: Optional[str] = None
    os_version: Optional[str] = None
    app_version: Optional[str] = None
    batch_id: str
    sent_at: float
    ack_port: int = 1002
    # Samples are validated lazily so a single bad sample doesn't reject the whole batch.
    samples: list[dict] = Field(default_factory=list)
    workouts: list[dict] = Field(default_factory=list)
    metadata: Optional[EnvelopeMetadata] = None


# ─── Route chunk envelope (port 1001, continuation) ──────────────────────────

class RouteChunkEnvelope(BaseModel):
    """Continuation envelope for a large workout's GPS polyline.

    Shape per iOS outbox doc: `{ batch_id, workout_uuid, chunk_idx, points: [] }`.
    We also accept a top-level `kind: "route_chunk"` marker if the source includes
    one, and we propagate `v`, `source`, `device_id`, `ack_port` when present so
    the collector can ack on the right port.
    """

    model_config = ConfigDict(extra="allow")

    v: int = CURRENT_VERSION
    kind: Literal["route_chunk"] = "route_chunk"
    source: Optional[str] = None
    device_id: Optional[str] = None
    batch_id: str
    workout_uuid: str
    chunk_idx: int
    chunk_total: Optional[int] = None  # last chunk should always include this
    points: list[list[Optional[float]]]
    ack_port: int = 1002
    sent_at: Optional[float] = None


# ─── Ack (reply on envelope.ack_port) ────────────────────────────────────────

class RejectedSample(BaseModel):
    uuid: str
    reason: str
    message: Optional[str] = None


class Ack(BaseModel):
    v: int = CURRENT_VERSION
    batch_id: str
    accepted: list[str] = Field(default_factory=list)
    duplicates: list[str] = Field(default_factory=list)
    rejected: list[RejectedSample] = Field(default_factory=list)
    ingested_at: float
    collector_version: str


# ─── Query / QueryResult (ports 1003 / reply_port) ───────────────────────────

class Query(BaseModel):
    model_config = ConfigDict(extra="allow")
    v: int = CURRENT_VERSION
    request_id: str
    reply_port: int
    kind: Literal["sql"] = "sql"
    sql: str
    params: list[Any] = Field(default_factory=list)
    limit: Optional[int] = None


class QueryError(BaseModel):
    code: str
    message: str


class QueryResult(BaseModel):
    v: int = CURRENT_VERSION
    request_id: str
    ok: bool
    rows: list[dict] = Field(default_factory=list)
    schema_: list[dict] = Field(default_factory=list, alias="schema")
    row_count: int = 0
    ms: int = 0
    truncated: bool = False
    error: Optional[QueryError] = None

    model_config = ConfigDict(populate_by_name=True)


# ─── ChangeEvent (port 1004) ─────────────────────────────────────────────────

class ChangeEvent(BaseModel):
    v: int = CURRENT_VERSION
    kind: Literal["samples_added"] = "samples_added"
    device_id: str
    by_type: dict[str, int]
    since_ts: Optional[float] = None
    until_ts: Optional[float] = None
    ts: float


# ─── Shape detection (used by the inbox dispatcher) ──────────────────────────

def classify_message(obj: dict) -> str:
    """Classify an inbound message by its top-level shape.

    Returns one of: "envelope" | "route_chunk" | "query" | "unknown".
    """
    if not isinstance(obj, dict):
        return "unknown"
    # route_chunk: explicit marker OR the unique shape (workout_uuid + chunk_idx + points).
    if obj.get("kind") == "route_chunk":
        return "route_chunk"
    if "workout_uuid" in obj and "chunk_idx" in obj and "points" in obj:
        return "route_chunk"
    # query: presence of sql + reply_port + request_id.
    if "sql" in obj and "reply_port" in obj and "request_id" in obj:
        return "query"
    # envelope: source + batch_id + samples list.
    if "source" in obj and "batch_id" in obj and isinstance(obj.get("samples"), list):
        return "envelope"
    return "unknown"
