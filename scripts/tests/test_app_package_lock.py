"""Build-free regressions for the app's reviewed dependency exception."""
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("app_lock", ROOT / "scripts/verify-app-package-lock.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class AppPackageLockTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = pathlib.Path(self.directory.name)
        for name in ("project.yml", "Package.resolved"):
            (self.app / name).write_bytes((ROOT / "phase3-binary/app" / name).read_bytes())

    def mutate_project(self, before, after):
        path = self.app / "project.yml"
        path.write_text(path.read_text().replace(before, after))

    def mutate_lock(self, edit):
        path = self.app / "Package.resolved"
        lock = json.loads(path.read_text())
        edit(lock)
        path.write_text(json.dumps(lock))

    def test_only_reviewed_package_passes(self):
        guard.verify(self.app)

    def test_second_package_is_rejected(self):
        self.mutate_project("packages:\n", "packages:\n  Other:\n    url: https://example.invalid/Other\n    exactVersion: 1.0.0\n")
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_other_version_is_rejected(self):
        self.mutate_project("exactVersion: 1.2.5", "exactVersion: 1.2.6")
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_updater_is_rejected(self):
        self.mutate_project("SwiftTerm", "Sparkle")
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_build_plugin_is_rejected(self):
        self.mutate_project("settings:\n", "plugins: [Unreviewed]\nsettings:\n")
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_transitive_pin_is_rejected(self):
        self.mutate_lock(lambda lock: lock["pins"].append(dict(lock["pins"][0])))
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_other_resolved_revision_is_rejected(self):
        self.mutate_lock(lambda lock: lock["pins"][0]["state"].update(revision="a" * 40))
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_other_resolved_version_is_rejected(self):
        self.mutate_lock(lambda lock: lock["pins"][0]["state"].update(version="1.2.6"))
        with self.assertRaises(ValueError):
            guard.verify(self.app)

    def test_every_workflow_uses_same_locked_resolver(self):
        for workflow in ("ci", "malibu-release", "acceptance-candidate", "release"):
            text = (ROOT / f".github/workflows/{workflow}.yml").read_text()
            self.assertIn('/resolve-app-packages.sh "$PWD" "$RUNNER_TEMP/MalibuSourcePackages"', text)
            self.assertIn('-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution', text)
            self.assertIn('-clonedSourcePackagesDirPath "$RUNNER_TEMP/MalibuSourcePackages"', text)
