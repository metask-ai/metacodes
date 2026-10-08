# sheet

Implement the `Sheet` class in `sheet.py`: a tiny spreadsheet.

## Cells

- A reference is one column letter `A`–`Z` followed by a row number `1`–`99`
  (`B7`), case-insensitive. Passing anything else to `set` or `get` raises
  `ValueError`.
- `set(ref, raw)` stores the raw text of a cell; `set(ref, "")` empties it.
- `get(ref)` returns the cell's current value. An empty cell is `None`.
- A raw text starting with `=` is a formula. Otherwise an integer
  (`42`, `-7`) is an `int`, a decimal number (`2.5`, `-0.25`) a `float`, and
  anything else is text (the string itself).
- Values always reflect the current contents of every cell.

## Formulas

Grammar, lowest precedence first:

1. comparison `=`, `<>`, `<`, `>`, `<=`, `>=` (left-associative)
2. concatenation `&` (left-associative)
3. `+`, `-` (left-associative)
4. `*`, `/` (left-associative)
5. `^` (right-associative)
6. unary `-` and `+`, which bind tighter than `^`: `=-2^2` is `4`
7. atoms: numbers (`3`, `2.5`), strings in double quotes (`"a""b"` is `a"b`),
   `TRUE`/`FALSE`, cell references, function calls `NAME(arg, ...)`,
   parentheses.

Function names and `TRUE`/`FALSE` are case-insensitive. A range `A1:B3` (the
inclusive rectangle; the corners may be given in either order) may appear only
as a function argument.

## Values

- A formula that is just a reference to an empty cell is `0`.
- Arithmetic (`+ - * / ^` and unary signs) takes numbers as they are,
  `TRUE`/`FALSE` as 1/0 and an empty cell as 0; text is `#VALUE!`. A result
  that is a whole number is an `int` (`=6/2` is `3`, `=2.5*2` is `5`), otherwise
  a `float`.
- `&` joins text: a number as `str` of its value (`3`, `2.5`), `TRUE`/`FALSE`
  as `TRUE`/`FALSE`, an empty cell as `""`.
- Comparisons return `True`/`False`. Two numbers (booleans count as 1/0)
  compare numerically; two texts compare case-insensitively; a number is always
  less than a text. An empty cell compares as `0` against a number and as `""`
  against a text.

## Functions

- `SUM`, `MIN`, `MAX`, `AVERAGE`, `COUNT` take one or more arguments, each an
  expression or a range. From ranges they use only cells whose value is a
  number (empty cells, text and booleans are skipped); a direct argument must be
  a number or a boolean (text is `#VALUE!`). `MIN`/`MAX` of no numbers is `0`,
  `AVERAGE` of no numbers is `#DIV/0!`, and `COUNT` is how many numbers were
  used.
- `IF(cond, then, else)`: `cond` is true for a nonzero number or `TRUE`; a text
  condition is `#VALUE!`. Only the chosen branch is evaluated.
- `ABS(x)`. `ROUND(x, digits)` rounds half away from zero, working on the
  decimal text `str(x)`: `ROUND(2.5, 0)` is `3`, `ROUND(-2.5, 0)` is `-3`,
  `ROUND(1.005, 2)` is `1.01`.
- A wrong number of arguments is `#VALUE!`.

## Errors

Errors are values — these strings: `#VALUE!`, `#DIV/0!` (division by zero),
`#NUM!` (a power that is not a real number, such as `=(-8)^0.5`), `#NAME?` (an
unknown function or a bare word), `#REF!` (a reference outside A1–Z99, such as
`AA1` or `A100`), `#ERROR!` (a formula that does not parse) and `#CYCLE!` (a
cell whose value depends on itself: every cell on the cycle, and every cell that
needs one of them, is `#CYCLE!`). An operation on an error returns that error;
when both operands are errors, the left one wins. A function returns the first
error among the values it uses.
