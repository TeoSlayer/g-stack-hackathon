"""Rule base class.

A Rule consumes the Coach's SQL surface, produces a structured result.
The engine handles cooldown, gbrain write, and Telegram delivery.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ..client import Coach


class Band(str, Enum):
    good = "good"
    warn = "warn"
    bad = "bad"


@dataclass
class RuleResult:
    """One evaluation of one rule on one snapshot of the warehouse."""

    rule_id: str
    band: Band
    # The single headline number the rule computed (e.g. HRV/RHR ratio).
    value: float
    # Human-readable explanation, used in Telegram + gbrain.
    message: str
    # Optional source rows for the gbrain insight (so we can cite numbers).
    detail: dict = field(default_factory=dict)

    @property
    def fires(self) -> bool:
        return self.band is not Band.good


class Rule:
    """Subclasses set `id`, `default_cooldown_h`, and implement `evaluate`."""

    id: str = "<rule-id>"
    title: str = "<one-line rule title>"
    # How long after a fire before this rule may fire again. 4h is the
    # default per `agent-b/README.md`; some rules (circadian) want longer.
    default_cooldown_h: float = 4.0

    def evaluate(self, coach: "Coach") -> RuleResult | None:
        """Return a RuleResult if the rule could evaluate, or None if data
        was insufficient (NOT an error; just "skip this turn")."""
        raise NotImplementedError

    # ── helpers shared by subclasses ────────────────────────────────────────

    @staticmethod
    def _query_rows(coach: "Coach", sql: str) -> list[dict]:
        """Run a SQL query via Pilot and return the row list, or [] on
        failure. The rule shouldn't crash the engine if Pilot's slow."""
        result = coach.query(sql, limit=2000)
        if not result.get("ok"):
            return []
        return result.get("rows", []) or []
