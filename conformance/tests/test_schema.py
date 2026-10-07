import unittest

from symphony_conformance.schema import Schema


class SchemaTest(unittest.TestCase):
    def test_nullable_integer(self):
        count = {"inputTokens": 0, "outputTokens": 0, "totalTokens": 0,
                 "cachedInputTokens": 0, "reasoningOutputTokens": 0}
        frame = {"method": "thread/tokenUsage/updated", "params": {
            "threadId": "fixture", "turnId": "turn", "tokenUsage": {
                "total": count, "last": count, "modelContextWindow": None}}}
        Schema().validate(frame, "server")


if __name__ == "__main__":
    unittest.main()
