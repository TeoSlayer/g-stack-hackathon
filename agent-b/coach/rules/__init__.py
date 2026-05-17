"""Coach rule engine.

Each rule:
  - Pulls bio data from the Collector via `coach.client.Coach.query()`.
  - Computes a single number + classifies it into a band: `good | warn | bad`.
  - When band ≠ good AND the cooldown has expired, the engine fires a
    nudge (Telegram message + gbrain insight write).

Implementing 3 of the 7 planned rules for v1 — these three are the most
data-cheap, the rest require multi-week state we don't have yet:

  - sleep_regularity   (14 nights of sleep onset → variance)
  - autonomic_balance  (last 7d HRV / RHR z-score vs trailing baseline)
  - sedentary_stress   (today's steps vs trailing-7d median)

Future:
  - cognitive_recovery_debt   (needs sleep debt + HRV depression)
  - burnout_cusum             (needs 21d+ baseline)
  - circadian_drift           (Mann-Kendall on bedtimes)
  - kalman_hrv                (state-space HRV denoiser)
"""

from .base import Band, Rule, RuleResult
from .engine import RuleEngine
from .sleep_regularity import SleepRegularity
from .autonomic_balance import AutonomicBalance
from .sedentary_stress import SedentaryStress

__all__ = [
    "Band",
    "Rule",
    "RuleResult",
    "RuleEngine",
    "SleepRegularity",
    "AutonomicBalance",
    "SedentaryStress",
    "ALL_RULES",
]


ALL_RULES = [SleepRegularity, AutonomicBalance, SedentaryStress]
