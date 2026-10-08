# semver

Implement `compare(a, b)` in `semver.py`.

`a` and `b` are version strings in the Semantic Versioning 2.0.0 format
`MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]`. `compare` returns `-1` when `a`
has lower precedence than `b`, `0` when they have equal precedence, and `1`
when `a` has higher precedence.

## Precedence

1. MAJOR, MINOR and PATCH are compared numerically, in that order.
2. When the cores are equal, a version with a pre-release has lower
   precedence than the version without one (`1.0.0-alpha < 1.0.0`).
3. Two pre-releases are compared identifier by identifier (identifiers are
   separated by dots), left to right:
   - two identifiers made only of digits compare numerically;
   - two identifiers that contain a letter or a hyphen compare lexically in
     ASCII order;
   - a numeric identifier always has lower precedence than a non-numeric
     one;
   - when every compared identifier is equal, the version with more
     identifiers has higher precedence.
4. Build metadata (everything after `+`) is ignored.

Example ordering, lowest first:

`1.0.0-alpha < 1.0.0-alpha.1 < 1.0.0-alpha.beta < 1.0.0-beta < 1.0.0-beta.2 < 1.0.0-beta.11 < 1.0.0-rc.1 < 1.0.0`

## Validation

Raise `ValueError` when either argument:

- is empty, contains whitespace, or has a core that is not exactly three
  dot-separated parts;
- has a core part that is not made only of digits, or that has a leading
  zero (`01.0.0`);
- has an empty pre-release or build identifier (`1.0.0-`, `1.0.0-a..b`,
  `1.0.0+`), or an identifier with a character outside `[0-9A-Za-z-]`;
- has a numeric pre-release identifier with a leading zero (`1.0.0-01`).
  Non-numeric identifiers may start with `0` (`1.0.0-0a` is valid), and
  build identifiers may have leading zeros (`1.0.0+001` is valid).
