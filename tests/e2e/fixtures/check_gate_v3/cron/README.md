# cronexpr

Implement `next_fire(expr, after)` in `cronexpr.py`.

`expr` is a cron expression and `after` a naive `datetime`. Return the earliest
minute strictly later than `after` that matches `expr`, as a naive `datetime`
with `second == 0` and `microsecond == 0`.

## Fields

Five fields separated by one or more spaces or tabs, in this order:

| field | values | names |
|---|---|---|
| minute | 0–59 | |
| hour | 0–23 | |
| day of month | 1–31 | |
| month | 1–12 | `JAN`–`DEC` |
| day of week | 0–7 (0 and 7 both mean Sunday) | `SUN`–`SAT` |

Names are case-insensitive, are valid only in their own field, and may appear
anywhere a number may (`MON-FRI`, `JAN,jul`).

Each field is a comma-separated list of items. An item is one of:

- `*` — every value of the field;
- `N` — one value;
- `A-B` — the values A through B inclusive (A must not be greater than B);
- any of the above followed by `/S` with S ≥ 1 — every S-th value of that span,
  starting at its first value. `*/15` in the minute field is 0, 15, 30, 45.
  `N/S` means `N-<field maximum>/S`, so `5/20` in the minute field is 5, 25, 45.

## Day matching

A day-of-month or day-of-week field is *unrestricted* when its text starts with
`*` (so `*/2` counts as unrestricted). A day matches when its month matches and:

- if both day of month and day of week are restricted, the day matches
  **either** of them (`0 0 13 * FRI` fires on every 13th and on every Friday);
- otherwise the day must match **both** (`0 0 */2 * MON` fires on Mondays that
  fall on an odd day of the month).

## Macros

`@yearly` and `@annually` mean `0 0 1 1 *`; `@monthly` means `0 0 1 * *`;
`@weekly` means `0 0 * * 0`; `@daily` and `@midnight` mean `0 0 * * *`;
`@hourly` means `0 * * * *`.

## Errors

Raise `ValueError` for: a wrong number of fields, an unknown macro or name, a
value outside its field's range, an empty item, a reversed range, a step that is
0 or not a number, a missing number (`/5`, `1-`), and a schedule that never
fires — when no minute within 366 × 5 days after `after` matches.
