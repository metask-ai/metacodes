"""Tasks."""
import datetime
from dataclasses import dataclass
from typing import Optional

PRIORITIES = ("high", "normal", "low")


@dataclass
class Task:
    id: int
    title: str
    priority: str = "normal"
    due: Optional[datetime.date] = None
    done: bool = False

    def __post_init__(self):
        if self.priority not in PRIORITIES:
            raise ValueError("unknown priority %r" % self.priority)
        if not self.title.strip():
            raise ValueError("empty title")
