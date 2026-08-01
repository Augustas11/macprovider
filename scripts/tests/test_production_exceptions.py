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
FUTURE_EXPIRES_AT = "2099-01-01T00:00:00Z"


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
        "expires_at": FUTURE_EXPIRES_AT,
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
            [
                _minimal_entry(
                    id="exc-removed-sample",
                    status="active",
                    expires_at=FUTURE_EXPIRES_AT,
                )
            ]
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
        result = pe.simulate_config_sync_restore(current, stale, tombstones, now=NOW)
        self.assertTrue(any(f.code == "resurrection" for f in result.errors))

    def test_health_report_allowlists_and_omits_free_prose(self):
        jwt = (
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            "eyJzdWIiOiIxMjM0NTY3ODkwIn0."
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        )
        doc = _minimal_register(
            [
                _minimal_entry(
                    owner="ops Basic dTpw",
                    policy_delta=f"Authorization: Basic dXNlcjpwYXNz and Bearer SUPERSECRETTOKEN123 {jwt}",
                    reason=f"AKIAIOSFODNN7EXAMPLE api_key=abcd1234 token={jwt}",
                    scope=f"password=hunter2 scope with {jwt}",
                    authority_surface="ghp_abcdefghijklmnopqrstuvwx",
                )
            ]
        )
        report = pe.build_health_report(doc, now=NOW)
        blob = json.dumps(report)
        for leaked in (
            "SUPERSECRETTOKEN123",
            "dXNlcjpwYXNz",
            "dTpw",
            "AKIAIOSFODNN7EXAMPLE",
            "hunter2",
            "ghp_abcdefghijklmnopqrstuvwx",
            jwt,
            "policy_delta",
            "authority_surface",
            '"owner"',
            '"reason"',
            '"scope"',
        ):
            self.assertNotIn(leaked, blob)
        self.assertEqual(report["field_set"], "allowlisted-v1")
        self.assertTrue(report["secrets_redacted"])
        self.assertEqual(set(report["exceptions"][0]), pe.REPORT_ROW_KEYS)
        self.assertEqual(report["counts"]["active"], 1)

    def test_health_report_omits_owner_including_opaque_and_auth_forms(self):
        cases = (
            "ops Basic dTpw",
            "Authorization: Basic dXNlcjpwYXNz",
            "Authorization: Bearer SUPERSECRETTOKEN123",
            "ops/opaque-credential-Q7V9m2L4x8",
            "ops password=hunter2token",
        )
        for owner in cases:
            doc = _minimal_register([_minimal_entry(owner=owner)])
            report = pe.build_health_report(doc, now=NOW)
            blob = json.dumps(report)
            self.assertNotIn('"owner"', blob, msg=owner)
            for marker in ("dTpw", "dXNlcjpwYXNz", "SUPERSECRETTOKEN123", "Q7V9m2L4x8", "hunter2token"):
                self.assertNotIn(marker, blob, msg=owner)
            self.assertTrue(report["secrets_redacted"], msg=owner)

    def test_redaction_covers_authorization_basic_and_bearer(self):
        basic = "Authorization: Basic dXNlcjpwYXNz"
        bearer = "Authorization: Bearer SUPERSECRETTOKEN123"
        short = "Basic dTpw"
        self.assertNotIn("dXNlcjpwYXNz", pe.redact_secrets(basic))
        self.assertNotIn("SUPERSECRETTOKEN123", pe.redact_secrets(bearer))
        self.assertNotIn("dTpw", pe.redact_secrets(short))
        self.assertTrue(pe.contains_residual_secret(basic))
        self.assertTrue(pe.contains_residual_secret(bearer))
        self.assertTrue(pe.contains_residual_secret(short))

    def test_cli_report_omits_basic_jwt_aws_even_when_schema_valid(self):
        jwt = (
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
            "eyJzdWIiOiIxMjM0NTY3ODkwIn0."
            "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        )
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            register = tmp_path / "production-exceptions.json"
            tombs = tmp_path / "removed-exception-tombstones.json"
            out = tmp_path / "report.json"
            doc = _minimal_register(
                [
                    _minimal_entry(
                        owner="Authorization: Basic dTpw",
                        policy_delta=f"Authorization: Basic dXNlcjpwYXNz {jwt}",
                        reason="AKIAIOSFODNN7EXAMPLE",
                        scope="api_key=supersecretvalue",
                    )
                ]
            )
            register.write_text(json.dumps(doc), encoding="utf-8")
            tombs.write_text(json.dumps(_tombstones()), encoding="utf-8")
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
            blob = out.read_text(encoding="utf-8")
            for leaked in (
                "dTpw",
                "dXNlcjpwYXNz",
                "AKIAIOSFODNN7EXAMPLE",
                "supersecretvalue",
                jwt,
                "policy_delta",
                '"owner"',
            ):
                self.assertNotIn(leaked, blob)
            parsed = json.loads(blob)
            self.assertTrue(parsed["secrets_redacted"])
            self.assertEqual(parsed["field_set"], "allowlisted-v1")

    def test_stale_register_full_structural_validation(self):
        current = _minimal_register()
        cases = [
            ({"schema_version": "wrong", "environment": "nope", "exceptions": {}}, "stale_"),
            (
                {
                    **_minimal_register(),
                    "$schema": "",
                },
                "stale_$schema",
            ),
            (
                {
                    **{k: v for k, v in _minimal_register().items() if k != "updated_by"},
                },
                "stale_updated_by",
            ),
            (
                {
                    **_minimal_register(),
                    "open_questions": "not-a-list",
                },
                "stale_open_questions",
            ),
            (
                {
                    **_minimal_register(),
                    "exceptions": [
                        {
                            "id": "exc-partial",
                            "status": "active",
                            "extra_field": True,
                        }
                    ],
                },
                "stale_",
            ),
            (
                {
                    **_minimal_register(),
                    "exceptions": [_minimal_entry()],
                    "unexpected_root": 1,
                },
                "stale_additional_properties",
            ),
        ]
        for stale, expect_prefix in cases:
            result = pe.simulate_config_sync_restore(current, stale, _tombstones(), now=NOW)
            self.assertTrue(
                any(f.code.startswith(expect_prefix) for f in result.errors),
                msg=f"expected {expect_prefix} in {[f.code for f in result.errors]} for {stale!r}",
            )

    def test_promote_history_detects_expiry_extend_after_unrelated_successor(self):
        """Mutation at main~2 + unrelated tip must still see earliest expiry."""
        baseline = _minimal_register(
            [_minimal_entry(id="exc-hist", expires_at="2026-08-01T00:00:00Z")]
        )
        extended = copy.deepcopy(baseline)
        extended["exceptions"][0]["expires_at"] = "2026-10-01T00:00:00Z"
        unrelated_tip = copy.deepcopy(extended)
        unrelated_tip["updated_by"] = "unrelated-successor"
        # History oldest-first: baseline -> extended -> tip(same as extended)
        previous = pe.earliest_expiry_previous_register(
            unrelated_tip, [baseline, extended, unrelated_tip]
        )
        self.assertEqual(previous["exceptions"][0]["expires_at"], "2026-08-01T00:00:00Z")
        result = pe.validate_register(
            unrelated_tip,
            now=NOW,
            tombstones=_tombstones(),
            previous_doc=previous,
        )
        self.assertTrue(any(f.code == "expiry_self_extension" for f in result.errors))

    def test_promote_history_detects_tombstone_delete_after_unrelated_successor(self):
        tomb_row = {
            "id": "exc-old",
            "removed_at": "2026-07-20T00:00:00Z",
            "removal_evidence": "prior",
            "authority_surface": "test",
        }
        with_tomb = _tombstones([tomb_row])
        deleted = _tombstones()
        tip = _minimal_register()
        base = pe.union_tombstone_docs([with_tomb, deleted, deleted])
        result = pe.validate_register(
            tip, now=NOW, tombstones=deleted, base_tombstones=base
        )
        self.assertTrue(any(f.code == "tombstone_deleted" for f in result.errors))
        # Reason-specific: must be tombstone_deleted, not a generic failure.
        self.assertEqual(
            {f.code for f in result.errors if f.code == "tombstone_deleted"},
            {"tombstone_deleted"},
        )

    def test_expired_reactivation_with_later_expiry_fails(self):
        expired = _minimal_register(
            [
                _minimal_entry(
                    id="exc-react",
                    status="expired",
                    expires_at="2026-07-01T00:00:00Z",
                    blocks_stable_promotion=False,
                )
            ]
        )
        reactivated = copy.deepcopy(expired)
        reactivated["exceptions"][0]["status"] = "active"
        reactivated["exceptions"][0]["expires_at"] = "2026-12-01T00:00:00Z"
        previous = pe.earliest_expiry_previous_register(
            reactivated, [expired, reactivated]
        )
        self.assertEqual(previous["exceptions"][0]["expires_at"], "2026-07-01T00:00:00Z")
        self.assertEqual(previous["exceptions"][0]["status"], "expired")
        result = pe.validate_register(
            reactivated,
            now=NOW,
            tombstones=_tombstones(),
            previous_doc=previous,
        )
        codes = {f.code for f in result.errors}
        self.assertIn("expiry_self_extension", codes)
        self.assertIn("expired_reactivation", codes)

    def test_active_expired_active_equal_expiry_reactivation_fails(self):
        """active → expired → active with the same expires_at must still fail."""
        active = _minimal_register(
            [
                _minimal_entry(
                    id="exc-cycle",
                    status="active",
                    expires_at="2026-08-01T00:00:00Z",
                    blocks_stable_promotion=False,
                )
            ]
        )
        expired = copy.deepcopy(active)
        expired["exceptions"][0]["status"] = "expired"
        reactivated = copy.deepcopy(active)
        previous = pe.earliest_expiry_previous_register(
            reactivated, [active, expired, reactivated]
        )
        self.assertEqual(previous["exceptions"][0]["status"], "expired")
        result = pe.validate_register(
            reactivated,
            now=NOW,
            tombstones=_tombstones(),
            previous_doc=previous,
        )
        self.assertTrue(any(f.code == "expired_reactivation" for f in result.errors))

    def test_sync_check_fails_on_malformed_stale(self):
        current = _minimal_register()
        stale = {"schema_version": "wrong", "environment": "nope", "exceptions": {}}
        result = pe.simulate_config_sync_restore(current, stale, _tombstones(), now=NOW)
        self.assertTrue(any(f.code.startswith("stale_") for f in result.errors))

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
            parsed = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(parsed["field_set"], "allowlisted-v1")
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
                    "--now",
                    "2026-07-22T12:00:00Z",
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
                    "--now",
                    "2026-07-22T12:00:00Z",
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
                    "--now",
                    "2026-07-22T12:00:00Z",
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
                    "--now",
                    "2026-07-22T12:00:00Z",
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

    def test_optional_progress_fields_accepted_and_typed(self):
        doc = _minimal_register(
            [
                _minimal_entry(
                    id="exc-progress",
                    partial_progress=["shipped fail-closed binding"],
                    still_blocked_for_clearance=["physical Pearl proof remains"],
                )
            ]
        )
        result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
        self.assertEqual(result.errors, [], [f.format() for f in result.errors])
        report = pe.build_health_report(doc, now=NOW)
        blob = json.dumps(report)
        self.assertNotIn("partial_progress", blob)
        self.assertNotIn("still_blocked_for_clearance", blob)
        self.assertNotIn("shipped fail-closed binding", blob)

    def test_optional_progress_fields_reject_bad_shapes(self):
        cases = (
            {"partial_progress": "not-a-list"},
            {"partial_progress": [""]},
            {"partial_progress": [123]},
            {"still_blocked_for_clearance": {"x": 1}},
            {"still_blocked_for_clearance": ["ok", ""]},
        )
        for overrides in cases:
            doc = _minimal_register([_minimal_entry(id="exc-progress-bad", **overrides)])
            result = pe.validate_register(doc, now=NOW, tombstones=_tombstones())
            self.assertTrue(
                any(
                    f.code in {"partial_progress", "still_blocked_for_clearance"}
                    for f in result.errors
                ),
                msg=overrides,
            )

    def test_committed_register_seals_608_catalog_and_609_hash_bridges(self):
        doc = pe.load_json(pe.default_register_path(ROOT))
        row = next(
            entry
            for entry in doc["exceptions"]
            if entry["id"] == "exc-catalog-compatibility-bridges"
        )
        self.assertEqual(row["status"], "removed")
        self.assertFalse(row["blocks_stable_promotion"])
        self.assertNotIn("still_blocked_for_clearance", row)
        containment = next(
            entry
            for entry in doc["exceptions"]
            if entry["id"] == "exc-tier2-hash-mismatch-containment"
        )
        self.assertEqual(containment["status"], "removed")
        self.assertFalse(containment["blocks_stable_promotion"])
        self.assertNotIn("still_blocked_for_clearance", containment)
        self.assertNotIn("partial_progress", containment)
        containment_blob = json.dumps(containment, sort_keys=True)
        self.assertNotIn(
            "Independent /opt/macprovider/tier2-catalog.json authority remains",
            containment_blob,
        )
        self.assertIn("require_hash_verified=true", containment_blob)
        self.assertIn("macprovider.snapshot-manifest.v1", containment_blob)
        self.assertIn(
            "https://github.com/Augustas11/macprovider/issues/608#issuecomment-5064599896",
            containment["evidence"],
        )
        tombstones = pe.load_json(pe.default_tombstone_path(ROOT))
        tombstone = next(
            row
            for row in tombstones["tombstones"]
            if row["id"] == "exc-catalog-compatibility-bridges"
        )
        self.assertEqual(
            tombstone["removal_evidence"],
            "https://github.com/Augustas11/macprovider/issues/608#issuecomment-5062822871",
        )
        containment_tombstone = next(
            row
            for row in tombstones["tombstones"]
            if row["id"] == "exc-tier2-hash-mismatch-containment"
        )
        self.assertEqual(
            containment_tombstone["removal_evidence"],
            "https://github.com/Augustas11/macprovider/issues/608#issuecomment-5064599896",
        )
        canary = next(
            entry
            for entry in doc["exceptions"]
            if entry["id"] == "exc-canary-disabled-enable-gate"
        )
        self.assertEqual(canary["status"], "active")
        self.assertTrue(canary["blocks_stable_promotion"])
        result = pe.validate_register(doc, now=NOW, tombstones=tombstones)
        self.assertEqual(result.errors, [], [f.format() for f in result.errors])

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
