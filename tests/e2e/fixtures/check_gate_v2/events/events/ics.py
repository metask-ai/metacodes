"""iCalendar export."""

_RRULE = {"daily": "FREQ=DAILY", "weekly": "FREQ=WEEKLY"}


def to_ics(events):
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//events//EN"]
    for event in events:
        lines.append("BEGIN:VEVENT")
        lines.append("SUMMARY:" + event.name)
        lines.append("DTSTART:" + event.start.strftime("%Y%m%dT%H%M%S") + "Z")
        lines.append("DURATION:PT%dM" % event.minutes)
        if event.repeat:
            lines.append("RRULE:" + _RRULE[event.repeat])
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    return "\r\n".join(lines) + "\r\n"
