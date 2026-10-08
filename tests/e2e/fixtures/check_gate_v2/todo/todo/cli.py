"""Command-line front end: `add`, `done`, `list`, `export`."""
import datetime

from .export import to_csv


def format_task(task):
    box = "[x]" if task.done else "[ ]"
    extra = task.priority
    if task.due:
        extra += ", due " + task.due.isoformat()
    return "%s %d %s (%s)" % (box, task.id, task.title, extra)


def main(argv, store, out):
    """Run one command; output lines are appended to `out`."""
    command, args = argv[0], argv[1:]
    if command == "add":
        priority = args[1] if len(args) > 1 else "normal"
        due = datetime.date.fromisoformat(args[2]) if len(args) > 2 else None
        task = store.add(args[0], priority, due)
        out.append("added %d" % task.id)
    elif command == "done":
        store.complete(int(args[0]))
        out.append("done %s" % args[0])
    elif command == "list":
        for task in store.all():
            out.append(format_task(task))
    elif command == "export":
        out.append(to_csv(store))
    else:
        raise ValueError("unknown command %r" % command)
    return 0
