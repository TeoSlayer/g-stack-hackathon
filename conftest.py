"""Repo-root conftest — fixtures available to every test.

Pytest auto-discovers this file going up from each test file, so both
`agent-a/tests/*.py` and `agent-b/tests/*.py` get the same fixtures.
Helper functions (factory builders for envelopes/samples) live in
`tests.helpers` and must be imported explicitly.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from collector.trust import TrustPolicy
from collector.warehouse import Warehouse


@pytest.fixture
def warehouse(tmp_path: Path) -> Warehouse:
    wh = Warehouse(tmp_path / "facts.duckdb")
    yield wh
    wh.close()


@pytest.fixture
def trust_open() -> TrustPolicy:
    return TrustPolicy(source_allowlist={"*"}, coach_allowlist={"*"})


@pytest.fixture
def trust_strict() -> TrustPolicy:
    return TrustPolicy(
        source_allowlist={"ios.healthsync.alex"},
        coach_allowlist={"coach.readiness"},
    )
