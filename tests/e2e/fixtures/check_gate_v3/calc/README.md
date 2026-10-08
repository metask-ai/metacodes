# calc

Implement `run(source)` and the exception class `CalcError` (a subclass of
`Exception`) in `calc.py`. `run` executes a program in the small calculator
language below and returns the printed values as a list of strings.

## Lexical structure

- Numbers: one or more digits, optionally followed by `.` and one or more
  digits (`12`, `3.25`). Numbers without a dot are `int`, with a dot `float`.
- Names: a letter or `_`, then letters, digits or `_`. `let` and `print` are
  keywords and cannot be used as names.
- Operators and punctuation: `+ - * / // % ^ ( ) , = ;`
- Spaces, tabs and newlines separate tokens; `#` starts a comment that runs to
  the end of the line.

## Statements

Statements are separated by `;` (a final `;` is optional and empty statements
are allowed). A newline does not end a statement.

- `let NAME = expr` defines or reassigns a variable.
- `print expr` evaluates `expr` and appends its formatted value to the output.
- `expr` evaluates `expr` and discards it.

The whole program is parsed before any statement runs: a syntax error anywhere
is reported even if an earlier statement would fail while running.

## Expressions

Lowest precedence first:

1. `+`, `-` (left-associative)
2. `*`, `/`, `//`, `%` (left-associative)
3. prefix `-`, `+`
4. `^`, right-associative and tighter than prefix signs: `-2 ^ 2` is `-4`,
   `2 ^ 3 ^ 2` is `512`; the exponent may itself carry a sign (`2 ^ -1`).
5. numbers, variables, calls `name(arg, ...)`, parentheses.

- `/` is true division (always a `float`). `//` and `%` follow Python (floor
  division and modulo; `int` when both operands are `int`).
- `^` with an `int` base and a non-negative `int` exponent is an exact `int`;
  otherwise it is computed in `float`.
- Functions: `abs(x)`; `min(a, ...)` and `max(a, ...)` with at least one
  argument; `sqrt(x)` (a `float`); `round(x)` rounds half away from zero to an
  `int` and `round(x, n)` rounds half away from zero to `n` decimals and gives a
  `float`. Both work on the decimal text `str(x)`, so `round(2.5)` is `3`,
  `round(-2.5)` is `-3` and `round(1.005, 2)` is `1.01`.
- Variables must be defined before they are used. Function names are not
  variables.

## Output

`print` writes an `int` as its decimal digits and a `float` as Python's
`repr` of it (`3.5`, `3.0`, `0.30000000000000004`).

## Errors

Raise `CalcError` whose message is `"<line>:<column>: <text>"`, with the 1-based
line and column of the offending token:

| situation | text | position |
|---|---|---|
| a character that starts no token | `unexpected character '$'` | the character |
| a token that cannot appear there | `unexpected token ')'` | the token |
| the program ends too early | `unexpected end of input` | just past the last character |
| an undefined variable | `undefined variable 'x'` | the name |
| an unknown function | `unknown function 'foo'` | the name |
| a wrong number of arguments | `function 'sqrt' expects 1 argument` (also `abs`), `function 'min' expects at least 1 argument` (also `max`), `function 'round' expects 1 or 2 arguments` | the function name |
| division by zero in `/`, `//` or `%` | `division by zero` | the operator |
| `sqrt` of a negative number, or a `^` whose result is not a real number | `math domain error` | the function name or the `^` |
