import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import native_mtp_rehearsal_release as rehearsal
from scripts import read_swiftpm_pins


class RuntimeRevisionTests(unittest.TestCase):
    def test_runtime_revision_is_the_resolved_reviewed_fork_pin(self):
        self.assertEqual(rehearsal.runtime_revision(), read_swiftpm_pins.SPEC048_MLX_SWIFT_LM_REVISION)
        entry = rehearsal.tuple_input()["entry"]
        self.assertEqual(entry["runtime_revision"], read_swiftpm_pins.SPEC048_MLX_SWIFT_LM_REVISION)
        self.assertEqual(entry["ordinary_baseline"]["runtime_revision"], entry["runtime_revision"])

    def test_unreviewed_or_missing_pin_fails_closed(self):
        resolved = json.loads(rehearsal.PACKAGE_RESOLVED.read_text())
        for pin in resolved["pins"]:
            if pin["identity"] == "mlx-swift-lm":
                pin["state"]["revision"] = "0" * 40
        with tempfile.TemporaryDirectory() as directory:
            stale = Path(directory) / "Package.resolved"
            stale.write_text(json.dumps(resolved))
            missing = Path(directory) / "absent.resolved"
            for path in (stale, missing):
                with mock.patch.object(rehearsal, "PACKAGE_RESOLVED", path):
                    with self.assertRaises(SystemExit):
                        rehearsal.runtime_revision()


if __name__ == "__main__":
    unittest.main()
