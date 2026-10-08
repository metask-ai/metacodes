import datetime
import unittest

from events.model import Event
from events.recur import occurrences_utc

UTC = datetime.timezone.utc


class TimezoneTest(unittest.TestCase):
    def test_berlin_daily_follows_local_time(self):
        event = Event("Standup", datetime.datetime(2026, 1, 5, 9, 0), 15, "daily", tz="Europe/Berlin")
        self.assertEqual(occurrences_utc(event, datetime.datetime(2026, 1, 6, tzinfo=UTC),
                                         datetime.datetime(2026, 1, 7, tzinfo=UTC)),
                         [datetime.datetime(2026, 1, 6, 8, 0, tzinfo=UTC)])
        self.assertEqual(occurrences_utc(event, datetime.datetime(2026, 7, 6, tzinfo=UTC),
                                         datetime.datetime(2026, 7, 7, tzinfo=UTC)),
                         [datetime.datetime(2026, 7, 6, 7, 0, tzinfo=UTC)])


if __name__ == "__main__":
    unittest.main()
