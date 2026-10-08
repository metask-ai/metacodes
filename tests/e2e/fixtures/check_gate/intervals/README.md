# intervals

Implement `merge(intervals)` in `intervals.py`.

`intervals` is a list of `(start, end)` tuples of integers describing
half-open ranges `[start, end)`. Return a new list of disjoint
`(start, end)` tuples, sorted by `start`, that covers exactly the same
integers.

- Overlapping ranges merge, and so do ranges that touch: `[1, 3)` and
  `[3, 5)` become `[1, 5)`. `[1, 2)` and `[3, 4)` do not touch.
- Empty ranges (`start == end`) cover nothing and never appear in the
  result.
- The input may be unsorted and may contain duplicates. It must not be
  modified.
- Raise `ValueError` if any range has `start > end`.
- The result contains tuples, not lists.
