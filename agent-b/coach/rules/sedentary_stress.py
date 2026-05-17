"""Sedentary stress — today's steps vs trailing-7d median.

Easy first-line "you're under-moving" signal. Bands:
  good : today ≥ 0.8 × trailing median
  warn : 0.5 × trailing ≤ today < 0.8 × trailing
  bad  : today < 0.5 × trailing
"""

from __future__ import annotations

from statistics import median
from typing import TYPE_CHECKING

from .base import Band, Rule, RuleResult

if TYPE_CHECKING:
    from ..client import Coach


class SedentaryStress(Rule):
    id = "sedentary_stress"
    title = "Sedentary stress"
    default_cooldown_h = 8.0

    SQL = """
        SELECT
            date_trunc('day', to_timestamp(start_utc)) AS day,
            SUM(value) AS steps
        FROM samples
        WHERE type = 'stepCount'
          AND start_utc > epoch_ms(now() - INTERVAL '8 days') / 1000
        GROUP BY 1
        ORDER BY 1
    """

    def evaluate(self, coach: "Coach") -> RuleResult | None:
        rows = self._query_rows(coach, self.SQL)
        if not rows:
            return None

        # Sort just in case the SQL order didn't survive serialisation.
        rows.sort(key=lambda r: str(r["day"]))

        # Need today + ≥ 3 baseline days. Conservative.
        if len(rows) < 4:
            return None

        today_day, today_steps = str(rows[-1]["day"])[:10], float(rows[-1]["steps"] or 0)
        baseline = [float(r["steps"] or 0) for r in rows[:-1]]
        med = median(baseline)
        if med <= 0:
            return None  # no movement to compare against

        ratio = today_steps / med

        if ratio >= 0.8:
            band = Band.good
            msg = (f"Movement on track — {int(today_steps):,} steps today "
                   f"vs {int(med):,} median (last {len(baseline)}d).")
        elif ratio >= 0.5:
            band = Band.warn
            msg = (f"Under-moving — {int(today_steps):,} steps today vs "
                   f"{int(med):,} median ({ratio:.0%}). Worth a 20-min walk.")
        else:
            band = Band.bad
            msg = (f"Sedentary day — {int(today_steps):,} steps vs "
                   f"{int(med):,} median ({ratio:.0%}). Get outside before bed.")

        return RuleResult(
            rule_id=self.id,
            band=band,
            value=round(ratio, 2),
            message=msg,
            detail={
                "today_day": today_day,
                "today_steps": int(today_steps),
                "baseline_median": int(med),
                "baseline_n": len(baseline),
            },
        )
