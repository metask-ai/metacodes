import datetime
import os
import unittest

from events import store
from events.model import Event

HERE = os.path.dirname(os.path.abspath(__file__))


class StoreTest(unittest.TestCase):
    def test_round_trip(self):
        events = [Event("Standup", datetime.datetime(2026, 1, 5, 9, 0), 15, "daily")]
        again = store.loads(store.dumps(events))
        self.assertEqual([(e.name, e.start, e.minutes, e.repeat) for e in again],
                         [("Standup", datetime.datetime(2026, 1, 5, 9, 0), 15, "daily")])

    def test_legacy_file_loads(self):
        with open(os.path.join(HERE, "data", "legacy_events.json"), encoding="utf-8") as handle:
            events = store.loads(handle.read())
        self.assertEqual([(e.name, e.start, e.repeat) for e in events],
                         [("Standup", datetime.datetime(2026, 1, 5, 9, 0), "daily"),
                          ("Review", datetime.datetime(2026, 3, 2, 14, 30), None)])


if __name__ == "__main__":
    unittest.main()
