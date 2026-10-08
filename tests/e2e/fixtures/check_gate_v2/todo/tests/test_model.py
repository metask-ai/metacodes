import unittest

from todo.model import Task


class TaskTest(unittest.TestCase):
    def test_defaults(self):
        task = Task(1, "Water plants")
        self.assertEqual((task.priority, task.due, task.done), ("normal", None, False))

    def test_validation(self):
        with self.assertRaises(ValueError):
            Task(1, "x", priority="urgent")
        with self.assertRaises(ValueError):
            Task(1, "   ")


if __name__ == "__main__":
    unittest.main()
