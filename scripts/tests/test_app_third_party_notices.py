"""Every app packaging path embeds the generated runtime licenses before signing."""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATHS = (
    ".github/workflows/release.yml",
    ".github/workflows/malibu-release.yml",
    "scripts/sign-acceptance-candidate.sh",
)


class AppThirdPartyNoticesTests(unittest.TestCase):
    def test_each_packaging_path_embeds_complete_generated_notices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            checkouts = root / "checkouts/example"
            checkouts.mkdir(parents=True)
            (checkouts / "LICENSE").write_text("Example dependency license\n")
            notices = root / "THIRD-PARTY-NOTICES.txt"
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/gather-third-party-notices.sh"),
                 str(notices), str(checkouts.parent)], capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            vendored = (ROOT / "phase3-binary/Sources/MacProviderImageGen/LICENSE").read_bytes()
            self.assertIn(vendored, notices.read_bytes())
            for index, path in enumerate(PATHS):
                with self.subTest(path=path):
                    app = root / f"app-{index}/Malibu.app"
                    resources = app / "Contents/Resources"
                    resources.mkdir(parents=True)
                    source = (ROOT / path).read_text()
                    match = re.search(
                        r"# Embed the CLI runtime notices before the app bundle is signed\.\n"
                        r"\s*test -s [^\n]+\n\s*install -m 0644 [^\n]+\n\s*cmp [^\n]+",
                        source,
                    )
                    self.assertIsNotNone(match, path)
                    result = subprocess.run(
                        ["bash", "-euc", match.group(0)],
                        env={"WORK": str(root), "payload_dir": str(root),
                             "cli_work": str(root), "APP": str(app), "app": str(app)},
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    embedded = resources / "THIRD-PARTY-NOTICES.txt"
                    self.assertEqual(embedded.read_bytes(), notices.read_bytes())
                    self.assertEqual(embedded.stat().st_mode & 0o777, 0o644)

    def test_missing_notices_abort_packaging(self):
        for path in PATHS:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "Malibu.app"
                (app / "Contents/Resources").mkdir(parents=True)
                source = (ROOT / path).read_text()
                block = re.search(
                    r"# Embed the CLI runtime notices before the app bundle is signed\.\n"
                    r"\s*test -s [^\n]+\n\s*install -m 0644 [^\n]+\n\s*cmp [^\n]+",
                    source,
                ).group(0)
                result = subprocess.run(
                    ["bash", "-euc", block],
                    env={"WORK": str(root), "payload_dir": str(root),
                         "cli_work": str(root), "APP": str(app), "app": str(app)},
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((app / "Contents/Resources/THIRD-PARTY-NOTICES.txt").exists())


if __name__ == "__main__":
    unittest.main()
