"""Reject JSON values that cannot survive a strict evidence replay."""

import unittest

from symphony_conformance.assets import decode


class AssetTests(unittest.TestCase):
    def test_float_overflow(self):
        for value in ("1e309", "-1e309"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                decode('{"ratio":' + value + '}')

    def test_finite_float_is_preserved(self):
        self.assertEqual(decode('{"ratio":3.25}'), {"ratio": 3.25})

    def test_deep_json_is_rejected(self):
        with self.assertRaises(ValueError):
            decode("[" * 2000 + "0" + "]" * 2000)


if __name__ == "__main__":
    unittest.main()
