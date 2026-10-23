#!/usr/bin/env python3
"""Tests for scripts/catalog-pricing-preflight.py, the offline form of the
catalog-activate preflight's pricing-unacked-move lane and coordinator
rate-card parity (#2111: #2112 merged a new rate row that only activation
refused).

Fixture: the committed signed rate card and catalog as head; base is the same
card without one row R that a served name N other than R resolves to (version
re-projected), so N moves default -> R, the shape of the #2112 DeepSeek row
(for example Jundot/GLM-5.3-Flash-oQ4e-mtp onto zai-org/glm-5.3-flash).
"""

from __future__ import annotations

import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "catalog-pricing-preflight.py"
STATIC = REPO / "phase3-binary" / "dist" / "static"
ACKS = REPO / "phase3-binary" / "catalog" / "autotune" / "acknowledged-pricing-moves.json"
COORDINATOR_YAML = REPO / "phase4-coordinator" / "dist" / "coordinator.yaml"

_spec = importlib.util.spec_from_file_location("catalog_release_for_preflight_test", REPO / "scripts" / "catalog-release.py")
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)


def moving_name_and_row() -> tuple[str, str]:
    """A served name and the non-default row it resolves to under another key."""
    rows = json.loads((STATIC / "rate-card.json").read_bytes())["rows"]
    for name in sorted(cr.release_model_names(STATIC)):
        row = cr.rate_row_for(rows, name)
        if row not in (None, "default", name) and cr.rate_row_for({k: v for k, v in rows.items() if k != row}, name) == "default":
            return name, row
    raise AssertionError("no served name resolves to a row under another key")


ARTIFACT, ROW = moving_name_and_row()


def without_row(card: dict, row: str) -> dict:
    card = json.loads(json.dumps(card))
    del card["rows"][row]
    card["version"] = cr.rate_card_projection_hash(card)
    return card


def acks_without(model: str) -> bytes:
    data = json.loads(ACKS.read_text())
    data["moves"] = [m for m in data["moves"] if m["model"] != model]
    return json.dumps(data, indent=2).encode()


def yaml_without_row(row: str) -> str:
    text = COORDINATOR_YAML.read_text()
    stripped, count = re.subn(r"(?m)^    " + re.escape(row) + r":.*\n(?:      .*\n)+", "", text, count=1)
    assert count == 1, f"{row} not in {COORDINATOR_YAML}"
    return stripped


class CatalogPricingPreflightTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="pricing-preflight-test."))
        self.addCleanup(shutil.rmtree, self.tmp)
        head_card = json.loads((STATIC / "rate-card.json").read_bytes())
        self.base = self.tmp / "base"
        self.base.mkdir()
        (self.base / "rate-card.json").write_bytes(cr.canonical_bytes(without_row(head_card, ROW)))
        shutil.copy(STATIC / "autotune-candidates.json", self.base / "autotune-candidates.json")

    def head(self, *, ack: bool, rewards_row: bool) -> Path:
        head = self.tmp / f"head-{ack}-{rewards_row}"
        head.mkdir()
        shutil.copy(STATIC / "rate-card.json", head / "rate-card.json")
        shutil.copy(STATIC / "autotune-candidates.json", head / "autotune-candidates.json")
        (head / "acknowledged-pricing-moves.json").write_bytes(ACKS.read_bytes() if ack else acks_without(ARTIFACT))
        (head / "coordinator.yaml").write_text(COORDINATOR_YAML.read_text() if rewards_row else yaml_without_row(ROW))
        return head

    def run_check(self, base: Path, head: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--base-dir", str(base), "--head-dir", str(head)],
            capture_output=True, text=True, check=False)

    def test_new_row_without_ack_or_rewards_row_fails(self) -> None:
        result = self.run_check(self.base, self.head(ack=False, rewards_row=False))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn(f"pricing-unacked-move: served model {ARTIFACT!r} moves rate row 'default' -> {ROW!r}", result.stderr)
        self.assertIn("coordinator rate-card parity", result.stderr)
        self.assertIn(ROW, result.stderr.split("coordinator rate-card parity", 1)[1])

    def test_new_row_without_ack_fails(self) -> None:
        result = self.run_check(self.base, self.head(ack=False, rewards_row=True))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("pricing-unacked-move", result.stderr)
        self.assertNotIn("coordinator rate-card parity", result.stderr)

    def test_new_row_without_rewards_row_fails(self) -> None:
        result = self.run_check(self.base, self.head(ack=True, rewards_row=False))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertNotIn("pricing-unacked-move", result.stderr)
        self.assertIn("coordinator rate-card parity", result.stderr)

    def test_new_row_with_ack_and_rewards_row_passes(self) -> None:
        result = self.run_check(self.base, self.head(ack=True, rewards_row=True))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("catalog-pricing-preflight: ok", result.stdout)

    def test_no_rate_row_change_passes(self) -> None:
        head = self.head(ack=False, rewards_row=True)
        result = self.run_check(head, head)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
