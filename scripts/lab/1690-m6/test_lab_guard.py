#!/usr/bin/env python3
"""lab_guard.py: LAB containment under the lab root.

  python3 scripts/lab/1690-m6/test_lab_guard.py
"""
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import lab_guard  # noqa: E402


class LabGuardTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        # realpath: macOS /var and /tmp are themselves symlinks.
        self.base = os.path.realpath(tmp.name)
        self.root = os.path.join(self.base, "lab-root")
        os.mkdir(self.root)

    def test_accepts_paths_within_the_root(self):
        self.assertEqual(lab_guard.check(self.root + "/pearl-abc", self.root), self.root + "/pearl-abc")
        self.assertEqual(lab_guard.check(self.root + "/a/b/", self.root), self.root + "/a/b")
        self.assertEqual(lab_guard.check(self.root, self.root), self.root)

    def test_strict_refuses_the_root_itself(self):
        with self.assertRaises(ValueError):
            lab_guard.check(self.root, self.root, strict=True)
        self.assertEqual(lab_guard.check(self.root + "/x", self.root, strict=True), self.root + "/x")

    def test_refuses_traversal_and_outside_paths(self):
        for lab in (self.root + "/../outside", self.root + "/./x", self.root + "-sibling/x", self.base,
                    "relative/path", "", "/"):
            with self.assertRaises(ValueError, msg=lab):
                lab_guard.check(lab, self.root)

    def test_refuses_symlink_escapes(self):
        outside = os.path.join(self.base, "outside")
        os.mkdir(outside)
        os.symlink(outside, os.path.join(self.root, "link"))
        for lab in (self.root + "/link", self.root + "/link/deeper"):
            with self.assertRaises(ValueError, msg=lab):
                lab_guard.check(lab, self.root)
        linked_root = os.path.join(self.base, "root-link")
        os.symlink(self.root, linked_root)
        with self.assertRaises(ValueError):
            lab_guard.check(linked_root + "/x", linked_root)

    def test_cli_exit_status(self):
        self.assertEqual(lab_guard.main(["lab_guard.py", "/nonexistent-root/../x"]), 2)
        os.environ["LAB_ROOT"] = self.root
        self.addCleanup(os.environ.pop, "LAB_ROOT", None)
        self.assertEqual(lab_guard.main(["lab_guard.py", "--strict", self.root + "/x"]), 0)
        self.assertEqual(lab_guard.main(["lab_guard.py", "--strict", self.root]), 2)


if __name__ == "__main__":
    unittest.main()
