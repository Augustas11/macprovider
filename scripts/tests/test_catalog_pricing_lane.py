#!/usr/bin/env python3
"""Hermetic tests for the #1693 pricing lane in `catalog-release.py`: the L1
rate_card splice, block extraction, the effective-price diff, the content-gate
pricing scope and commit-block binding, and the provenance-comment rule on the
tracked coordinator config.
"""

from __future__ import annotations

import copy
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from unittest import mock

from scripts.tests.test_catalog_compare_live import CANONICAL, LEDGER, REPO, SCRIPT, STATIC, STATIC_FILES, assemble, cr, edit_json
from scripts.tests.test_catalog_content_gate import GENERATED_AT, NO_EXCLUSIONS, NOW, correct_hash, git

COORDINATOR_YAML = REPO / "phase4-coordinator" / "dist" / "coordinator.yaml"
TRACKED = COORDINATOR_YAML.read_bytes()
EMPTY_ACKS = json.dumps({"schema_version": cr.ACKNOWLEDGED_PRICING_MOVES_SCHEMA, "moves": []}).encode()
SETTLEMENT_TAIL = b"\n# SPEC-015 / SPEC-022 settlement policy.\n"


def acks(*moves: tuple[str, str, str]) -> bytes:
    return json.dumps({
        "schema_version": cr.ACKNOWLEDGED_PRICING_MOVES_SCHEMA,
        "moves": [{"model": m, "from_row": f, "to_row": t} for m, f, t in moves],
    }).encode()


def run_cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, check=False)


def tracked_block() -> bytes:
    return cr.extract_coordinator_rate_card_block(TRACKED, "tracked")


def reprice_block(block: bytes, row: str, field: str, value: int) -> bytes:
    lines = block.decode().split("\n")
    head = lines.index(f"    {row}:") if f"    {row}:" in lines else next(
        i for i, line in enumerate(lines) if line.startswith(f"    {row}:")
    )
    for i in range(head + 1, len(lines)):
        if lines[i].lstrip().startswith(f"{field}:"):
            lines[i] = re.sub(r"\d+", str(value), lines[i], count=1)
            return "\n".join(lines).encode()
    raise AssertionError(f"{row}.{field} not found")


MINI = (
    b"top: 1\n"
    b"rewards:\n"
    b"  global_multiplier: 1.0\n"
    b"  provider_share: 0.90\n"
    b"  rate_card:\n"
    b"    # in-child provenance comment\n"
    b"    default:\n"
    b"      prompt_credits_per_mtok: 500000\n"
    b"      prompt_cache_hit_credits_per_mtok: 125000\n"
    b"\n"
    b"      completion_credits_per_mtok: 1000000 # $1/M\n"
    b"\n"
    b"  after: 2\n"
    b"tail: 3\n"
)
MINI_BLOCK = (
    b"  rate_card:\n"
    b"    default:\n"
    b"      prompt_credits_per_mtok: 1\n"
    b"      prompt_cache_hit_credits_per_mtok: 1\n"
    b"      completion_credits_per_mtok: 2\n"
)


