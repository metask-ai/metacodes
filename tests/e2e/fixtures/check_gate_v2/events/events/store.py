"""JSON storage for events."""
import datetime
import json

from .model import Event


def to_dict(event):
    return {"name": event.name, "start": event.start.isoformat(), "minutes": event.minutes,
            "repeat": event.repeat}


def from_dict(data):
    return Event(data["name"], datetime.datetime.fromisoformat(data["start"]),
                 data.get("minutes", 60), data.get("repeat"))


def dumps(events):
    return json.dumps([to_dict(event) for event in events], indent=2)


def loads(text):
    return [from_dict(row) for row in json.loads(text)]
