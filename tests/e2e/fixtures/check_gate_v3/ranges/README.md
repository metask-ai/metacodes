# ranges

Implement `satisfies(version, range_text)` and
`max_satisfying(versions, range_text)` in `ranges.py`, following the npm-style
range syntax specified here.

## Versions

`MAJOR.MINOR.PATCH` with an optional pre-release `-ID.ID...` (identifiers made
of `[0-9A-Za-z-]`; numeric parts and numeric identifiers have no leading zeros).
No build metadata, no leading `v`, no whitespace.

Precedence follows Semantic Versioning 2.0.0: the three numbers compare
numerically; a pre-release is lower than its release; pre-release identifiers
compare left to right — two numeric identifiers numerically, a numeric
identifier lower than a non-numeric one, two non-numeric ones in ASCII order —
and when all compared identifiers are equal the longer list is higher.

## Ranges

- A range is one or more comparator sets separated by `||`; it matches when any
  set matches. An empty set (or the range `""`) matches every release.
- A comparator set is comparators separated by whitespace, all of which must
  match — or a hyphen range `A - B` (with spaces around the hyphen).
- A comparator is an optional operator `<`, `<=`, `>`, `>=`, `=`, `~` or `^`,
  optional whitespace, then a *partial* version: `1`, `1.2` or `1.2.3`, where
  `x`, `X` or `*` may stand for a part, and nothing but wildcards may follow a
  wildcard (`1.x.3` is invalid). Only a full `1.2.3` may carry a pre-release
  (`1.2.3-beta.1`).

Each comparator means the following (`<V-0` means "below V and below every
pre-release of V"):

| written | means |
|---|---|
| `*`, `x`, `X` | `>=0.0.0` |
| `1`, `1.x`, `=1` | `>=1.0.0 <2.0.0-0` |
| `1.2`, `1.2.x`, `=1.2` | `>=1.2.0 <1.3.0-0` |
| `1.2.3`, `=1.2.3` | exactly `1.2.3` |
| `>1` / `>1.2` | `>=2.0.0` / `>=1.3.0` |
| `>=1` / `>=1.2` | `>=1.0.0` / `>=1.2.0` |
| `<1` / `<1.2` | `<1.0.0-0` / `<1.2.0-0` |
| `<=1` / `<=1.2` | `<2.0.0-0` / `<1.3.0-0` |
| `~1.2.3` / `~1.2` / `~1` | `>=1.2.3 <1.3.0-0` / `>=1.2.0 <1.3.0-0` / `>=1.0.0 <2.0.0-0` |
| `^1.2.3` / `^0.2.3` / `^0.0.3` | `>=1.2.3 <2.0.0-0` / `>=0.2.3 <0.3.0-0` / `>=0.0.3 <0.0.4-0` |
| `^1.2` / `^0.2` / `^0.0` / `^1` / `^0` | `>=1.2.0 <2.0.0-0` / `>=0.2.0 <0.3.0-0` / `>=0.0.0 <0.1.0-0` / `>=1.0.0 <2.0.0-0` / `>=0.0.0 <1.0.0-0` |
| `1.2.3 - 2.3.4` | `>=1.2.3 <=2.3.4` |
| `1.2 - 2.3.4` | `>=1.2.0 <=2.3.4` |
| `1.2.3 - 2.3` / `1.2.3 - 2` | `>=1.2.3 <2.4.0-0` / `>=1.2.3 <3.0.0-0` |

`>`, `>=`, `<`, `<=` with a full version compare against exactly that version.
A pre-release written on `~`, `^` or a hyphen range stays on the lower bound:
`~1.2.3-beta.2` is `>=1.2.3-beta.2 <1.3.0-0` and `^1.2.3-beta.2` is
`>=1.2.3-beta.2 <2.0.0-0`.

## Pre-releases

A version with a pre-release satisfies a comparator set only if all of the set's
comparators match **and** at least one comparator of that set was written with a
pre-release on the same `MAJOR.MINOR.PATCH` (the `-0` bounds above do not count).
So `1.2.4-beta` does not satisfy `>=1.2.3`, while `1.2.3-rc.1` satisfies
`>=1.2.3-beta.2 <1.3.0`.

## Results and errors

- `satisfies` returns `True` or `False`, and raises `ValueError` for an invalid
  version or an invalid range.
- `max_satisfying` returns the highest version in `versions` that satisfies the
  range, skipping strings that are not valid versions, or `None` when there is
  none. It raises `ValueError` for an invalid range.
