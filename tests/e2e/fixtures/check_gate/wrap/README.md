# wrap

Implement `wrap(text, width)` in `wrap.py`. It reflows `text` into lines no
longer than `width` characters and returns them joined with `"\n"` (no
trailing newline).

- A paragraph is a run of non-blank lines. Paragraphs are separated by one
  or more blank lines (a blank line is empty or contains only spaces). In
  the result, paragraphs are separated by exactly one empty line, and there
  are no empty lines before the first paragraph or after the last.
- Inside a paragraph, line breaks and runs of spaces only separate words.
- Lines are filled greedily: each line takes as many of the following
  words as fit, separated by single spaces. No line has leading or
  trailing spaces.
- A word longer than `width` starts on a new line and is split into pieces
  of exactly `width` characters, except the last piece, which may be
  shorter. Following words may continue on the line of that last piece if
  they fit.
- `width` must be an `int` of at least 1; raise `ValueError` otherwise.
- Text with no words returns `""`.

Example: `wrap("the quick brown fox", 10)` → `"the quick\nbrown fox"`.
