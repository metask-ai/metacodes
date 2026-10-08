# Time zones for events

Events are all in UTC today. Teams in other cities need local times.

- `Event` gets a `tz` field: an IANA zone name such as `Europe/Berlin`,
  default `"UTC"`. An unknown zone raises `ValueError` when the event is
  created.
- `start` stays a naive datetime; it now means wall-clock time in `tz`.
- `recur.occurrences(event, start, end)` is unchanged: naive window bounds,
  naive local wall-clock results.
- New `recur.occurrences_utc(event, start, end)`: the same occurrences as
  timezone-aware UTC datetimes, for a window given as aware datetimes
  (`start <= t < end`). A repeating event keeps its local wall-clock time across
  daylight-saving changes: a daily 09:00 event in `Europe/Berlin` is at 08:00
  UTC in January and at 07:00 UTC in July.
- Storage writes the `tz`; files written before this change have no `tz` key
  and load as `UTC`.
- ICS export: UTC events keep `DTSTART:20261008T090000Z`; events in other zones
  use `DTSTART;TZID=Europe/Berlin:20261008T090000`.
