#!/usr/bin/env python3
"""Local tests for scripts/pearl_autotune_deploy_lock.py (no Pearl, no root)."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
import importlib.util

SPEC = importlib.util.spec_from_file_location(
    "pearl_autotune_deploy_lock",
    REPO / "scripts" / "pearl_autotune_deploy_lock.py",
)
assert SPEC is not None and SPEC.loader is not None
lockmod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lockmod)


class PearlAutotuneDeployLockTests(unittest.TestCase):
    def _touch(self, path: Path, mode: int) -> None:
        path.write_bytes(b"lock")
        os.chmod(path, mode)

    def test_accepts_0600_regular_file_without_root_requirement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lock"
            self._touch(path, 0o600)
            lockmod.validate_lock_file(str(path), require_root=False)

    def test_rejects_missing_file(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            lockmod.validate_lock_file("/tmp/macprovider-missing-lock-test", require_root=False)
        self.assertIn("missing lock file", str(ctx.exception))

    def test_rejects_world_readable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lock"
            self._touch(path, 0o644)
            with self.assertRaises(SystemExit) as ctx:
                lockmod.validate_lock_file(str(path), require_root=False)
            self.assertIn("mode not 0600", str(ctx.exception))

    def test_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target"
            link = Path(tmp) / "lock"
            self._touch(target, 0o600)
            os.symlink(target, link)
            with self.assertRaises(SystemExit) as ctx:
                lockmod.validate_lock_file(str(link), require_root=False)
            self.assertTrue(
                "cannot open lock file" in str(ctx.exception)
                or "not a regular file" in str(ctx.exception)
                or "nlink" in str(ctx.exception),
                msg=str(ctx.exception),
            )

    def test_rejects_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lockdir"
            path.mkdir(mode=0o700)
            with self.assertRaises(SystemExit) as ctx:
                lockmod.validate_lock_file(str(path), require_root=False)
            self.assertTrue(
                "not a regular file" in str(ctx.exception)
                or "cannot open lock file" in str(ctx.exception),
                msg=str(ctx.exception),
            )


if __name__ == "__main__":
    unittest.main()
