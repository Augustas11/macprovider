#!/usr/bin/env python3
"""Unit tests for #615 production exception enforcement scaffolding."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import production_exceptions as pe  # noqa: E402


NOW = datetime(2026, 7, 22, 12, 0, 0, tzinfo=timezone.utc)


def _minimal_entry(**overrides):
    base = {
        "id": "exc-test-sample",
        "status": "active",
        "environment": "pearl-production",
        "component": "coordinator",
        "policy_delta": "temporary relaxation for test",
        "authority_surface": "test overlay key",
        "reason": "unit test fixture",
        "owner": "ops/test",
        "issue": "https://github.com/Augustas11/macprovider/issues/615",
        "created_at": "2026-07-01T00:00:00Z",
        "expires_at": "2026-08-01T00:00:00Z",
        "scope": "unit-test only; must not widen to arbitrary providers",
        "removal_condition": "test complete",
        "rollback_command": "echo rollback",
        "post_removal_validation": "echo validate",
        "blocks_stable_promotion": True,
        "evidence": ["https://github.com/Augustas11/macprovider/issues/615"],
    }
    base.update(overrides)
    return base


def _minimal_register(entries=None):
    return {
        "$schema": "./production-exceptions.schema.json",
        "schema_version": pe.SCHEMA_VERSION,
        "updated_at": "2026-07-22T00:00:00Z",
        "updated_by": "unit-test",
        "environment": "pearl-production",
        "exceptions": entries or [_minimal_entry()],
        "open_questions": [],
    }


def _tombstones(rows=None):
    return {
        "schema_version": pe.TOMBSTONE_SCHEMA_VERSION,
        "updated_at": "2026-07-22T00:00:00Z",
        "updated_by": "unit-test",
        "environment": "pearl-production",
        "tombstones": rows or [],
    }


class ProductionExceptionsTests(unittest.TestCase):
    def test_committed_register_validates(self):
        doc = pe.load_json(pe.default_register_path(ROOT))
        tombstones = pe.load_json(pe.default_tombstone_path(ROOT))
        result = pe.validate_register(doc, now=NOW, tombstones=tombstones)
        self.assertEqual(result.errors, [], [f.format() for f in result.errors])

    def test_duplicate_ids_fail(self):
        doc = _minimal_register(
            [_minimal_entry(id="exc-dup"), _minimal_entry(id="exc-dup", expires_at="2026-09-01T00:00:00Z")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "duplicate_ids" for f in result.errors))

    def test_ownerless_fails(self):
        for owner in ("TBD", "TBD - assign ops", "unknown owner", "TODO/team"):
            doc = _minimal_register([_minimal_entry(owner=owner)])
            result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
            self.assertTrue(
                any(f.code == "ownerless" for f in result.errors),
                msg=owner,
            )

    def test_clock_boundary_expired_active_fail_closed(self):
        doc = _minimal_register(
            [_minimal_entry(status="active", expires_at="2026-07-22T12:00:00Z")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "expired_active" for f in result.errors))

        doc2 = _minimal_register(
            [_minimal_entry(status="active", expires_at="2026-07-22T12:00:01Z")]
        )
        result2 = pe.validate_register(doc2, now=NOW, tombstones=_tombstones())
        self.assertFalse(any(f.code == "expired_active" for f in result2.errors))

    def test_null_expiry_requires_reason(self):
        entry = _minimal_entry(expires_at=None)
        entry.pop("expiry_unknown_reason", None)
        doc = _minimal_register([entry])
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "expiry_unknown" for f in result.errors))

    def test_scope_mismatch_environment(self):
        doc = _minimal_register(
            [_minimal_entry(environment="staging", scope="staging only")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code in {"environment", "scope_mismatch"} for f in result.errors))

    def test_scope_widening_rejected(self):
        for scope in (
            "all providers in production without bounds",
            "every provider in pearl",
            "global production fleet",
            "*",
        ):
            doc = _minimal_register([_minimal_entry(scope=scope)])
            result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
            self.assertTrue(
                any(f.code == "scope_mismatch" for f in result.errors),
                msg=scope,
            )

    def test_deploy_default_warns_expired_and_blocking(self):
        doc = _minimal_register(
            [_minimal_entry(status="expired", expires_at="2026-07-26T23:59:59Z")]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        gated = pe.apply_gate_policy(result, "deploy", enforce=False)
        self.assertEqual(gated.errors, [])
        codes = {f.code for f in gated.warnings}
        self.assertIn("status_expired", codes)
        self.assertIn("blocks_stable_promotion", codes)

    def test_promote_fails_expired_unbounded_and_blocking_bit(self):
        doc = _minimal_register(
            [
                _minimal_entry(status="expired", expires_at="2026-07-26T23:59:59Z"),
                _minimal_entry(
                    id="exc-unbounded",
                    expires_at=None,
                    expiry_unknown_reason="no pearl evidence yet",
                ),
                _minimal_entry(
                    id="exc-bounded-blocking",
                    expires_at="2026-09-01T00:00:00Z",
                    blocks_stable_promotion=True,
                ),
            ]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        gated = pe.apply_gate_policy(result, "promote", enforce=False)
        codes = {f.code for f in gated.errors}
        self.assertIn("status_expired", codes)
        self.assertIn("unbounded_active", codes)
        self.assertIn("blocks_stable_promotion", codes)

    def test_promote_allows_non_blocking_bounded_active(self):
        doc = _minimal_register(
            [
                _minimal_entry(
                    id="exc-ok",
                    expires_at="2026-09-01T00:00:00Z",
                    blocks_stable_promotion=False,
                )
            ]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        gated = pe.apply_gate_policy(result, "promote", enforce=False)
        self.assertEqual(gated.errors, [], [f.format() for f in gated.errors])

    def test_removed_requires_tombstone(self):
        doc = _minimal_register([_minimal_entry(id="exc-removed-sample", status="removed")])
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertTrue(any(f.code == "missing_tombstone" for f in result.errors))

    def test_anti_resurrection_on_stale_sync(self):
        removed = _minimal_entry(id="exc-removed-sample", status="removed")
        current = _minimal_register([removed])
        stale = _minimal_register(
            [_minimal_entry(id="exc-removed-sample", status="active", expires_at="2026-08-01T00:00:00Z")]
        )
        tombstones = _tombstones(
            [
                {
                    "id": "exc-removed-sample",
                    "removed_at": "2026-07-20T00:00:00Z",
                    "removal_evidence": "unit-test removal evidence",
                    "authority_surface": "test overlay key",
                }
            ]
        )
        result = pe.simulate_config_sync_restore(current, stale, tombstones)
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))

    def test_sync_check_fails_on_malformed_stale(self):
        current = _minimal_register()
        stale = {"schema_version": "wrong", "environment": "nope", "exceptions": {}}
        result = pe.simulate_config_sync_restore(current, stale, _tombstones())
        self.assertTrue(any(f.code.startswith("stale_") for f in result.errors))

    def test_parent_tombstones_arg_preserved_for_sync_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            current = _minimal_register(
                [_minimal_entry(id="exc-sync-removed", status="removed")]
            )
            stale = _minimal_register(
                [_minimal_entry(id="exc-sync-removed", status="active")]
            )
            tombs = _tombstones(
                [
                    {
                        "id": "exc-sync-removed",
                        "removed_at": "2026-07-20T00:00:00Z",
                        "removal_evidence": "test",
                        "authority_surface": "test",
                    }
                ]
            )
            empty = _tombstones()
            (tmp_path / "current.json").write_text(json.dumps(current), encoding="utf-8")
            (tmp_path / "stale.json").write_text(json.dumps(stale), encoding="utf-8")
            (tmp_path / "tombs.json").write_text(json.dumps(tombs), encoding="utf-8")
            (tmp_path / "empty.json").write_text(json.dumps(empty), encoding="utf-8")
            # Parent-level --tombstones must not be clobbered by the subparser.
            rc = pe.main(
                [
                    "--tombstones",
                    str(tmp_path / "tombs.json"),
                    "sync-check",
                    "--current",
                    str(tmp_path / "current.json"),
                    "--stale",
                    str(tmp_path / "stale.json"),
                ]
            )
            self.assertEqual(rc, 1)
            rc_ok = pe.main(
                [
                    "--tombstones",
                    str(tmp_path / "empty.json"),
                    "sync-check",
                    "--current",
                    str(tmp_path / "current.json"),
                    "--stale",
                    str(tmp_path / "stale.json"),
                ]
            )
            # Empty tombstones + removed current fails missing_tombstone during validate.
            self.assertEqual(rc_ok, 1)

    def test_tombstone_deletion_vs_base_fails(self):
        tombs = _tombstones()
        base = _tombstones(
            [
                {
                    "id": "exc-old",
                    "removed_at": "2026-07-20T00:00:00Z",
                    "removal_evidence": "prior",
                    "authority_surface": "test",
                }
            ]
        )
        doc = _minimal_register()
        result = pe.validate_register(doc, now=NOW, tombstones=tombs, base_tombstones=base)
        self.assertTrue(any(f.code == "tombstone_deleted" for f in result.errors))

    def test_tombstone_blocks_non_removed_status(self):
        doc = _minimal_register([_minimal_entry(id="exc-ghost", status="active")])
        tombstones = _tombstones(
            [
                {
                    "id": "exc-ghost",
                    "removed_at": "2026-07-20T00:00:00Z",
                    "removal_evidence": "unit-test",
                    "authority_surface": "test",
                }
            ]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=tombstones)
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))

    def test_schema_parity_rejects_bad_shapes(self):
        doc = _minimal_register()
        doc["unexpected"] = True
        doc["updated_at"] = "2026-99-99T99:99:99Z"
        doc["exceptions"][0]["evidence"] = [123, ""]
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        codes = {f.code for f in result.errors}
        self.assertIn("additional_properties", codes)
        self.assertIn("updated_at", codes)
        self.assertIn("evidence", codes)

    def test_expiry_self_extension_detected(self):
        previous = _minimal_register(
            [_minimal_entry(id="exc-ext", expires_at="2026-08-01T00:00:00Z")]
        )
        nxt = copy.deepcopy(previous)
        nxt["exceptions"][0]["expires_at"] = "2026-09-01T00:00:00Z"
        result = pe.validate_register(
            nxt, now=NOW, tombstones=_tombstones(), previous_doc=previous
        )
        self.assertTrue(any(f.code == "expiry_self_extension" for f in result.errors))

    def test_health_report_redacts_secrets_and_lists_active(self):
        doc = _minimal_register(
            [
                _minimal_entry(
                    owner="ops password=hunter2",
                    policy_delta="uses Bearer SUPERSECRETTOKEN123 and still temporary",
                    reason="token: abcdefghijklmnop",
                )
            ]
        )
        report = pe.build_health_report(doc, now=NOW)
        blob = json.dumps(report)
        self.assertNotIn("SUPERSECRETTOKEN123", blob)
        self.assertNotIn("hunter2", blob)
        self.assertIn("[REDACTED]", blob)
        self.assertTrue(report["secrets_redacted"])
        self.assertEqual(report["counts"]["active"], 1)

    def test_cli_gate_report_and_sync_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            register = tmp_path / "production-exceptions.json"
            tombs = tmp_path / "removed-exception-tombstones.json"
            stale = tmp_path / "stale.json"
            register.write_text(json.dumps(_minimal_register()), encoding="utf-8")
            tombs.write_text(json.dumps(_tombstones()), encoding="utf-8")
            stale.write_text(json.dumps(_minimal_register()), encoding="utf-8")
            out = tmp_path / "report.json"
            rc = pe.main(
                [
                    "--register",
                    str(register),
                    "--tombstones",
                    str(tombs),
                    "--now",
                    "2026-07-22T12:00:00Z",
                    "report",
                    "-o",
                    str(out),
                ]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(out.is_file())
            rc_gate = pe.main(
                [
                    "--register",
                    str(register),
                    "--tombstones",
                    str(tombs),
                    "--now",
                    "2026-07-22T12:00:00Z",
                    "gate",
                    "--mode",
                    "deploy",
                    "--no-enforce",
                ]
            )
            self.assertEqual(rc_gate, 0)
            rc_sync = pe.main(
                [
                    "--tombstones",
                    str(tombs),
                    "sync-check",
                    "--current",
                    str(register),
                    "--stale",
                    str(stale),
                ]
            )
            self.assertEqual(rc_sync, 0)
            # Documented form with --tombstones after subcommand also works.
            rc_sync2 = pe.main(
                [
                    "sync-check",
                    "--current",
                    str(register),
                    "--stale",
                    str(stale),
                    "--tombstones",
                    str(tombs),
                ]
            )
            self.assertEqual(rc_sync2, 0)

    def test_previous_removed_restored_detected(self):
        previous = _minimal_register(
            [_minimal_entry(id="exc-was-removed", status="removed")]
        )
        nxt = copy.deepcopy(previous)
        nxt["exceptions"][0]["status"] = "active"
        nxt["exceptions"][0]["expires_at"] = "2026-08-01T00:00:00Z"
        tombs = _tombstones(
            [
                {
                    "id": "exc-was-removed",
                    "removed_at": "2026-07-20T00:00:00Z",
                    "removal_evidence": "unit-test",
                    "authority_surface": "test",
                }
            ]
        )
        result = pe.validate_register(
            nxt, now=NOW, tombstones=tombs, previous_doc=previous
        )
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))


if __name__ == "__main__":
    unittest.main()
