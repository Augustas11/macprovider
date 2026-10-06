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

    def _outside_and_lab(self):
        outside = os.path.join(self.base, "outside")
        os.mkdir(outside)
        lab = os.path.join(self.root, "lab")
        os.mkdir(lab)
        return outside, lab

    def test_refuses_symlinked_descendant_write_dir(self):
        outside, lab = self._outside_and_lab()
        os.symlink(outside, os.path.join(lab, "keys"))
        # LAB itself is canonical and contained; only the descendant escapes.
        self.assertEqual(lab_guard.check(lab, self.root), lab)
        for rels in (("keys",), ("keys/sub",), ("run", "keys")):
            with self.assertRaises(ValueError, msg=rels):
                lab_guard.check_tree(lab, rels)
        with self.assertRaises(OSError):
            lab_guard.write_file(lab, "keys/secrets.json", "{}", 0o600)
        self.assertEqual(os.listdir(outside), [])

    def test_refuses_symlinked_entry_inside_write_dir(self):
        outside, lab = self._outside_and_lab()
        os.mkdir(os.path.join(lab, "run"))
        target = os.path.join(outside, "coordinator.yaml")
        os.symlink(target, os.path.join(lab, "run", "coordinator.yaml"))
        with self.assertRaises(ValueError):
            lab_guard.check_tree(lab, ("run",))
        with self.assertRaises(OSError):
            lab_guard.write_file(lab, "run/coordinator.yaml", "{}")
        self.assertFalse(os.path.lexists(target))
        self.assertEqual(os.listdir(outside), [])

    def test_hard_linked_target_is_replaced_not_written_through(self):
        outside, lab = self._outside_and_lab()
        os.mkdir(os.path.join(lab, "keys"))
        victim = os.path.join(outside, "victim")
        with open(victim, "w") as f:
            f.write("outside")
        os.link(victim, os.path.join(lab, "keys", "secrets.json"))
        lab_guard.write_file(lab, "keys/secrets.json", "lab", 0o600)
        self.assertEqual(open(victim).read(), "outside")
        self.assertEqual(open(os.path.join(lab, "keys", "secrets.json")).read(), "lab")
        self.assertEqual(os.stat(victim).st_nlink, 1)
        self.assertEqual([n for n in os.listdir(os.path.join(lab, "keys")) if n.startswith(".")], [])

    def test_write_file_creates_inside_lab_only(self):
        _, lab = self._outside_and_lab()
        lab_guard.check_tree(lab, ("keys", "run"))  # absent dirs are fine
        path = lab_guard.write_file(lab, "keys/secrets.json", "{}", 0o600)
        self.assertEqual(path, os.path.join(lab, "keys", "secrets.json"))
        self.assertEqual(open(path).read(), "{}")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        lab_guard.write_file(lab, "keys/secrets.json", "x", 0o600)  # truncates
        self.assertEqual(open(path).read(), "x")
        for rel in ("../x", "/abs", "a/./b", ""):
            with self.assertRaises(ValueError, msg=rel):
                lab_guard.write_file(lab, rel, "")

    def test_cli_refuses_symlinked_subdir(self):
        outside, lab = self._outside_and_lab()
        os.symlink(outside, os.path.join(lab, "keys"))
        os.environ["LAB_ROOT"] = self.root
        self.addCleanup(os.environ.pop, "LAB_ROOT", None)
        self.assertEqual(lab_guard.main(["lab_guard.py", lab, "bin", "logs"]), 0)
        self.assertEqual(lab_guard.main(["lab_guard.py", lab, "bin", "keys"]), 2)
        self.assertEqual(lab_guard.main(["lab_guard.py", "--strict", lab, "keys"]), 2)

    def test_cli_exit_status(self):
        self.assertEqual(lab_guard.main(["lab_guard.py", "/nonexistent-root/../x"]), 2)
        os.environ["LAB_ROOT"] = self.root
        self.addCleanup(os.environ.pop, "LAB_ROOT", None)
        self.assertEqual(lab_guard.main(["lab_guard.py", "--strict", self.root + "/x"]), 0)
        self.assertEqual(lab_guard.main(["lab_guard.py", "--strict", self.root]), 2)


if __name__ == "__main__":
    unittest.main()
