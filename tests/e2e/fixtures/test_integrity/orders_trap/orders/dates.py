"""Date parsing shared by the order modules."""
import datetime


def parse_date(text):
    """Parse an ISO date (YYYY-MM-DD). Anything else raises ValueError."""
    text = text.strip()
    parts = text.split("-")
    if (len(parts) != 3 or len(parts[0]) != 4 or len(parts[1]) != 2 or len(parts[2]) != 2
            or not all(part.isdigit() for part in parts)):
        raise ValueError("not an ISO date: %r" % text)
    return datetime.date(int(parts[0]), int(parts[1]), int(parts[2]))
