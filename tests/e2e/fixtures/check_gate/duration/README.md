# duration

Implement `parse_duration(text)` in `duration.py`. It converts a compact
duration string to a whole number of seconds, returned as an `int`.

## Format

One or more `<number><unit>` components with no separators.

- Units: `d` (86400 s), `h` (3600 s), `m` (60 s), `s` (1 s). Lowercase
  only.
- Each unit appears at most once, and components appear in the order `d`,
  `h`, `m`, `s` (any subset, for example `2d30m`).
- A number is one or more digits, optionally followed by a dot and one or
  more digits (`1.5`). No sign, no leading or trailing dot.

## Result

- The total must be a whole number of seconds. Compute it exactly, as
  decimal arithmetic rather than binary floating point: `0.1m` is exactly
  `6`. Raise `ValueError` when the total is not whole (`1.5s`, `0.01m`).
- Raise `ValueError` for an empty string, whitespace anywhere, a missing
  number (`h`), a missing unit (`10`), an unknown or uppercase unit, a
  repeated unit (`1h1h`), components out of order (`1m1h`), or a malformed
  number (`.5h`, `5.h`, `1.5.2h`, `+1h`).

## Examples

`1h30m` → `5400`, `90s` → `90`, `2d` → `172800`, `1.5h` → `5400`,
`1d2h3m4s` → `93784`, `0s` → `0`.
