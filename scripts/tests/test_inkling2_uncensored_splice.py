"""#2467: the uncensored Inkling-2-Mini splice refuses any change outside the attention output
projections and writes only the re-quantized projections into a clone of the base.

Tiny synthetic checkpoints in the three layouts (original and uncensored source: `model.llm.*`
BF16; base: oQ `model.layers.N.attn.o_proj` weight/scales/biases), stdlib only. The quantizer
is a stand-in with the real byte sizes, so the plumbing (diff rules, in-place write, the
verification of every other tensor and file) is what these tests check; the numeric gate's
real numbers come from mx.quantize on the Studio.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "inkling2_uncensored_splice", ROOT / "scripts" / "lab" / "2467" / "inkling2_uncensored_splice.py")
splice_mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(splice_mod)

ROWS, COLS, GROUP, BITS = 4, 128, 64, 8


def write_safetensors(path: Path, tensors: dict[str, tuple[str, list[int], bytes]]) -> None:
    header, offset, blobs = {}, 0, []
    for name in sorted(tensors):
        dtype, shape, raw = tensors[name]
        header[name] = {"dtype": dtype, "shape": shape, "data_offsets": [offset, offset + len(raw)]}
        offset += len(raw)
        blobs.append(raw)
    header["__metadata__"] = {"format": "pt"}
    blob = json.dumps(header).encode()
    path.write_bytes(struct.pack("<Q", len(blob)) + blob + b"".join(blobs))


def write_checkpoint(root: Path, tensors: dict, extra: dict[str, bytes] | None = None) -> None:
    root.mkdir(parents=True, exist_ok=True)
    shard = "model-00001-of-00001.safetensors"
    write_safetensors(root / shard, tensors)
    (root / "model.safetensors.index.json").write_text(json.dumps({"weight_map": {n: shard for n in tensors}}))
    for name, raw in (extra or {}).items():
        (root / name).write_bytes(raw)


def bf16(seed: int, n: int) -> bytes:
    out = bytearray()
    while len(out) < 2 * n:
        out += hashlib.sha256(f"{seed}-{len(out)}".encode()).digest()
    # Keep every value a finite BF16 (exponent field never all ones).
    raw = bytearray(out[: 2 * n])
    for i in range(1, len(raw), 2):
        raw[i] &= 0x3F
    return bytes(raw)


def checksum(path: Path) -> dict:
    return {"sha256": splice_mod.sha256_file(path), "size": path.stat().st_size}


class FakeQuantizer:
    """Deterministic bytes of the real affine sizes; errors that pass the gate."""

    def quantize(self, raw, shape, spec):
        rows, cols = shape
        h = lambda tag, n: (hashlib.sha256(tag.encode() + raw).digest() * (n // 32 + 1))[:n]
        return {"weight": h("w", rows * cols * spec["bits"] // 8),
                "scales": h("s", rows * cols // spec["group_size"] * 2),
                "biases": h("b", rows * cols // spec["group_size"] * 2)}

    def error(self, parts, spec, ref_raw, shape):
        return {"ref_max_abs": 1.0, "max_abs": 0.01, "rel_fro": 0.001, "mlx_vs_numpy_max_abs": 0.0}

    def edit_size(self, new_raw, old_raw, shape):
        return {"max_abs": 0.1, "rel_fro": 0.01, "elements_changed": 1}


class SpliceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="inkling2-splice-"))
        self.addCleanup(shutil.rmtree, self.tmp)
        self.q = FakeQuantizer()
        spec = {"group_size": GROUP, "bits": BITS, "mode": "affine"}
        wo = {i: bf16(i, ROWS * COLS) for i in range(3)}
        other = bf16(99, 16)
        orig = {f"model.llm.layers.{i}.attn.wo_ud.weight": ("BF16", [ROWS, COLS], wo[i]) for i in range(3)}
        orig["model.llm.norm.weight"] = ("BF16", [16], other)
        self.orig_tensors = orig
        write_checkpoint(self.tmp / "orig", orig, {"config.json": b'{"a": 1, "dtype": "bfloat16"}'})
        # The base: the original's projections re-quantized, plus an unrelated tensor.
        base = {"model.norm.weight": ("BF16", [16], other)}
        for i in range(3):
            parts = self.q.quantize(wo[i], [ROWS, COLS], {**spec, "scale_dtype": "BF16"})
            m = f"model.layers.{i}.attn.o_proj"
            base[m + ".weight"] = ("U32", [ROWS, COLS * BITS // 32], parts["weight"])
            base[m + ".scales"] = ("BF16", [ROWS, COLS // GROUP], parts["scales"])
            base[m + ".biases"] = ("BF16", [ROWS, COLS // GROUP], parts["biases"])
        config = {"quantization": {"group_size": 64, "bits": 4, "mode": "affine",
                                   **{f"model.layers.{i}.attn.o_proj": spec for i in range(3)}}}
        write_checkpoint(self.tmp / "base", base, {"config.json": json.dumps(config).encode(), "tokenizer.json": b"{}"})
        self.base_files = {n: checksum(self.tmp / "base" / n) for n in splice_mod.listing(self.tmp / "base")}

    def source(self, changes: dict[str, bytes], extra: dict[str, bytes] | None = None) -> Path:
        tensors = dict(self.orig_tensors)
        for name, raw in changes.items():
            dtype, shape, _ = tensors[name]
            tensors[name] = (dtype, shape, raw)
        root = self.tmp / "src"
        if root.exists():
            shutil.rmtree(root)
        write_checkpoint(root, tensors, {"config.json": b'{"a": 1}', **(extra or {})})
        return root

    def fetch(self, src: Path) -> dict:
        org = self.tmp / "orig"
        files = ["model-00001-of-00001.safetensors", "model.safetensors.index.json", "config.json"]
        return {"fetched": files,
                "source_files": {n: checksum(src / n) for n in files},
                "original_files": {n: checksum(org / n) for n in files},
                "served_base_files": self.base_files,
                "source": {}, "original": {}, "served_base": {}}

    def diff(self, src: Path, expect: int | None) -> dict:
        org = self.tmp / "orig"
        fetch = self.fetch(src)
        files = splice_mod.compare_files(fetch, src, org)
        return {**files, **splice_mod.diff_tensors(splice_mod.Shards(src), splice_mod.Shards(org), expect)}

    def clone_base(self) -> Path:
        out = self.tmp / "out"
        shutil.copytree(self.tmp / "base", out)
        return out

    def test_only_the_changed_projections_are_rewritten(self):
        src = self.source({"model.llm.layers.1.attn.wo_ud.weight": bf16(1001, ROWS * COLS)})
        diff = self.diff(src, 1)
        self.assertEqual([c["layer"] for c in diff["changed_tensors"]], [1])
        self.assertEqual(diff["differing_ignorable"], ["config.json (ignorable keys only)"])
        out = self.clone_base()
        doc = splice_mod.splice(self.tmp / "base", src, self.tmp / "orig", out, self.fetch(src), diff, self.q, 1.25, 2.0)
        self.assertEqual(doc["recipe_reproduced"], 1)
        self.assertEqual([r["module"] for r in doc["changed_modules"]], ["model.layers.1.attn.o_proj"])
        base_sh, out_sh = splice_mod.Shards(self.tmp / "base"), splice_mod.Shards(out)
        for name in base_sh.names():
            same = base_sh.read(name) == out_sh.read(name)
            self.assertEqual(same, not name.startswith("model.layers.1.attn.o_proj."), name)
        self.assertEqual(splice_mod.read_header(out / "model-00001-of-00001.safetensors")[2],
                         splice_mod.read_header(self.tmp / "base" / "model-00001-of-00001.safetensors")[2])
        self.assertEqual((out / "tokenizer.json").read_bytes(), b"{}")

    def test_a_change_outside_the_output_projections_is_refused(self):
        src = self.source({"model.llm.layers.1.attn.wo_ud.weight": bf16(1001, ROWS * COLS),
                           "model.llm.norm.weight": bf16(5, 16)})
        with self.assertRaisesRegex(splice_mod.Blocker, "outside the attention output projections"):
            self.diff(src, None)

    def test_the_card_count_is_enforced(self):
        src = self.source({"model.llm.layers.1.attn.wo_ud.weight": bf16(1001, ROWS * COLS)})
        with self.assertRaisesRegex(splice_mod.Blocker, "the card says 20"):
            self.diff(src, 20)
        no_change = self.source({})
        with self.assertRaisesRegex(splice_mod.Blocker, "no tensor differs"):
            self.diff(no_change, None)

    def test_a_pickle_in_a_model_directory_is_refused(self):
        src = self.source({"model.llm.layers.1.attn.wo_ud.weight": bf16(1001, ROWS * COLS)}, {"edit.pt": b"\x80\x04."})
        diff = self.diff(src, 1)
        with self.assertRaisesRegex(splice_mod.Blocker, "pickle-like"):
            splice_mod.splice(self.tmp / "base", src, self.tmp / "orig", self.clone_base(), self.fetch(src), diff,
                              self.q, 1.25, 2.0)
        self.assertTrue(splice_mod.is_pickle_like("edit.pt"))
        with self.assertRaisesRegex(splice_mod.Blocker, "pickle-like"):
            splice_mod.download("x/y", "rev", "edit.pt", self.tmp, {})

    def test_extra_or_differing_side_files_are_refused(self):
        fetch = self.fetch(self.source({}))
        fetch["source_files"]["edit.pt"] = {"sha256": "0" * 64, "size": 1}
        splice_mod.compare_files(fetch, self.tmp / "src", self.tmp / "orig")  # edit.pt is the allowed extra
        fetch["source_files"]["other.bin"] = {"sha256": "0" * 64, "size": 1}
        with self.assertRaisesRegex(splice_mod.Blocker, "extra files"):
            splice_mod.compare_files(fetch, self.tmp / "src", self.tmp / "orig")
        fetch = self.fetch(self.source({}))
        fetch["source_files"]["tokenizer.json"] = {"blob_sha1": "a", "size": 1}
        fetch["original_files"]["tokenizer.json"] = {"blob_sha1": "b", "size": 1}
        with self.assertRaisesRegex(splice_mod.Blocker, "differ from the original"):
            splice_mod.compare_files(fetch, self.tmp / "src", self.tmp / "orig")

    def test_the_numeric_gate_refuses_a_worse_error_and_a_lost_edit(self):
        src = self.source({"model.llm.layers.1.attn.wo_ud.weight": bf16(1001, ROWS * COLS)})
        diff = self.diff(src, 1)

        class Worse(FakeQuantizer):
            def error(self, parts, spec, ref_raw, shape):
                worse = ref_raw == src_raw
                return {"ref_max_abs": 1.0, "max_abs": 0.01, "rel_fro": 0.002 if worse else 0.001,
                        "mlx_vs_numpy_max_abs": 0.0}

        src_raw = splice_mod.Shards(src).read("model.llm.layers.1.attn.wo_ud.weight")
        with self.assertRaisesRegex(splice_mod.Blocker, "numeric gate failed: .*rel_fro"):
            splice_mod.splice(self.tmp / "base", src, self.tmp / "orig", self.clone_base(), self.fetch(src), diff,
                              Worse(), 1.25, 2.0)

        class Lost(FakeQuantizer):
            def quantize(self, raw, shape, spec):
                return super().quantize(orig_raw, shape, spec)

        orig_raw = splice_mod.Shards(self.tmp / "orig").read("model.llm.layers.1.attn.wo_ud.weight")
        shutil.rmtree(self.tmp / "out")
        with self.assertRaisesRegex(splice_mod.Blocker, "edit did not survive"):
            splice_mod.splice(self.tmp / "base", src, self.tmp / "orig", self.clone_base(), self.fetch(src), diff,
                              Lost(), 1.25, 2.0)

    def test_the_recipe_check_runs_on_the_original_alone(self):
        doc = splice_mod.recipe(self.tmp / "base", self.tmp / "orig", self.q, 1.25, 2.0)
        self.assertEqual([r["layer"] for r in doc["modules"]], [0, 1, 2])
        self.assertEqual(doc["reproduced"], 3)

        class Transformed(FakeQuantizer):
            # A base that is not a plain quantization of attn.wo_ud: its error on the original is large.
            def error(self, parts, spec, ref_raw, shape):
                return {"ref_max_abs": 1.0, "max_abs": 0.5, "rel_fro": 0.9, "mlx_vs_numpy_max_abs": 0.0}

        with self.assertRaisesRegex(splice_mod.Blocker, "recipe check failed: .*not a plain quantization"):
            splice_mod.recipe(self.tmp / "base", self.tmp / "orig", Transformed(), 1.25, 2.0)

        class Drifted(FakeQuantizer):
            # Our recipe is not byte-equal and errs far more than the base's on the original.
            def quantize(self, raw, shape, spec):
                return super().quantize(raw + b"x", shape, spec)

            def error(self, parts, spec, ref_raw, shape):
                ours = parts == super().quantize(ref_raw + b"x", shape, spec)
                return {"ref_max_abs": 1.0, "max_abs": 0.01, "rel_fro": 0.01 if ours else 0.001,
                        "mlx_vs_numpy_max_abs": 0.0}

        with self.assertRaisesRegex(splice_mod.Blocker, "recipe check failed: .*our recipe on the original rel_fro"):
            splice_mod.recipe(self.tmp / "base", self.tmp / "orig", Drifted(), 1.25, 2.0)

    def test_the_source_listing_must_be_the_committed_manifest(self):
        path = ROOT / "docs" / "evidence" / "inkling-2-mini-intake-2026-11-24" / "openuncensored-source-050f1cec.manifest"
        data = path.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), splice_mod.SOURCE_MANIFEST_SHA256)
        manifest = splice_mod.parse_manifest(data)
        self.assertIn("edit.pt", manifest)
        listing = {n: {"sha256": v["sha256"], "size": v["size"]} for n, v in manifest.items()}
        splice_mod.check_source_listing(listing, manifest)
        listing["model-00001-of-00001.safetensors"] = {"sha256": "0" * 64, "size": manifest["model-00001-of-00001.safetensors"]["size"]}
        with self.assertRaisesRegex(splice_mod.Blocker, "committed manifest"):
            splice_mod.check_source_listing(listing, manifest)


if __name__ == "__main__":
    unittest.main()
