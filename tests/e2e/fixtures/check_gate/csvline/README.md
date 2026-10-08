# csvline

Implement `parse_line(line)` in `csvline.py`. It splits one line of CSV
text (it contains no newline characters) into a list of field strings.

- Fields are separated by commas: `a,b,c` → `["a", "b", "c"]`.
- A field may be enclosed in double quotes. Inside a quoted field commas
  are literal, and two double quotes (`""`) stand for one double quote:
  `"x,y","say ""hi"""` → `["x,y", 'say "hi"']`.
- Nothing is trimmed: spaces belong to the field (` a , b ` →
  `[" a ", " b "]`).
- An empty line is one empty field (`[""]`). A trailing comma adds a final
  empty field (`a,` → `["a", ""]`), and `,` → `["", ""]`.
- A field is quoted only when its very first character is a double quote.
  A double quote anywhere else in an unquoted field is an ordinary
  character (`a"b` → `['a"b']`).
- Raise `ValueError` when a quoted field is not closed, or when its closing
  quote is followed by anything other than a comma or the end of the line
  (`"a"b`).
