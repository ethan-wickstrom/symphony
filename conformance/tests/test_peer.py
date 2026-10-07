"""Peer marker publication owns each pending file across concurrent writers."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from symphony_conformance.peer import _marker

JOIN_TIMEOUT = 5


class PeerTest(unittest.TestCase):
    def test_concurrent_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "peer.json"
            identities = [{"peer_id": "first", "pid": 1}, {"peer_id": "second", "pid": 2}]
            ready = threading.Barrier(len(identities))
            original = Path.replace

            def replace(pending, destination):
                # Both writes finish before either publisher renames its owned file.
                ready.wait(JOIN_TIMEOUT)
                return original(pending, destination)

            with patch.object(Path, "replace", replace), ThreadPoolExecutor(max_workers=len(identities)) as workers:
                writes = [workers.submit(_marker, marker, identity) for identity in identities]
                for write in writes:
                    write.result(JOIN_TIMEOUT)
            self.assertIn(json.loads(marker.read_text()), identities)
            self.assertEqual(list(marker.parent.iterdir()), [marker])

    def test_failed_marker_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "peer.json"
            with patch.object(Path, "replace", side_effect=OSError("injected rename failure")):
                with self.assertRaisesRegex(OSError, "injected rename failure"):
                    _marker(marker, {"peer_id": "first", "pid": 1})
            self.assertEqual(list(marker.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
