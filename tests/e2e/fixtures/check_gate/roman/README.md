# roman

Implement `to_roman(n)` and `from_roman(text)` in `roman.py`.

- Numerals use I=1, V=5, X=10, L=50, C=100, D=500, M=1000 and the six
  subtractive pairs IV, IX, XL, XC, CD, CM, in the standard (canonical)
  form: `to_roman(1994) == "MCMXCIV"`, `to_roman(4) == "IV"`.
- The supported range is 1 to 3999; `to_roman` raises `ValueError` outside
  it.
- `to_roman` raises `TypeError` unless `n` is an `int` (a `bool` is not
  accepted).
- `from_roman` accepts only the canonical form of a number in range, so
  `from_roman(to_roman(n)) == n` for every supported `n`, and every other
  string raises `ValueError` — including `IIII`, `VV`, `IC`, `XM`, `IIV`,
  `MMMM`, lowercase numerals, surrounding spaces and the empty string.