class SpliceBoundaryTests(unittest.TestCase):
    def test_tracked_boundary_keeps_settlement_comments_outside(self) -> None:
        start, end = cr.coordinator_rate_card_block_span(TRACKED, "tracked")
        self.assertTrue(TRACKED[start:].startswith(b"  rate_card:\n    # Wave 1 subset"))
        self.assertTrue(TRACKED[:end].endswith(b"completion_credits_per_mtok: 688000    # $0.688/M\n"))
        self.assertTrue(TRACKED[end:].startswith(SETTLEMENT_TAIL))

    def test_identity_splice_is_byte_identical(self) -> None:
        self.assertEqual(cr.splice_coordinator_rate_card(TRACKED, tracked_block()), TRACKED)

    def test_changed_block_keeps_prefix_and_suffix(self) -> None:
        start, end = cr.coordinator_rate_card_block_span(TRACKED, "tracked")
        block = reprice_block(tracked_block(), "qwen3-8b", "completion_credits_per_mtok", 27001)
        out = cr.splice_coordinator_rate_card(TRACKED, block)
        self.assertEqual(out[:start], TRACKED[:start])
        self.assertEqual(out[start + len(block):], TRACKED[end:])
        _, _, rows = cr.parse_coordinator_rewards(out.decode())
        self.assertEqual(rows["qwen3-8b"]["completion_credits_per_mtok"], 27001)

    def test_deeper_comments_and_inner_blanks_belong_to_block_trailing_blank_does_not(self) -> None:
        start, end = cr.coordinator_rate_card_block_span(MINI, "mini")
        block = MINI[start:end]
        self.assertIn(b"# in-child provenance comment", block)
        self.assertTrue(block.endswith(b"# $1/M\n"))
        self.assertTrue(MINI[end:].startswith(b"\n  after: 2\n"))
        out = cr.splice_coordinator_rate_card(MINI, MINI_BLOCK)
        self.assertEqual(out, MINI[:start] + MINI_BLOCK + MINI[end:])

    def test_boundary_comment_at_child_indent_ends_block(self) -> None:
        text = MINI.replace(b"\n  after: 2\n", b"\n  # rewards-level note\n  after: 2\n")
        _, end = cr.coordinator_rate_card_block_span(text, "t")
        self.assertTrue(text[end:].startswith(b"\n  # rewards-level note\n"))

    def test_block_at_eof_without_newline(self) -> None:
        text = b"rewards:\n  global_multiplier: 1.0\n  provider_share: 0.9\n  rate_card:\n    default:\n      prompt_credits_per_mtok: 5\n      prompt_cache_hit_credits_per_mtok: 5\n      completion_credits_per_mtok: 5"
        start, end = cr.coordinator_rate_card_block_span(text, "t")
        self.assertEqual(end, len(text))
        self.assertEqual(cr.splice_coordinator_rate_card(text, MINI_BLOCK), text[:start] + MINI_BLOCK)

    def test_refusal_matrix(self) -> None:
        cases = {
            "tab": MINI.replace(b"top: 1", b"top:\t1"),
            "crlf": MINI.replace(b"\n", b"\r\n"),
            "bom": b"\xef\xbb\xbf" + MINI,
            "control char": MINI.replace(b"top: 1", b"top: \x0b1"),
            "line separator": MINI.replace(b"top: 1", "top: \u20281".encode()),
            "not utf-8": MINI.replace(b"top: 1", b"top: \xff"),
            "multi-doc": MINI + b"---\nother: 1\n",
            "doc end": MINI + b"...\n",
            "directive": b"%YAML 1.2\n" + MINI,
            "anchor": MINI.replace(b"  after: 2", b"  after: &a 2"),
            "alias": MINI.replace(b"  after: 2", b"  after: *a"),
            "tag": MINI.replace(b"  after: 2", b"  after: !!int 2"),
            "flow": MINI.replace(b"  after: 2", b"  after: {x: 1}"),
            "flow seq": MINI.replace(b"  after: 2", b"  after: [1]"),
            "block scalar": MINI.replace(b"  after: 2", b"  after: |\n    x"),
            "two rewards": MINI + b"rewards:\n  x: 1\n",
            "inline rewards": MINI.replace(b"rewards:\n", b"rewards: \n  ").replace(b"rewards: \n  ", b"rewards: {}\n", 1),
            "no rewards": MINI.replace(b"rewards:", b"other:"),
            "two rate_card": MINI.replace(b"  after: 2", b"  rate_card:\n    x: 1"),
            "no rate_card": MINI.replace(b"  rate_card:", b"  rate_kard:"),
            "inline rate_card": MINI.replace(b"  rate_card:\n", b"  rate_card: 1\n  x:\n"),
            "duplicate rewards key": MINI.replace(b"  after: 2", b"  provider_share: 0.5"),
            "duplicate top key": MINI + b"top: 4\n",
            "duplicate row": MINI.replace(b"\n  after: 2", b"    default:\n      prompt_credits_per_mtok: 1\n  after: 2"),
            "non-credit field": MINI.replace(b"      prompt_credits_per_mtok: 500000", b"      provider_share_bps: 9000"),
            "inconsistent indent": MINI.replace(b"  after: 2", b" after: 2"),
            "split by column-0 comment": MINI.replace(
                b"      completion_credits_per_mtok: 1000000 # $1/M\n",
                b"# split\n    extra:\n      prompt_credits_per_mtok: 1\n",
            ),
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.assertNotEqual(text, MINI)
                with self.assertRaises(cr.CatalogError):
                    cr.splice_coordinator_rate_card(text, MINI_BLOCK)

    def test_block_refusals(self) -> None:
        cases = {
            "no trailing newline": MINI_BLOCK[:-1],
            "trailing blank line": MINI_BLOCK + b"\n",
            "wrong indent": MINI_BLOCK.replace(b"  rate_card:", b"rate_card:"),
            "extra sibling": MINI_BLOCK + b"  sibling: 1\n",
            "missing default": MINI_BLOCK.replace(b"    default:", b"    qwen3-8b:"),
            "missing field": MINI_BLOCK.replace(b"      completion_credits_per_mtok: 2\n", b""),
            "globals smuggled": MINI_BLOCK + b"  provider_share: 0.5\n",
            "tab": MINI_BLOCK.replace(b"      prompt", b"\t    prompt", 1),
            "anchor": MINI_BLOCK.replace(b"    default:", b"    default: &d"),
        }
        for name, block in cases.items():
            with self.subTest(name):
                with self.assertRaises(cr.CatalogError):
                    cr.splice_coordinator_rate_card(MINI, block)

    def test_in_child_comments_keep_parity_and_prefilter(self) -> None:
        rate_card = cr.validate_rate_card((STATIC / "rate-card.json").read_bytes())
        cr.check_rate_card_parity(rate_card, TRACKED.decode())
        commented = TRACKED.replace(
            b"    qwen3-8b:", b"    # moved provenance: qwen3-8b 13500\n      # deeper note\n    qwen3-8b:"
        )
        cr.check_rate_card_parity(rate_card, commented.decode())
        self.assertIn(b"# deeper note", cr.extract_coordinator_rate_card_block(commented, "c"))


class SpliceCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def test_splice_and_extract_cli(self) -> None:
        live = self.tmp / "live.yaml"
        live.write_bytes(TRACKED)
        block_path = self.tmp / "block.yaml"
        proc = run_cli("extract-coordinator-rate-card-block", "--config", str(live), "--output", str(block_path))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        extracted = json.loads(proc.stdout)
        self.assertEqual(extracted["block_sha256"], cr.sha256(block_path.read_bytes()))
        self.assertEqual(extracted["config_sha256"], cr.sha256(TRACKED))
        self.assertEqual(block_path.stat().st_mode & 0o777, 0o600)

        new_block = self.tmp / "new-block.yaml"
        new_block.write_bytes(reprice_block(block_path.read_bytes(), "qwen3-8b", "completion_credits_per_mtok", 27001))
        out = self.tmp / "out.yaml"
        proc = run_cli("splice-coordinator-rate-card", "--live-config", str(live), "--block", str(new_block), "--output", str(out))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        summary = json.loads(proc.stdout)
        self.assertEqual(sorted(summary), ["block_sha256", "live_config_sha256", "output_sha256", "prefix_bytes", "suffix_bytes"])
        self.assertEqual(summary["output_sha256"], cr.sha256(out.read_bytes()))
        self.assertEqual(summary["prefix_bytes"] + len(new_block.read_bytes()) + summary["suffix_bytes"], len(out.read_bytes()))

        # An existing output is never replaced; a refused splice writes nothing.
        proc = run_cli("splice-coordinator-rate-card", "--live-config", str(live), "--block", str(new_block), "--output", str(out))
        self.assertEqual(proc.returncode, 1)
        bad = self.tmp / "bad.yaml"
        bad.write_bytes(TRACKED.replace(b"\n", b"\r\n"))
        refused = self.tmp / "refused.yaml"
        proc = run_cli("splice-coordinator-rate-card", "--live-config", str(bad), "--block", str(new_block), "--output", str(refused))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("refused", proc.stderr)
        self.assertFalse(refused.exists())


class ProvenanceCommentTests(unittest.TestCase):
    """Price provenance lives only inside the rate_card child of the tracked config."""

    def test_no_price_comment_outside_the_rate_card_block(self) -> None:
        start, end = cr.coordinator_rate_card_block_span(TRACKED, "tracked")
        _, _, rows = cr.parse_coordinator_rewards(TRACKED.decode())
        keys = sorted(key for key in rows if key != "default")
        values = sorted({str(v) for row in rows.values() for v in row.values()})
        token = r"(?<![A-Za-z0-9._/-]){}(?![A-Za-z0-9._/-])"
        patterns = [re.compile(token.format(re.escape(item))) for item in keys + values]
        patterns += [re.compile(r"credits_per_mtok"), re.compile(r"\$\d[\d.]*/M")]
        outside = (TRACKED[:start] + TRACKED[end:]).decode()
        offenders = []
        for number, line in enumerate(outside.split("\n"), 1):
            match = re.search(r"(?:(?<=\s)|^)#.*$", line)
            if match and any(p.search(match.group()) for p in patterns):
                offenders.append((number, line))
        self.assertEqual(offenders, [])


class EffectiveDiffTests(unittest.TestCase):
    def setUp(self) -> None:
        self.live = cr.pricing_credit_rows(json.loads((STATIC / "rate-card.json").read_bytes())["rows"])

    def diff(self, candidate: dict, names=(), pinned=(), ack=EMPTY_ACKS, new=()) -> tuple[dict, dict]:
        return cr.pricing_effective_diff(self.live, candidate, set(names), set(pinned), ack, set(new))

    def test_removal_moves_served_model_to_default_unless_acknowledged(self) -> None:
        candidate = copy.deepcopy(self.live)
        del candidate["gemma-4-26b-a4b-it"]
        served = "mlx-community/gemma-4-26b-a4b-it-4bit"
        diff, _ = self.diff(candidate, names={served})
        self.assertEqual(diff["unacknowledged_moves"], ["gemma-4-26b-a4b-it", served])
        entry = next(e for e in diff["models"] if e["model"] == served)
        self.assertEqual((entry["old_row"], entry["new_row"], entry["move"]), ("gemma-4-26b-a4b-it", "default", True))
        self.assertEqual(diff["rows"]["removed"], [{"row": "gemma-4-26b-a4b-it", "old": self.live["gemma-4-26b-a4b-it"]}])
        ack = acks(("gemma-4-26b-a4b-it", "gemma-4-26b-a4b-it", "default"), (served, "gemma-4-26b-a4b-it", "default"))
        self.assertEqual(self.diff(candidate, names={served}, ack=ack)[0]["unacknowledged_moves"], [])
        # An acknowledgement binds the exact destination row.
        wrong = acks(("gemma-4-26b-a4b-it", "gemma-4-26b-a4b-it", "default"), (served, "gemma-4-26b-a4b-it", "qwen3-8b"))
        self.assertEqual(self.diff(candidate, names={served}, ack=wrong)[0]["unacknowledged_moves"], [served])

    def test_shadowing_addition_is_refused_unless_acknowledged(self) -> None:
        candidate = copy.deepcopy(self.live)
        candidate["some-new-model"] = dict(self.live["qwen3-8b"])
        served = "mlx-community/Some-New-Model-4bit"
        diff, _ = self.diff(candidate, pinned={served})
        # SPEC-023-R018 rule 2 (v0.16.1): the added row's own key moving off
        # `default` is the addition itself (listed, no ack); a normalized name
        # it captures is a move that needs one.
        self.assertEqual(diff["unacknowledged_moves"], [served])
        own = next(e for e in diff["models"] if e["model"] == "some-new-model")
        self.assertEqual((own["old_row"], own["new_row"], own["move"]), ("default", "some-new-model", True))
        entry = next(e for e in diff["models"] if e["model"] == served)
        self.assertEqual((entry["old_row"], entry["new_row"]), ("default", "some-new-model"))
        ack = acks((served, "default", "some-new-model"))
        self.assertEqual(self.diff(candidate, pinned={served}, ack=ack)[0]["unacknowledged_moves"], [])
        # An exact-key row added under a name that used to normalize elsewhere captures it.
        candidate = copy.deepcopy(self.live)
        candidate["llama-3.1-8b-instruct"] = dict(self.live["default"])
        diff, _ = self.diff(candidate, pinned={"llama-3.1-8b-instruct"})
        entry = next(e for e in diff["models"] if e["model"] == "llama-3.1-8b-instruct")
        self.assertEqual(entry["old_row"], "meta-llama/llama-3.1-8b-instruct")
        self.assertIn("llama-3.1-8b-instruct", diff["unacknowledged_moves"])

    def test_credit_change_is_listed_but_needs_no_ack(self) -> None:
        candidate = copy.deepcopy(self.live)
        candidate["qwen3-8b"]["completion_rate_per_mtok"] += 1
        diff, _ = self.diff(candidate, names={"mlx-community/Qwen3-8B-4bit"})
        self.assertEqual(diff["unacknowledged_moves"], [])
        self.assertEqual({e["model"] for e in diff["models"]}, {"qwen3-8b", "mlx-community/Qwen3-8B-4bit"})
        self.assertTrue(all(not e["move"] for e in diff["models"]))

    def test_retained_window_release_names_are_covered(self) -> None:
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        window = assemble(tmp / "window")
        candidate = copy.deepcopy(self.live)
        del candidate["meta-llama/llama-3.2-3b-instruct"]
        served = "mlx-community/Llama-3.2-3B-Instruct-4bit"
        without, _ = self.diff(candidate)
        self.assertNotIn(served, without["unacknowledged_moves"])
        with_window, _ = self.diff(candidate, names=cr.release_model_names(window))
        self.assertIn(served, with_window["unacknowledged_moves"])
        self.assertNotEqual(without["names_sha256"], with_window["names_sha256"])

    def test_control_characters_are_escaped_and_unresolved(self) -> None:
        hostile = "evil\x1b[31m\x9b\x7f\\x00"
        diff, _ = self.diff(copy.deepcopy(self.live), pinned={hostile, "Ünicode"})
        self.assertEqual(diff["unresolved_names"], ["evil\\x1b[31m\\x9b\\x7f\\x5cx00", "Ünicode"])
        data = cr.pricing_canonical_bytes(diff)
        self.assertTrue(all(b < 0x80 for b in data))
        self.assertNotIn(b"\\u001b", data)
        self.assertEqual(cr.escape_model_name("a\\x07"), "a\\x5cx07")
        self.assertNotEqual(cr.escape_model_name("a\x07"), cr.escape_model_name("a\\x07"))

    def test_unicode_format_and_bidi_controls_are_escaped(self) -> None:
        # SEC-L1: bidi embeddings/overrides/isolates/marks, other Cf, Zl/Zp and
        # astral Cf become ASCII escapes; a backslash stays escaped, so the
        # encoding is injective and the terminal never sees a raw one.
        controls = ["\u200e", "\u200f", "\u202a", "\u202b", "\u202c", "\u202d", "\u202e",
                    "\u2066", "\u2067", "\u2068", "\u2069", "\u061c", "\u200b", "\u00ad",
                    "\ufeff", "\u2028", "\u2029", "\U000e0001"]
        for ch in controls:
            with self.subTest(code=hex(ord(ch))):
                escaped = cr.escape_model_name("m" + ch + "x")
                width = 8 if ord(ch) > 0xFFFF else 4
                prefix = "\\U" if ord(ch) > 0xFFFF else "\\u"
                self.assertEqual(escaped, "m" + prefix + format(ord(ch), f"0{width}x") + "x")
                self.assertTrue(escaped.isascii())
        self.assertEqual(cr.escape_model_name("\u65e5\u672c-model"), "\u65e5\u672c-model")
        self.assertNotEqual(cr.escape_model_name("a\u202eb"), cr.escape_model_name("a\\u202eb"))
        self.assertEqual(cr.escape_model_name("a\\u202eb"), "a\\x5cu202eb")
        hostile = "gpt\u202e4-mini\u2066"
        diff, _ = self.diff(copy.deepcopy(self.live), pinned={hostile})
        self.assertEqual(diff["unresolved_names"], ["gpt\\u202e4-mini\\u2066"])
        obj = cr.pricing_acknowledged_object(diff, go_resolutions(hostile))
        self.assertEqual(obj["model_resolutions"][0]["name"], "gpt\\u202e4-mini\\u2066")
        self.assertTrue(all(b < 0x80 for b in cr.pricing_canonical_bytes(obj)))

    def test_diff_is_deterministic(self) -> None:
        candidate = copy.deepcopy(self.live)
        candidate["qwen3-8b"]["prompt_rate_per_mtok"] += 1
        names = ["b-model", "a-model", "mlx-community/Qwen3-8B-4bit"]
        one = cr.pricing_canonical_bytes(self.diff(candidate, pinned=names)[0])
        two = cr.pricing_canonical_bytes(self.diff(dict(reversed(list(candidate.items()))), pinned=list(reversed(names)))[0])
        self.assertEqual(one, two)

    def test_new_names_are_checked_but_kept_out_of_the_digest(self) -> None:
        candidate = copy.deepcopy(self.live)
        del candidate["qwen3-32b"]
        ack = acks(("qwen3-32b", "qwen3-32b", "default"))
        pinned_diff, pinned_new = self.diff(candidate, pinned={"a-model"}, ack=ack)
        self.assertEqual(pinned_diff["unacknowledged_moves"], [])
        # A new name that moves unacknowledged refuses; the pinned diff digest is unchanged.
        diff, new = self.diff(candidate, pinned={"a-model"}, ack=ack, new={"Qwen3-32B", "a-model", "other"})
        self.assertEqual(cr.pricing_canonical_bytes(diff), cr.pricing_canonical_bytes(pinned_diff))
        self.assertEqual(new["unacknowledged_moves"], ["Qwen3-32B"])
        self.assertEqual({e["model"] for e in new["models"]}, {"Qwen3-32B"})
        # A pinned name leaving the window never invalidates: new names are optional.
        self.assertEqual(pinned_new["models"], [])

    def test_ack_file_schema(self) -> None:
        committed = (CANONICAL / "acknowledged-pricing-moves.json").read_bytes()
        self.assertEqual(cr.load_pricing_move_acks(committed, "committed"), set())
        for bad in (
            b"[]",
            json.dumps({"schema_version": "x", "moves": []}).encode(),
            json.dumps({"schema_version": cr.ACKNOWLEDGED_PRICING_MOVES_SCHEMA}).encode(),
            json.dumps({"schema_version": cr.ACKNOWLEDGED_PRICING_MOVES_SCHEMA, "moves": [{"model": "a"}]}).encode(),
            acks(("a", "default", "default")),
            acks(("a", "b", "c"), ("a", "b", "c")),
            json.dumps({"schema_version": cr.ACKNOWLEDGED_PRICING_MOVES_SCHEMA, "moves": [], "extra": 1}).encode(),
        ):
            with self.subTest(bad):
                with self.assertRaises(cr.CatalogError):
                    cr.load_pricing_move_acks(bad, "t")

    def test_rate_for_port(self) -> None:
        rows = {"default": {}, "qwen3-8b": {}, "openai/gpt-oss-20b": {}}
        self.assertEqual(cr.rate_row_for(rows, "qwen3-8b"), "qwen3-8b")
        self.assertEqual(cr.rate_row_for(rows, "mlx-community/Qwen3-8B-4bit"), "qwen3-8b")
        self.assertEqual(cr.rate_row_for(rows, "mlx-community/gpt-oss-20b-MXFP4-Q8"), "openai/gpt-oss-20b")
        self.assertEqual(cr.rate_row_for(rows, "unknown"), "default")
        self.assertIsNone(cr.rate_row_for({"x": {}}, "y"))


class EffectiveDiffCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.release = assemble(self.tmp / "release")
        self.window = assemble(self.tmp / "window")

        def drop(o: dict) -> None:
            del o["rows"]["qwen3-8b"]
            o["version"] = cr.rate_card_projection_hash(o)

        edit_json(self.release / "rate-card.json", drop)
        self.live_yaml = self.tmp / "coordinator.yaml"
        self.live_yaml.write_bytes(TRACKED)
        self.pinned = self.tmp / "pinned.json"
        self.pinned.write_text(json.dumps(["qwen3-8b-free", "\x1b[2J"]))
        self.ack = self.tmp / "ack.json"

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def run_diff(self, output: str, *extra: str) -> subprocess.CompletedProcess:
        return run_cli(
            "pricing-effective-diff", "--live-config", str(self.live_yaml),
            "--candidate-rate-card", str(self.release / "rate-card.json"),
            "--release", str(self.release), "--release", str(self.window),
            "--pinned-names", str(self.pinned), "--acknowledged-moves", str(self.ack),
            "--output", str(self.tmp / output), *extra,
        )

    def test_unacknowledged_then_acknowledged(self) -> None:
        self.ack.write_bytes(EMPTY_ACKS)
        proc = self.run_diff("diff1.json")
        self.assertEqual(proc.returncode, 3, proc.stderr)
        verdict = json.loads(proc.stdout)
        self.assertFalse(verdict["ok"])
        self.assertEqual(verdict["unacknowledged_moves"], ["mlx-community/Qwen3-8B-4bit", "qwen3-8b", "qwen3-8b-free"])
        self.assertEqual(verdict["unresolved_names"], ["\\x1b[2J"])
        data = (self.tmp / "diff1.json").read_bytes()
        self.assertEqual(verdict["pricing_diff_sha256"], cr.sha256(data))
        self.assertEqual(json.loads(data)["schema_version"], cr.PRICING_EFFECTIVE_DIFF_SCHEMA)

        self.ack.write_bytes(acks(*((m, "qwen3-8b", "default") for m in verdict["unacknowledged_moves"])))
        proc = self.run_diff("diff2.json")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        verdict = json.loads(proc.stdout)
        self.assertTrue(verdict["ok"])
        new = self.tmp / "new.json"
        new.write_text(json.dumps(["Qwen3-8B"]))
        proc = self.run_diff("diff3.json", "--new-names", str(new))
        self.assertEqual(proc.returncode, 3, proc.stderr)
        again = json.loads(proc.stdout)
        self.assertEqual(again["pricing_diff_sha256"], verdict["pricing_diff_sha256"])
        self.assertEqual(again["new_names"]["unacknowledged_moves"], ["Qwen3-8B"])

    def test_malformed_inputs_exit_1(self) -> None:
        self.ack.write_bytes(EMPTY_ACKS)
        self.pinned.write_text(json.dumps({"names": []}))
        self.assertEqual(self.run_diff("d.json").returncode, 1)
        self.pinned.write_text("[]")
        self.ack.write_text("{}")
        self.assertEqual(self.run_diff("e.json").returncode, 1)
        self.assertFalse((self.tmp / "e.json").exists())


class GatePricingScopeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.release = assemble(self.tmp / "release")
        self.live = assemble(self.tmp / "live")
        correct_hash(self.release)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def gate(self, **kwargs) -> dict:
        kwargs.setdefault("now", NOW)
        kwargs.setdefault("exclusions_data", NO_EXCLUSIONS)
        kwargs.setdefault("ack_data", EMPTY_ACKS)
        with mock.patch.object(cr, "verify_directory", lambda _directory: None):
            return cr.content_gate(self.release, self.live, LEDGER, **kwargs)

    def rate_card(self, mutate) -> None:
        def apply(o: dict) -> None:
            mutate(o)
            o["version"] = cr.rate_card_projection_hash(o)

        edit_json(self.release / "rate-card.json", apply)

    def assertLane(self, result: dict, lane: str) -> None:
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["lane"], lane, result)

    def test_credit_change_is_eligible_with_pricing_object(self) -> None:
        self.rate_card(lambda o: o["rows"]["qwen3-8b"].update(completion_rate_per_mtok=27001))
        result = self.gate()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["lane"], "catalog-content")
        self.assertEqual(result["pricing"]["changed"][0]["row"], "qwen3-8b")
        self.assertEqual(result["pricing"]["added"], [])
        self.assertIsNone(result["commit_block_sha256"])

    def test_non_pricing_release_has_empty_pricing_object(self) -> None:
        self.assertEqual(self.gate()["pricing"], {"changed": [], "added": [], "removed": []})

    def test_absent_ack_file_blocks_only_pricing_releases(self) -> None:
        # An older bundle without the acknowledgement file keeps shipping non-pricing content.
        with mock.patch.object(cr, "ACKNOWLEDGED_PRICING_MOVES_PATH", self.tmp / "absent.json"):
            result = self.gate(ack_data=None)
            self.assertTrue(result["ok"], result)
            self.assertIsNone(result["acknowledged_moves_sha256"])
            self.rate_card(lambda o: o["rows"]["qwen3-8b"].update(completion_rate_per_mtok=27001))
            self.assertLane(self.gate(ack_data=None), "pricing-unacked-move")

    def test_default_removal_is_invalid_release(self) -> None:
        edit_json(self.release / "rate-card.json", lambda o: o["rows"].pop("default"))
        result = self.gate()
        self.assertLane(result, "invalid-release")
        self.assertIn("rate-card.json removes the default row", result["reasons"])

    def test_usd_per_million_credits_is_pricing_globals(self) -> None:
        self.rate_card(lambda o: o.update(usd_per_million_credits=2.0))
        result = self.gate()
        self.assertLane(result, "pricing-globals")
        self.assertTrue(any("usd_per_million_credits" in r for r in result["reasons"]), result)

    def test_share_and_multiplier_are_pricing_globals(self) -> None:
        for field in ("provider_share_bps", "global_multiplier_ppm"):
            with self.subTest(field):
                self.tearDown()
                self.setUp()

                def bump(o: dict, field: str = field) -> None:
                    for row in o["rows"].values():
                        row[field] -= 1

                self.rate_card(bump)
                self.assertLane(self.gate(), "pricing-globals")

    def test_policy_version_stays_full_provider_app(self) -> None:
        self.rate_card(lambda o: o.update(policy_version="rate-card-policy-v2"))
        self.assertLane(self.gate(), "full-provider-app")

    def test_stale_or_future_wins_over_pricing_lanes(self) -> None:
        self.rate_card(lambda o: o.update(usd_per_million_credits=2.0))
        result = self.gate(now=GENERATED_AT + timedelta(days=31))
        self.assertLane(result, "stale-or-future")
        self.assertTrue(any("usd_per_million_credits" in r for r in result["reasons"]), result)
        order = cr.CONTENT_GATE_LANE_ORDER
        self.assertNotIn("pricing", order)
        self.assertLess(order.index("stale-or-future"), order.index("pricing-globals"))
        self.assertLess(order.index("pricing-globals"), order.index("pricing-unacked-move"))

    def test_row_addition_capturing_only_its_own_key_needs_no_acknowledgement(self) -> None:
        def add(o: dict) -> None:
            o["rows"]["zz-new-model"] = dict(o["rows"]["qwen3-8b"])

        self.rate_card(add)
        result = self.gate()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["pricing"]["added"][0]["row"], "zz-new-model")
        # A self acknowledgement stays accepted (older reviewed files carry it).
        result = self.gate(ack_data=acks(("zz-new-model", "default", "zz-new-model")))
        self.assertTrue(result["ok"], result)

    def test_own_row_exemption_is_exact(self) -> None:
        own = cr.pricing_move_is_own_row
        self.assertTrue(own("zz-new-model", "default", "zz-new-model"))
        self.assertFalse(own("Zz-New-Model", "default", "zz-new-model"))  # captured through normalization
        self.assertFalse(own("zz-new-model", "qwen3-8b", "zz-new-model"))  # moved off another row
        self.assertFalse(own("zz-new-model", "zz-new-model", "default"))  # a removal
        self.assertFalse(own("default", "default", "default"))

    def test_supplied_pricing_diff_is_bound(self) -> None:
        self.rate_card(lambda o: o["rows"]["qwen3-8b"].update(completion_rate_per_mtok=27001))
        live_rows = cr.pricing_credit_rows(json.loads((self.live / "rate-card.json").read_bytes())["rows"])
        release_rows = cr.pricing_credit_rows(json.loads((self.release / "rate-card.json").read_bytes())["rows"])

        def acknowledged(rows: dict, ack: bytes = EMPTY_ACKS, resolutions: list | None = None) -> bytes:
            diff, _ = cr.pricing_effective_diff(live_rows, rows, set(), {"x", "bad name"}, ack)
            return cr.pricing_canonical_bytes(cr.pricing_acknowledged_object(diff, go_resolutions("bad name") if resolutions is None else resolutions))

        data = acknowledged(release_rows)
        result = self.gate(pricing_diff=data, pricing_diff_sha256=cr.sha256(data))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["pricing_diff_sha256"], cr.sha256(data))
        self.assertLane(self.gate(pricing_diff=data, pricing_diff_sha256="0" * 64), "pricing-unacked-move")
        other_rows = copy.deepcopy(release_rows)
        other_rows["qwen3-8b"]["completion_rate_per_mtok"] += 1
        other = acknowledged(other_rows)
        self.assertLane(self.gate(pricing_diff=other, pricing_diff_sha256=cr.sha256(other)), "pricing-unacked-move")
        # A diff produced under a different acknowledgement file is refused.
        stale = acknowledged(release_rows, acks(("q", "default", "qwen3-8b")))
        self.assertLane(self.gate(pricing_diff=stale, pricing_diff_sha256=cr.sha256(stale)), "pricing-unacked-move")
        # The bare effective diff (no coordinator resolutions) is not the acknowledged object.
        bare = cr.pricing_canonical_bytes(cr.pricing_effective_diff(live_rows, release_rows, set(), {"x", "bad name"}, EMPTY_ACKS)[0])
        self.assertLane(self.gate(pricing_diff=bare, pricing_diff_sha256=cr.sha256(bare)), "pricing-unacked-move")

    def test_coordinator_resolved_names_are_bound_and_moves_need_acks(self) -> None:
        self.rate_card(lambda o: o["rows"]["qwen3-8b"].update(completion_rate_per_mtok=27001))
        live_rows = cr.pricing_credit_rows(json.loads((self.live / "rate-card.json").read_bytes())["rows"])
        release_rows = cr.pricing_credit_rows(json.loads((self.release / "rate-card.json").read_bytes())["rows"])
        diff, _ = cr.pricing_effective_diff(live_rows, release_rows, set(), {"bad name"}, EMPTY_ACKS)
        obj = cr.pricing_acknowledged_object(diff, go_resolutions("bad name"))
        # A coordinator-resolved row move without an acknowledgement is refused.
        obj["model_resolutions"][0]["new"]["row_key"] = "qwen3-8b"
        moved = cr.pricing_canonical_bytes(obj)
        result = self.gate(pricing_diff=moved, pricing_diff_sha256=cr.sha256(moved))
        self.assertLane(result, "pricing-unacked-move")
        self.assertTrue(any("coordinator-resolved move" in r for r in result["reasons"]), result)
        # ...and accepted once the reviewed commit acknowledges exactly that move.
        ack = acks(("bad name", "default", "qwen3-8b"))
        diff, _ = cr.pricing_effective_diff(live_rows, release_rows, set(), {"bad name"}, ack)
        obj = cr.pricing_acknowledged_object(diff, go_resolutions("bad name"))
        obj["model_resolutions"][0]["new"]["row_key"] = "qwen3-8b"
        acked = cr.pricing_canonical_bytes(obj)
        result = self.gate(ack_data=ack, pricing_diff=acked, pricing_diff_sha256=cr.sha256(acked))
        self.assertTrue(result["ok"], result)
        # A coordinator-resolved name captured by an added row of exactly its
        # own name needs no acknowledgement; any other destination does.
        diff, _ = cr.pricing_effective_diff(live_rows, release_rows, set(), {"bad name"}, EMPTY_ACKS)
        own_obj = cr.pricing_acknowledged_object(diff, go_resolutions("bad name"))
        own_obj["model_resolutions"][0]["new"]["row_key"] = "bad name"
        own_bytes = cr.pricing_canonical_bytes(own_obj)
        self.assertTrue(self.gate(pricing_diff=own_bytes, pricing_diff_sha256=cr.sha256(own_bytes))["ok"])
        # Resolutions must cover exactly the digested unresolved names.
        obj["model_resolutions"] = []
        uncovered = cr.pricing_canonical_bytes(obj)
        self.assertLane(self.gate(ack_data=ack, pricing_diff=uncovered, pricing_diff_sha256=cr.sha256(uncovered)), "pricing-unacked-move")


