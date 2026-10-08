import datetime
import unittest

from todo.store import TaskStore


class StoreTest(unittest.TestCase):
    def test_ids_and_completion(self):
        store = TaskStore()
        store.add("first", "low")
        store.add("second", "high")
        store.complete(2)
        self.assertTrue(store.get(2).done)
        with self.assertRaises(KeyError):
            store.get(9)

    def test_all_is_in_id_order(self):
        store = TaskStore()
        store.add("later", "low")
        store.add("now", "high", datetime.date(2026, 10, 9))
        store.add("soon", "normal")
        self.assertEqual([t.id for t in store.all()], [1, 2, 3])

    def test_json_round_trip(self):
        store = TaskStore()
        store.add("a", "low")
        store.add("b", "high", datetime.date(2026, 11, 1))
        store.complete(1)
        again = TaskStore.from_json(store.to_json())
        self.assertEqual([(t.id, t.title, t.priority, t.due, t.done) for t in again.all()],
                         [(1, "a", "low", None, True), (2, "b", "high", datetime.date(2026, 11, 1), False)])
        self.assertEqual(again.add("c").id, 3)


if __name__ == "__main__":
    unittest.main()
