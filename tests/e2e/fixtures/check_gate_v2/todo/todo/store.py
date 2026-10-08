"""An in-memory task store with a JSON form."""
import datetime
import json

from .model import Task
from .ordering import sort_tasks


class TaskStore:
    def __init__(self):
        self._tasks = {}
        self._next_id = 1

    def add(self, title, priority="normal", due=None):
        task = Task(self._next_id, title, priority, due)
        self._tasks[task.id] = task
        self._next_id += 1
        return task

    def complete(self, task_id):
        self.get(task_id).done = True

    def get(self, task_id):
        try:
            return self._tasks[task_id]
        except KeyError:
            raise KeyError("no task %d" % task_id) from None

    def all(self):
        return sort_tasks(self._tasks.values())

    def to_json(self):
        return json.dumps([{"id": t.id, "title": t.title, "priority": t.priority,
                            "due": t.due.isoformat() if t.due else None, "done": t.done}
                           for t in self.all()], indent=2)

    @classmethod
    def from_json(cls, text):
        store = cls()
        for row in json.loads(text):
            due = datetime.date.fromisoformat(row["due"]) if row.get("due") else None
            task = Task(row["id"], row["title"], row.get("priority", "normal"), due, row.get("done", False))
            store._tasks[task.id] = task
            store._next_id = max(store._next_id, task.id + 1)
        return store
