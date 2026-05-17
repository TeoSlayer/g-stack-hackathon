"""Autonomic balance — HRV vs RHR z-score against the user's own baseline.

HRV alone can mislead because everyone has different absolute values.
The HRV/RHR ratio captures parasympathetic *relative* tone for this user.

  ratio_today = HRV_today / RHR_today
  z = (ratio_today - mean(ratio_last_14d)) / stddev(ratio_last_14d)

Bands:
  good : z ≥ -0.5
  warn : -1.5 ≤ z < -0.5
  bad  : z < -1.5
"""

from __future__ import annotations

from statistics import mean, stdev
from typing import TYPE_CHECKING

from .base import Band, Rule, RuleResult

if TYPE_CHECKING:
    from ..client import Coach


class AutonomicBalance(Rule):
    id = "autonomic_balance"
    title = "Autonomic balance"
    default_cooldown_h = 4.0

    SQL = """
        SELECT
            date_trunc('day', to_timestamp(start_utc)) AS day,
            type,
            AVG(value) AS v
        FROM samples
        WHERE type IN ('heartRateVariabilitySDNN','restingHeartRate')
          AND start_utc > epoch_ms(now() - INTERVAL '14 days') / 1000
        GROUP BY 1, 2
        ORDER BY 1
    """

    def evaluate(self, coach: "Coach") -> RuleResult | None:
        rows = self._query_rows(coach, self.SQL)
        if not rows:
            return None

        by_day: dict[str, dict[str, float]] = {}
        for r in rows:
            day = str(r["day"])[:10]
            by_day.setdefault(day, {})[r["type"]] = float(r["v"])

        # Need both HRV and RHR per day, ≥ 5 days for a stable baseline.
        ratios: list[tuple[str, float]] = []
        for day, m in sorted(by_day.items()):
            if "heartRateVariabilitySDNN" in m and "restingHeartRate" in m and m["restingHeartRate"] > 0:
                ratios.append((day, m["heartRateVariabilitySDNN"] / m["restingHeartRate"]))
        if len(ratios) < 5:
            return None

        # Today's ratio vs baseline of the rest.
        today_day, today_ratio = ratios[-1]
        baseline_vals = [r for _d, r in ratios[:-1]]
        if len(baseline_vals) < 4:
            return None
        mu = mean(baseline_vals)
        sd = stdev(baseline_vals) if len(baseline_vals) >= 2 else 0.0
        if sd == 0:
            return None  # baseline is degenerate; can't z-score
        z = (today_ratio - mu) / sd

        if z >= -0.5:
            band = Band.good
            msg = (f"Autonomic balance steady. HRV/RHR ratio z = {z:+.2f} vs your "
                   f"{len(baseline_vals)}-day baseline.")
        elif z >= -1.5:
            band = Band.warn
            msg = (f"Autonomic balance soft. HRV/RHR ratio is {z:+.2f}σ below baseline. "
                   f"Light day recommended.")
        else:
            band = Band.bad
            msg = (f"Autonomic stress signal: HRV/RHR ratio is {z:+.2f}σ below your baseline. "
                   f"Treat today as a rest day; protect sleep tonight.")

        return RuleResult(
            rule_id=self.id,
            band=band,
            value=round(z, 2),
            message=msg,
            detail={
                "today_day": today_day,
                "today_ratio": round(today_ratio, 4),
                "baseline_mean": round(mu, 4),
                "baseline_sd": round(sd, 4),
                "baseline_n": len(baseline_vals),
            },
        )
