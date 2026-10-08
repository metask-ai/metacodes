"""Task ordering shared by the store and the exports."""


def sort_tasks(tasks):
    """Tasks in creation order (by id)."""
    return sorted(tasks, key=lambda task: task.id)
