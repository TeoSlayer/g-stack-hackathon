"""Proactive loop for the Coach.

Called from `cmd_watch` whenever a ChangeEvent arrives on Pilot 1004
(meaning the Collector just landed a new batch from a source). Two
side effects per tick:

  1. **Brain growth (idempotent):** write/refresh a daily-summary page
     in the coach gbrain for every date that appears in the most recent
     samples. These pages accumulate over time and give the LLM richer
     context for future questions like "what was last Tuesday like?"

  2. **Rule loop:** evaluate every rule against the warehouse. Cooldowns
     are respected; firing produces a Telegram push + an insight page in
     the coach gbrain.

This loop is **idempotent**. Calling it 10 times in a row produces the
same gbrain state and at most one Telegram nudge per rule per cooldown.
"""

from __future__ import annotations

import datetime as _dt
import json
import logging
from pathlib import Path
from typing import TYPE_CHECKING

from .notify import TelegramNotifier
from .rules import ALL_RULES
from .rules.engine import CooldownStore, RuleEngine
from .tools.gbrain_writer import GbrainCLI

if TYPE_CHECKING:
    from .client import Coach


log = logging.getLogger("coach.proactive")


DAILY_SUMMARY_SQL = """
    SELECT
        date_trunc('day', to_timestamp(start_utc)) AS day,
        type,
        ROUND(AVG(value), 2) AS avg_v,
        COUNT(*) AS n
    FROM samples
    WHERE start_utc > epoch_ms(now() - INTERVAL '3 days') / 1000
    GROUP BY 1, 2
    ORDER BY 1 DESC, 2
"""


class ProactiveCoach:
    """Wraps Coach + RuleEngine + gbrain-writer + telegram for the watch loop."""

    def __init__(
        self,
        *,
        coach: "Coach",
        cooldowns_path: str | Path = "/home/alexgodo/g-stack-hackathon/infra/data/coach-cooldowns.json",
    ):
        self.coach = coach
        self.gbrain = GbrainCLI()
        self.notifier = TelegramNotifier()
        self.engine = RuleEngine(
            coach=coach,
            rules=ALL_RULES,
            cooldowns=CooldownStore(Path(cooldowns_path)),
            notifier=self.notifier,
            gbrain_writer=self.gbrain,
        )
        log.info(
            "ProactiveCoach ready — rules=%s telegram=%s gbrain_home=%s",
            [r.id for r in self.engine.rules],
            "yes" if self.notifier.configured else "no",
            self.gbrain.home,
        )

    # ── public entry points ────────────────────────────────────────────────

    def on_change_event(self, event: dict) -> None:
        """Called by `cmd_watch` for each ChangeEvent."""
        log.info("ChangeEvent: by_type=%s device=%s",
                 event.get("by_type"), event.get("device_id"))
        try:
            self._grow_brain()
        except Exception as e:
            log.warning("brain growth failed: %s", e)
        try:
            self._run_rules()
        except Exception as e:
            log.warning("rule loop failed: %s", e)

    def tick_manual(self) -> dict:
        """For one-off CLI invocations (e.g. `python -m coach proactive`).

        Returns a dict summarising what fired.
        """
        self._grow_brain()
        fired = self.engine.tick()
        return {
            "rules_fired": [r.rule_id for r in fired],
            "messages": [r.message for r in fired],
        }

    # ── implementation ──────────────────────────────────────────────────────

    def _grow_brain(self) -> None:
        """Write/refresh a daily-summary gbrain page per day in the last 3d."""
        rows = self.engine._query_rows_method(DAILY_SUMMARY_SQL) if hasattr(
            self.engine, "_query_rows_method") else self._query_rows(DAILY_SUMMARY_SQL)
        if not rows:
            return
        by_day: dict[str, dict[str, dict]] = {}
        for r in rows:
            day = str(r["day"])[:10]
            by_day.setdefault(day, {})[r["type"]] = {"avg": r["avg_v"], "n": r["n"]}

        for day, types in sorted(by_day.items()):
            slug = f"daily-summaries/{day}"
            try:
                self.gbrain.put(slug, _render_daily_summary(day, types))
                log.info("gbrain growth: wrote %s (%d metric types)", slug, len(types))
            except Exception as e:
                log.warning("daily summary write failed for %s: %s", day, e)

    def _run_rules(self) -> None:
        fired = self.engine.tick()
        for r in fired:
            log.info("RULE FIRED: %s → %s", r.rule_id, r.band.value)

    def _query_rows(self, sql: str) -> list[dict]:
        result = self.coach.query(sql, limit=2000)
        if not result.get("ok"):
            return []
        return result.get("rows", []) or []


# ─── markdown rendering ──────────────────────────────────────────────────────

def _render_daily_summary(day: str, types: dict[str, dict]) -> str:
    """Markdown body for `daily-summaries/<day>` pages.

    These pages are designed to be diffable across re-runs (so gbrain's
    chunker doesn't churn) and human-readable on Telegram if quoted.
    """
    weekday = _dt.date.fromisoformat(day).strftime("%A")
    front = (
        "---\n"
        "type: daily-summary\n"
        f"title: {day} ({weekday})\n"
        f"date: '{day}T00:00:00.000Z'\n"
        "source: coach.proactive\n"
        "tags:\n  - daily-summary\n  - autogen\n"
        "---\n\n"
    )
    body = [f"# Daily summary — {day} ({weekday})", ""]
    # Prefer a stable ordering.
    priority = [
        "heartRateVariabilitySDNN",
        "restingHeartRate",
        "oxygenSaturation",
        "respiratoryRate",
        "stepCount",
        "distanceWalkingRunning",
        "activeEnergyBurned",
        "basalEnergyBurned",
        "appleExerciseTime",
        "appleStandTime",
        "heartRate",
        "bodyMass",
        "vo2Max",
        "sleepAnalysis",
    ]
    seen = set()
    for t in priority + sorted(set(types) - set(priority)):
        if t not in types or t in seen:
            continue
        seen.add(t)
        v = types[t]
        body.append(f"- **{t}** — avg {v['avg']} (n={v['n']})")
    body.append("")
    body.append("_Auto-generated by `coach.proactive` from the Collector warehouse._")
    body.append("")
    return front + "\n".join(body)
