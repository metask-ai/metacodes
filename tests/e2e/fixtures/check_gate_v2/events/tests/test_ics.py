import datetime
import unittest

from events.ics import to_ics
from events.model import Event


class IcsTest(unittest.TestCase):
    def test_utc_event(self):
        event = Event("Standup", datetime.datetime(2026, 10, 8, 9, 0), 15, "daily")
        self.assertEqual(to_ics([event]), "\r\n".join([
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//events//EN",
            "BEGIN:VEVENT", "SUMMARY:Standup", "DTSTART:20261008T090000Z", "DURATION:PT15M",
            "RRULE:FREQ=DAILY", "END:VEVENT", "END:VCALENDAR"]) + "\r\n")


if __name__ == "__main__":
    unittest.main()
