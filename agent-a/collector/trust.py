"""Trust + schema-version gating.

Pilot identity is the only auth at the transport layer. The Collector keeps
a per-port allowlist of identities it will accept inbound from.

  source_allowlist  — identities allowed to send Envelopes on 1001
  coach_allowlist   — identities allowed to send Queries on 1003 and
                      receive ChangeEvents on 1004

Allowlists support a wildcard "*" entry which disables the check (useful
during local development).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Optional

from .schema import ACCEPTED_VERSIONS


class VersionRejected(Exception):
    pass


class TrustRejected(Exception):
    pass


@dataclass
class TrustPolicy:
    source_allowlist: set[str] = field(default_factory=lambda: {"*"})
    coach_allowlist: set[str] = field(default_factory=lambda: {"*"})

    @classmethod
    def from_config(cls, cfg: dict) -> "TrustPolicy":
        return cls(
            source_allowlist=set(cfg.get("sources", ["*"])),
            coach_allowlist=set(cfg.get("coaches", ["*"])),
        )

    def check_source(self, identity: Optional[str]) -> None:
        if "*" in self.source_allowlist:
            return
        if identity is None:
            raise TrustRejected("source identity missing")
        if identity not in self.source_allowlist:
            raise TrustRejected(f"source identity '{identity}' not in allowlist")

    def check_coach(self, identity: Optional[str]) -> None:
        if "*" in self.coach_allowlist:
            return
        if identity is None:
            raise TrustRejected("coach identity missing")
        if identity not in self.coach_allowlist:
            raise TrustRejected(f"coach identity '{identity}' not in allowlist")

    def subscribed_coaches(self) -> Iterable[str]:
        """Return Coach identities to receive ChangeEvent broadcasts.

        A '*' entry means "no broadcast targets configured" — events go to
        the event log only.
        """
        return {c for c in self.coach_allowlist if c != "*"}


def check_schema_version(v: int) -> None:
    if v not in ACCEPTED_VERSIONS:
        raise VersionRejected(
            f"schema v={v} not in accepted versions {sorted(ACCEPTED_VERSIONS)}"
        )
