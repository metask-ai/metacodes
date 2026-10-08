"""CSV export, one row per task in id order."""


def to_csv(store):
    rows = ["id,title,priority,due,done"]
    for task in store.all():
        rows.append("%d,%s,%s,%s,%s" % (task.id, task.title.replace(",", " "), task.priority,
                                        task.due.isoformat() if task.due else "",
                                        "yes" if task.done else "no"))
    return "\n".join(rows) + "\n"
