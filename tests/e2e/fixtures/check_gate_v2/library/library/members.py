"""Library members."""
import json
from dataclasses import dataclass


@dataclass
class Member:
    id: str
    name: str


def load_members(text):
    """Members from a JSON list of {"id", "name"} objects, keyed by id."""
    return {row["id"]: Member(row["id"], row["name"]) for row in json.loads(text)}
