"""Reject evidence destinations that would replace canonical checker inputs."""

import importlib.util
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


CHECKER = Path(__file__).resolve().parents[1] / "tools/protocol_codec_check.py"
SPEC = importlib.util.spec_from_file_location("protocol_codec_check", CHECKER)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class CodecCheckTest(unittest.TestCase):
    def test_canonical_collision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = root / "assets"
            protocol = assets / "protocol"
            # Exercise the installed asset layout without risking its original bytes.
            shutil.copytree(str(GATE.resource("protocol")), protocol)
            original = {path.relative_to(protocol): path.read_bytes()
                        for path in protocol.rglob("*") if path.is_file()}
            exporter = root / "exporter"
            exporter.write_bytes(b"fixture exporter")
            arguments = SimpleNamespace(evidence_dir=protocol, exporter=exporter, fixtures="-")

            with patch.object(GATE, "resource", side_effect=lambda name: assets.joinpath(*name.split("/"))):
                with self.assertRaisesRegex(GATE.Rejected, "overwrite a checker input"):
                    GATE.evidence_paths(arguments)

            retained = {path.relative_to(protocol): path.read_bytes()
                        for path in protocol.rglob("*") if path.is_file()}
            self.assertEqual(retained, original)


if __name__ == "__main__":
    unittest.main()