def go_resolution(name: str, row: str = "default", rates: tuple[int, int, int] = (500000, 125000, 1000000),
                  new_rates: tuple[int, int, int] | None = None, new_row: str | None = None) -> dict:
    def side(key: str, values: tuple[int, int, int]) -> dict:
        return {"row_key": key, "prompt_credits_per_mtok": values[0],
                "prompt_cache_hit_credits_per_mtok": values[1], "completion_credits_per_mtok": values[2]}

    return {"name": name, "old": side(row, rates), "new": side(new_row or row, new_rates or rates)}


def go_resolutions(*names: str) -> list:
    return [go_resolution(name) for name in names]


class AcknowledgedPricingObjectTests(unittest.TestCase):
    """SEC-M1: the acknowledged digest covers the coordinator-resolved names."""

    def setUp(self) -> None:
        self.live = {"default": {"completion_rate_per_mtok": 2, "prompt_cache_hit_rate_per_mtok": 1, "prompt_rate_per_mtok": 1},
                     "qwen3-8b": {"completion_rate_per_mtok": 4, "prompt_cache_hit_rate_per_mtok": 1, "prompt_rate_per_mtok": 2}}
        self.candidate = copy.deepcopy(self.live)
        self.candidate["qwen3-8b"]["completion_rate_per_mtok"] = 5
        self.diff, _ = cr.pricing_effective_diff(self.live, self.candidate, set(), {"b name", "a\x1bname", "qwen3-8b"}, EMPTY_ACKS)

    def digest(self, resolutions: list) -> str:
        return cr.sha256(cr.pricing_canonical_bytes(cr.pricing_acknowledged_object(self.diff, resolutions)))

    def test_object_is_sorted_escaped_and_complete(self) -> None:
        obj = cr.pricing_acknowledged_object(self.diff, [go_resolution("b name"), go_resolution("a\x1bname")])
        self.assertEqual(obj["schema_version"], cr.PRICING_ACKNOWLEDGED_SCHEMA)
        self.assertEqual(obj["effective_diff"], self.diff)
        self.assertEqual([r["name"] for r in obj["model_resolutions"]], self.diff["unresolved_names"])
        self.assertEqual(obj["model_resolutions"][0]["name"], "a\\x1bname")
        self.assertEqual(set(obj["model_resolutions"][0]["old"]), {"row_key", *cr.PRICING_RESOLVED_RATE_FIELDS})

    def test_only_a_go_resolved_price_change_moves_the_digest(self) -> None:
        base = self.digest([go_resolution("b name"), go_resolution("a\x1bname")])
        for index in range(3):
            with self.subTest(field=index):
                bumped = [500000, 125000, 1000000]
                bumped[index] += 1
                changed = self.digest([go_resolution("b name", new_rates=tuple(bumped)), go_resolution("a\x1bname")])
                self.assertNotEqual(changed, base)
        self.assertNotEqual(self.digest([go_resolution("b name", new_row="qwen3-8b"), go_resolution("a\x1bname")]), base)
        # A name first seen after pinning stays out of the acknowledged digest.
        self.assertEqual(self.digest([go_resolution("b name"), go_resolution("a\x1bname"), go_resolution("new name")]), base)

    def test_missing_duplicate_or_malformed_resolutions_fail(self) -> None:
        for resolutions in (
            [go_resolution("b name")],
            [go_resolution("b name"), go_resolution("b name"), go_resolution("a\x1bname")],
            [go_resolution("b name", row=""), go_resolution("a\x1bname")],
            [dict(go_resolution("b name"), extra=1), go_resolution("a\x1bname")],
            [go_resolution("b name", rates=(1, 1, -1)), go_resolution("a\x1bname")],
            "not a list",
        ):
            with self.subTest(resolutions=resolutions):
                with self.assertRaises(cr.CatalogError):
                    cr.pricing_acknowledged_object(self.diff, resolutions)


