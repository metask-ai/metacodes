import datetime
import unittest

from todo.export import to_csv
from todo.store import TaskStore


class ExportTest(unittest.TestCase):
    def test_rows_in_id_order(self):
        store = TaskStore()
        store.add("Taxes", "low", datetime.date(2027, 4, 15))
        store.add("Fix leak", "high")
        store.add("Call Bo", "normal", datetime.date(2026, 10, 12))
        store.complete(2)
        self.assertEqual(to_csv(store), (
            "id,title,priority,due,done\n"
            "1,Taxes,low,2027-04-15,no\n"
            "2,Fix leak,high,,yes\n"
            "3,Call Bo,normal,2026-10-12,no\n"))


if __name__ == "__main__":
    unittest.main()
