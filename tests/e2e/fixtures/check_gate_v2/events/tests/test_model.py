import datetime
import unittest

from events.model import Event


class EventTest(unittest.TestCase):
    def test_validation(self):
        with self.assertRaises(ValueError):
            Event("x", datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc))
        with self.assertRaises(ValueError):
            Event("x", datetime.datetime(2026, 1, 1), repeat="monthly")
        with self.assertRaises(ValueError):
            Event("x", datetime.datetime(2026, 1, 1), minutes=0)


if __name__ == "__main__":
    unittest.main()
