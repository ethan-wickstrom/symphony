import unittest

from symphony_conformance.linear import matches, select


class LinearTest(unittest.TestCase):
    def test_inline_alias(self):
        result = select({"query": 'query { tasks: issues(first: 2, filter: {id: {in: ["A"]}}) { nodes { id } } }'})
        self.assertEqual(result["response_key"], "tasks")
        self.assertTrue(matches({"id": "A"}, result["filter"]))
        self.assertFalse(matches({"id": "B"}, result["filter"]))

    def test_variables_and_defaults(self):
        result = select({"query": 'query Different($pick: IssueFilter!, $limit: Int = 3) { issues(filter: $pick, first: $limit) { nodes { id } } }',
                         "operationName": "Different", "variables": {"pick": {"id": {"in": ["A"]}}}})
        self.assertEqual(result["first"], 3)
        self.assertEqual(result["filter"], {"id": {"in": ["A"]}})

    def test_unknown_operator(self):
        with self.assertRaises(ValueError):
            matches({"id": "A"}, {"id": {"guess": "A"}})

    def test_non_query(self):
        with self.assertRaises(ValueError):
            select({"query": 'mutation { issues(first: 1, filter: {}) { nodes { id } } }'})

    def test_linear_ordering(self):
        result = select({"query": 'query { issues(first: 2, filter: {id: {in: ["A"]}}, orderBy: createdAt, includeArchived: false) { nodes { id } } }'})
        self.assertEqual(result["orderBy"], "createdAt")
        self.assertIs(result["includeArchived"], False)


if __name__ == "__main__":
    unittest.main()
