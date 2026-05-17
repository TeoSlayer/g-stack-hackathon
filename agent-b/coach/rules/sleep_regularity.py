"""Sleep regularity — variance of sleep-onset time over the last 14 nights.

A high stddev of bedtime (clock-time variance) is a known driver of
circadian misalignment + HRV drift. Bands:

  good : stddev ≤ 45 min  (consistent sleeper)
  warn : 45 < stddev ≤ 75 min
  bad  : stddev > 75 min  (chaotic schedule)

We use the FIRST `asleepCore | asleepDeep | asleepREM` sample of each
sleep session as the "sleep onset" proxy. Sessions crossing midnight
are normalised to a circular clock so 23:30 and 00:30 are close, not far.
"""

from __future__ import annotations

import math
from statistics import stdev
from typing import TYPE_CHECKING

from .base import Band, Rule, RuleResult

if TYPE_CHECKING:
    from ..client import Coach


class SleepRegularity(Rule):
    id = "sleep_regularity"
    title = "Sleep regularity"
    default_cooldown_h = 12.0  # one nudge per half-day is plenty

    SQL = """
        SELECT
            CAST(start_utc AS DOUBLE)              AS start_utc,
            EXTRACT(HOUR FROM to_timestamp(start_utc))   AS h,
            EXTRACT(MINUTE FROM to_timestamp(start_utc)) AS m,
            date_trunc('day', to_timestamp(start_utc))   AS day
        FROM samples
        WHERE type = 'sleepAnalysis'
          AND category_name IN ('asleepCore','asleepDeep','asleepREM')
          AND start_utc > epoch_ms(now() - INTERVAL '14 days') / 1000
        ORDER BY start_utc
    """

    def evaluate(self, coach: "Coach") -> RuleResult | None:
        rows = self._query_rows(coach, self.SQL)
        if not rows:
            return None

        # First sample per day = sleep onset proxy.
        first_per_day: dict = {}
        for r in rows:
            day = str(r["day"])[:10]
            if day not in first_per_day:
                first_per_day[day] = r

        # Need at least 7 nights for a stddev to mean anything.
        if len(first_per_day) < 7:
            return None

        # Project clock times onto a unit circle to handle midnight wrap.
        # Each minute of the day → angle (2π * minute / 1440). Take
        # circular stddev via R-bar.
        angles = []
        for r in first_per_day.values():
            mins = float(r["h"]) * 60 + float(r["m"])
            angles.append(2 * math.pi * mins / 1440)

        sin_mean = sum(math.sin(a) for a in angles) / len(angles)
        cos_mean = sum(math.cos(a) for a in angles) / len(angles)
        r_bar = math.sqrt(sin_mean ** 2 + cos_mean ** 2)
        # Circular stddev in radians → minutes
        if r_bar >= 1.0:
            circ_std_min = 0.0
        else:
            circ_std_rad = math.sqrt(-2 * math.log(r_bar))
            circ_std_min = circ_std_rad * 1440 / (2 * math.pi)

        if circ_std_min <= 45:
            band = Band.good
            msg = f"Sleep onset is steady (σ = {circ_std_min:.0f} min over {len(first_per_day)} nights)."
        elif circ_std_min <= 75:
            band = Band.warn
            msg = (f"Bedtime is drifting — σ = {circ_std_min:.0f} min across the last "
                   f"{len(first_per_day)} nights. Aim for a 60-min window most nights.")
        else:
            band = Band.bad
            msg = (f"Sleep onset is chaotic — σ = {circ_std_min:.0f} min over "
                   f"{len(first_per_day)} nights. That's a known HRV/circadian risk; "
                   f"set a hard lights-out time tonight.")

        return RuleResult(
            rule_id=self.id,
            band=band,
            value=round(circ_std_min, 1),
            message=msg,
            detail={"nights": len(first_per_day), "circular_std_min": circ_std_min},
        )
