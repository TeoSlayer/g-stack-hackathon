"""Trust + version policy."""

from __future__ import annotations

import pytest

from collector.trust import TrustPolicy, TrustRejected, VersionRejected, check_schema_version


def test_wildcard_accepts_everyone():
    p = TrustPolicy()
    p.check_source("anyone")
    p.check_source(None)
    p.check_coach("anyone")


def test_strict_source_allowlist():
    p = TrustPolicy(source_allowlist={"ios.alex"})
    p.check_source("ios.alex")
    with pytest.raises(TrustRejected):
        p.check_source("stranger")
    with pytest.raises(TrustRejected):
        p.check_source(None)


def test_strict_coach_allowlist():
    p = TrustPolicy(coach_allowlist={"coach.x"})
    p.check_coach("coach.x")
    with pytest.raises(TrustRejected):
        p.check_coach("stranger")


def test_from_config():
    p = TrustPolicy.from_config({"sources": ["a", "b"], "coaches": ["c"]})
    assert p.source_allowlist == {"a", "b"}
    assert p.coach_allowlist == {"c"}


def test_subscribed_coaches_excludes_wildcard():
    p = TrustPolicy(coach_allowlist={"*", "coach.x"})
    assert set(p.subscribed_coaches()) == {"coach.x"}

    p2 = TrustPolicy()  # default wildcard only
    assert set(p2.subscribed_coaches()) == set()


def test_version_acceptance():
    check_schema_version(1)
    check_schema_version(0)  # v-1
    with pytest.raises(VersionRejected):
        check_schema_version(2)
    with pytest.raises(VersionRejected):
        check_schema_version(-1)
