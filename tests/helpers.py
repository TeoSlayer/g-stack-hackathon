"""Factory functions for building wire-schema messages in tests."""

from __future__ import annotations

import uuid


def make_quantity_sample(
    *,
    type: str = "heartRate",
    value: float = 60.0,
    unit: str = "count/min",
    start: float = 1701234560.0,
    end: float = 1701234560.0,
    uuid_: str | None = None,
) -> dict:
    return {
        "kind": "quantity",
        "uuid": uuid_ or str(uuid.uuid4()),
        "type": type,
        "value": value,
        "unit": unit,
        "start_utc": start,
        "end_utc": end,
        "source_name": "Apple Watch",
        "device": "Apple Watch Series 9",
    }


def make_category_sample(
    *,
    type: str = "sleepAnalysis",
    category_value: int = 5,
    category_name: str = "asleepREM",
    start: float = 1701208800.0,
    end: float = 1701209820.0,
    uuid_: str | None = None,
) -> dict:
    return {
        "kind": "category",
        "uuid": uuid_ or str(uuid.uuid4()),
        "type": type,
        "category_value": category_value,
        "category_name": category_name,
        "start_utc": start,
        "end_utc": end,
        "source_name": "Apple Watch",
    }


def make_workout(
    *,
    uuid_: str | None = None,
    start: float = 1701180000.0,
    end: float = 1701183600.0,
    inline_route: bool = True,
    n_points: int = 5,
) -> dict:
    points = [
        [47.610 + 0.001 * i, -122.333 + 0.001 * i, 10.0 + i, start + i * 10.0, 3.0]
        for i in range(n_points)
    ]
    return {
        "uuid": uuid_ or str(uuid.uuid4()),
        "activity_type": 37,
        "activity_name": "running",
        "start_utc": start,
        "end_utc": end,
        "duration_s": end - start,
        "total_energy_kcal": 450.2,
        "total_distance_m": 10500.3,
        "source_name": "Apple Watch",
        "device": "Apple Watch Series 9",
        "route": {
            "point_count": n_points,
            "inline": inline_route,
            "points": points if inline_route else [],
        },
    }


def make_envelope(
    *,
    batch_id: str | None = None,
    samples: list[dict] | None = None,
    workouts: list[dict] | None = None,
    source: str = "ios.healthsync",
    device_id: str = "iPhone-Calin",
    ack_port: int = 1002,
    v: int = 1,
) -> dict:
    return {
        "v": v,
        "source": source,
        "device_id": device_id,
        "device_model": "iPhone 15 Pro Max",
        "os_version": "iOS 17.6",
        "app_version": "0.1.0",
        "batch_id": batch_id or str(uuid.uuid4()),
        "sent_at": 1701234567.123,
        "ack_port": ack_port,
        "samples": samples or [],
        "workouts": workouts or [],
        "metadata": {"network": "wifi", "battery_level": 0.82, "wake_window": [7, 23]},
    }
