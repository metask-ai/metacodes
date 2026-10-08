"""Calendar events."""
import datetime
from dataclasses import dataclass
from typing import Optional

REPEATS = (None, "daily", "weekly")


@dataclass
class Event:
    name: str
    start: datetime.datetime  # naive, UTC
    minutes: int = 60
    repeat: Optional[str] = None

    def __post_init__(self):
        if self.start.tzinfo is not None:
            raise ValueError("start must be a naive datetime")
        if self.repeat not in REPEATS:
            raise ValueError("unknown repeat %r" % self.repeat)
        if self.minutes <= 0:
            raise ValueError("minutes must be positive")
