import unittest

from library.members import Member, load_members


class MembersTest(unittest.TestCase):
    def test_load(self):
        members = load_members('[{"id": "m1", "name": "Ann"}, {"id": "m2", "name": "Bo"}]')
        self.assertEqual(members["m1"].name, "Ann")
        self.assertEqual(sorted(members), ["m1", "m2"])

    def test_construct(self):
        self.assertEqual(Member("m3", "Cy").name, "Cy")


if __name__ == "__main__":
    unittest.main()
