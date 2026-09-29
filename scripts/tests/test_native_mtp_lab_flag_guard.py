from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FORBIDDEN = "MACPROVIDER_" + "LAB_HARNESS"
FORBIDDEN_DEFINE = "D" + FORBIDDEN
SCAN_ROOTS = (
    ROOT / "scripts",
    ROOT / "phase3-binary" / "scripts",
    ROOT / ".github" / "workflows",
)
TEXT_SUFFIXES = {".bash", ".json", ".mjs", ".py", ".sh", ".yaml", ".yml"}


class NativeMTPLabFlagGuardTests(unittest.TestCase):
    def test_release_signing_ci_surfaces_do_not_pass_lab_harness_flag(self) -> None:
        offenders: list[str] = []
        this_file = Path(__file__).resolve()

        for root in SCAN_ROOTS:
            if not root.exists():
                continue
            for path in sorted(p for p in root.rglob("*") if p.is_file()):
                if path.resolve() == this_file or "__pycache__" in path.parts:
                    continue
                if path.suffix not in TEXT_SUFFIXES and path.name != "Makefile":
                    continue
                try:
                    text = path.read_text(encoding="utf-8")
                except UnicodeDecodeError:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                if FORBIDDEN in text or FORBIDDEN_DEFINE in text:
                    offenders.append(str(path.relative_to(ROOT)))

        self.assertEqual(
            [],
            offenders,
            "Lab-only native MTP harness compile flag must not be passed by release, signing, or CI scripts.",
        )


if __name__ == "__main__":
    unittest.main()