class GateCommitBlockTests(unittest.TestCase):
    """--commit binds the committed coordinator rate_card block to the release rows."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.release = assemble(self.tmp / "release")
        self.live = assemble(self.tmp / "live")

        def reprice(o: dict) -> None:
            o["rows"]["qwen3-8b"]["completion_rate_per_mtok"] = 27001
            o["version"] = cr.rate_card_projection_hash(o)

        edit_json(self.release / "rate-card.json", reprice)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp)

    def commit(self, coordinator: bytes | None, ack: bytes | None = EMPTY_ACKS) -> str:
        repo = self.tmp / "repo"
        static = repo / "phase3-binary" / "dist" / "static"
        catalog = repo / "phase3-binary" / "catalog" / "autotune"
        static.mkdir(parents=True)
        catalog.mkdir(parents=True)
        for name in STATIC_FILES:
            shutil.copyfile(self.release / name, static / name)
        for name in ("release.json", "trusted-keys.json", "tier2-catalog.json"):
            shutil.copyfile(self.release / name, catalog / name)
        shutil.copyfile(LEDGER, catalog / "release-ledger.json")
        (catalog / "not-buyer-serving.json").write_bytes(NO_EXCLUSIONS)
        if ack is not None:
            (catalog / "acknowledged-pricing-moves.json").write_bytes(ack)
        if coordinator is not None:
            (repo / "phase4-coordinator" / "dist").mkdir(parents=True)
            (repo / "phase4-coordinator" / "dist" / "coordinator.yaml").write_bytes(coordinator)
        git(repo.parent, "init", "-q", str(repo))
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "release")
        sha = git(repo, "rev-parse", "HEAD")
        git(repo, "update-ref", "refs/remotes/origin/main", sha)
        self.repo = repo
        return sha

    def gate(self, sha: str) -> dict:
        with mock.patch.object(cr, "verify_directory", lambda _directory: None):
            return cr.content_gate(self.release, self.live, LEDGER, commit=sha, now=NOW, repo=self.repo)

    def test_matching_block_is_bound(self) -> None:
        block = reprice_block(tracked_block(), "qwen3-8b", "completion_credits_per_mtok", 27001)
        coordinator = cr.splice_coordinator_rate_card(TRACKED, block)
        result = self.gate(self.commit(coordinator))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["commit_block_sha256"], cr.sha256(block))
        self.assertEqual(result["acknowledged_moves_sha256"], cr.sha256(EMPTY_ACKS))

    def test_mismatched_block_is_unverified_commit(self) -> None:
        result = self.gate(self.commit(TRACKED))
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["lane"], "unverified-commit", result)
        self.assertTrue(any("does not bind the release rate card" in r for r in result["reasons"]), result)

    def test_missing_config_or_ack_is_unverified_commit(self) -> None:
        self.assertEqual(self.gate(self.commit(None))["lane"], "unverified-commit")
        shutil.rmtree(self.repo)
        block = reprice_block(tracked_block(), "qwen3-8b", "completion_credits_per_mtok", 27001)
        result = self.gate(self.commit(cr.splice_coordinator_rate_card(TRACKED, block), ack=None))
        self.assertEqual(result["lane"], "unverified-commit", result)
        self.assertTrue(any("acknowledged-pricing-moves.json" in r for r in result["reasons"]), result)


if __name__ == "__main__":
    unittest.main()
