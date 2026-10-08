"""Occurrences of (possibly repeating) events."""
import datetime

_STEP = {"daily": datetime.timedelta(days=1), "weekly": datetime.timedelta(weeks=1)}


def occurrences(event, start, end):
    """Start times of `event` in [start, end), as naive datetimes."""
    result = []
    current = event.start
    step = _STEP.get(event.repeat)
    while current < end:
        if current >= start:
            result.append(current)
        if step is None:
            break
        current += step
    return result
