"""RuleEngine — runs rules, applies cooldowns, delivers nudges.

  engine = RuleEngine(coach, notifier, gbrain_writer, cooldown_store)
  for result in engine.evaluate_all():
      if result.fires:
          ...

The engine is stateful only in the cooldown store, which is a JSON file
on disk. The engine itself is created per-tick from the background watch
loop in `coach.__main__:cmd_watch`.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING, Iterable

from .base import Band, Rule, RuleResult

if TYPE_CHECKING:
    from ..client import Coach
    from ..notify import TelegramNotifier
    from ..tools.gbrain import GbrainCLI


log = logging.getLogger("coach.rules.engine")


class CooldownStore:
    """Disk-backed per-rule cooldown. JSON file with `{rule_id: epoch_seconds}`."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._data: dict[str, float] = {}
        self._load()

    def _load(self) -> None:
        if self.path.exists():
            try:
                self._data = json.loads(self.path.read_text())
            except Exception as e:
                log.warning("cooldown store unreadable (%s), starting fresh", e)
                self._data = {}

    def _save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._data, indent=2))
        tmp.replace(self.path)

    def is_active(self, rule_id: str, cooldown_h: float, *, now: float | None = None) -> bool:
        now = _dt.datetime.now(_dt.UTC).timestamp() if now is None else now
        last = self._data.get(rule_id)
        if last is None:
            return False
        return (now - last) < cooldown_h * 3600.0

    def touch(self, rule_id: str, *, now: float | None = None) -> None:
        self._data[rule_id] = _dt.datetime.now(_dt.UTC).timestamp() if now is None else now
        self._save()


class RuleEngine:
    """Evaluates rules + handles side effects."""

    def __init__(
        self,
        *,
        coach: "Coach",
        rules: Iterable[type[Rule]],
        cooldowns: CooldownStore,
        notifier: "TelegramNotifier | None" = None,
        gbrain_writer: "GbrainCLI | None" = None,
    ):
        self.coach = coach
        self.rules = [cls() for cls in rules]
        self.cooldowns = cooldowns
        self.notifier = notifier
        self.gbrain_writer = gbrain_writer

    def evaluate_all(self) -> list[tuple[Rule, RuleResult | None]]:
        out = []
        for rule in self.rules:
            try:
                result = rule.evaluate(self.coach)
            except Exception as e:
                log.warning("rule %s crashed: %s", rule.id, e)
                result = None
            out.append((rule, result))
        return out

    def tick(self) -> list[RuleResult]:
        """Single rule-loop iteration: evaluate, fire nudges where appropriate.

        Returns the list of RuleResults that actually FIRED this tick
        (after cooldown filtering).
        """
        fired: list[RuleResult] = []
        for rule, result in self.evaluate_all():
            if result is None:
                continue
            log.info("rule %s → %s (value=%s)", rule.id, result.band.value, result.value)
            if not result.fires:
                continue
            if self.cooldowns.is_active(rule.id, rule.default_cooldown_h):
                log.info("rule %s would fire but is on cooldown", rule.id)
                continue
            self._deliver(rule, result)
            self.cooldowns.touch(rule.id)
            fired.append(result)
        return fired

    # ── side effects ────────────────────────────────────────────────────────

    def _deliver(self, rule: Rule, result: RuleResult) -> None:
        """Telegram nudge + gbrain insight write."""
        msg = f"⚠️ {rule.title}: {result.message}"
        if self.notifier is not None:
            ok = self.notifier.send(msg)
            if not ok:
                log.warning("Telegram send failed for rule %s", rule.id)
        if self.gbrain_writer is not None:
            self._write_insight(rule, result)

    def _write_insight(self, rule: Rule, result: RuleResult) -> None:
        today = _dt.datetime.now(_dt.UTC).date().isoformat()
        slug = f"insights/{today}-{rule.id}"
        body = f"""---
type: insight
date: '{today}T00:00:00.000Z'
source: coach.rules
rule_id: {rule.id}
band: {result.band.value}
tags: [coach, rule, {rule.id}]
---

# {rule.title} — {today} ({result.band.value.upper()})

{result.message}

## Detail

```json
{json.dumps(result.detail, indent=2)}
```

Value: **{result.value}**
"""
        try:
            self.gbrain_writer.put(slug, body)
            log.info("wrote insight %s", slug)
        except Exception as e:
            log.warning("gbrain insight write failed: %s", e)
