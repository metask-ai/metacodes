# Order `todo list` by urgency

`todo list` shows tasks in creation order, so urgent work gets buried. It
should show what to do next first:

1. open tasks before done tasks;
2. open tasks by priority: `high`, then `normal`, then `low`;
3. within a priority, by due date, earliest first; tasks without a due date
   come after the ones that have one;
4. any remaining ties by id.

Done tasks come last, in id order.

`todo export` must keep exporting in id order — downstream spreadsheets depend
on it.
