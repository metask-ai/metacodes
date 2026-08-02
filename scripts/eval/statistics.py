"""Small-sample statistics for repeated agent rollouts (stdlib only)."""

from __future__ import annotations

import math
from typing import Iterable, Optional, Sequence, Tuple


_T_CRITICAL_95 = {
    1: 12.706,
    2: 4.303,
    3: 3.182,
    4: 2.776,
    5: 2.571,
    6: 2.447,
    7: 2.365,
    8: 2.306,
    9: 2.262,
    10: 2.228,
    11: 2.201,
    12: 2.179,
    13: 2.160,
    14: 2.145,
    15: 2.131,
    16: 2.120,
    17: 2.110,
    18: 2.101,
    19: 2.093,
    20: 2.086,
    21: 2.080,
    22: 2.074,
    23: 2.069,
    24: 2.064,
    25: 2.060,
    26: 2.056,
    27: 2.052,
    28: 2.048,
    29: 2.045,
    30: 2.042,
}


def wilson_interval(successes: int, total: int, z: float = 1.96) -> Tuple[float, float]:
    if total <= 0:
        return (0.0, 1.0)
    proportion = successes / total
    denominator = 1.0 + z * z / total
    center = (proportion + z * z / (2.0 * total)) / denominator
    half = (
        z
        * math.sqrt(
            proportion * (1.0 - proportion) / total + z * z / (4.0 * total * total)
        )
        / denominator
    )
    return (max(0.0, center - half), min(1.0, center + half))


def percentile(values: Sequence[float], quantile: float) -> Optional[float]:
    if not values:
        return None
    if not 0.0 <= quantile <= 1.0:
        raise ValueError("quantile must be between 0 and 1")
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return float(ordered[lower])
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def mean(values: Iterable[float]) -> Optional[float]:
    materialized = list(values)
    if not materialized:
        return None
    return sum(materialized) / len(materialized)


def sample_variance(values: Sequence[float]) -> Optional[float]:
    if len(values) < 2:
        return None
    center = sum(values) / len(values)
    return sum((value - center) ** 2 for value in values) / (len(values) - 1)


def mean_confidence_interval_95(
    values: Sequence[float],
) -> Tuple[Optional[float], Optional[float]]:
    """Two-sided 95% CI for a paired mean delta using Student's t.

    A single pair has no estimable variance and therefore returns (None, None)
    instead of pretending the observed delta is certain.
    """
    if len(values) < 2:
        return (None, None)
    center = sum(values) / len(values)
    variance = sample_variance(values)
    assert variance is not None
    df = len(values) - 1
    critical = _T_CRITICAL_95.get(df, 1.96)
    half = critical * math.sqrt(variance / len(values))
    return (center - half, center + half)


def exact_mcnemar(discordant_regressions: int, discordant_improvements: int) -> float:
    """Two-sided exact McNemar p-value for paired binary rollouts.

    Under the null, either direction is equally likely for each discordant pair.
    This exact binomial form is stable for the small suites used during harness
    development and avoids an external statistics dependency.
    """
    if discordant_regressions < 0 or discordant_improvements < 0:
        raise ValueError("discordant counts must be non-negative")
    total = discordant_regressions + discordant_improvements
    if total == 0:
        return 1.0
    tail = min(discordant_regressions, discordant_improvements)
    numerator = sum(math.comb(total, k) for k in range(tail + 1))
    return min(1.0, 2.0 * numerator / (2**total))
