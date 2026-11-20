"""Offline tests of dsv4_abliterated_splice.py on synthetic tensors (numpy only).

Run: python3 -m unittest scripts/lab/dsv4/test_dsv4_abliterated_splice.py
"""

import contextlib
import hashlib
import io
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dsv4_abliterated_splice as sp  # noqa: E402

RNG = np.random.default_rng(2409)


def write_safetensors(path: Path, tensors: dict) -> None:
    """tensors: name -> (dtype, shape, bytes)."""
    header, off, blobs = {"__metadata__": {"format": "pt"}}, 0, []
    for name, (dtype, shape, raw) in tensors.items():
        header[name] = {"dtype": dtype, "shape": list(shape), "data_offsets": [off, off + len(raw)]}
        off += len(raw)
        blobs.append(raw)
    h = json.dumps(header).encode()
    h += b" " * (-len(h) % 8)
    path.write_bytes(struct.pack("<Q", len(h)) + h + b"".join(blobs))


def fp4_native(rows, cols):
    packed = RNG.integers(0, 256, size=(rows, cols // 2), dtype=np.uint8)
    scales = RNG.integers(110, 135, size=(rows, cols // 32), dtype=np.uint8)
    return packed, scales


def fp8_native(rows, cols):
    raw = RNG.integers(0, 256, size=(rows, cols), dtype=np.uint8)
    raw[(raw & 0x7F) == 0x7F] = 0x10  # no NaN codes in weights
    scales = RNG.integers(110, 135, size=(-(-rows // 128), -(-cols // 128)), dtype=np.uint8)
    return raw, scales


class Formats(unittest.TestCase):
    def test_e4m3_codes(self):
        self.assertEqual(sp.E4M3[0x7E], 448.0)
        self.assertEqual(sp.E4M3[0xFE], -448.0)
        self.assertEqual(sp.E4M3[0x01], 2.0 ** -9)
        self.assertEqual(sp.E4M3[0x38], 1.0)
        self.assertTrue(np.isnan(sp.E4M3[0x7F]) and np.isnan(sp.E4M3[0xFF]))
        try:
            import ml_dtypes
        except ImportError:
            return
        ref = np.arange(256, dtype=np.uint8).view(ml_dtypes.float8_e4m3fn).astype(np.float64)
        np.testing.assert_array_equal(np.nan_to_num(ref, nan=7.0), np.nan_to_num(sp.E4M3, nan=7.0))

    def test_e8m0(self):
        s = np.array([127, 128, 0, 254, 255], dtype=np.uint8)
        out = sp.e8m0(s)
        self.assertEqual(list(out[:4]), [1.0, 2.0, 2.0 ** -127, 2.0 ** 127])
        self.assertTrue(np.isnan(out[4]))

    def test_fp4_low_nibble_first(self):
        packed = np.array([[0x21, 0xF8] * 16], dtype=np.uint8)  # 64 values
        scales = np.array([[127, 128]], dtype=np.uint8)
        v = sp.decode_fp4_native(packed, scales)
        self.assertEqual(list(v[0, :4]), [0.5, 1.0, -0.0, -6.0])
        self.assertEqual(list(v[0, 32:36]), [1.0, 2.0, -0.0, -12.0])

    def test_mx_lane_semantics(self):
        # Element j of a uint32 lane sits at bits [bits*j, bits*(j+1)): decode bit by bit.
        for bits, (native, scales) in ((4, fp4_native(8, 64)), (8, fp8_native(8, 64))):
            w = np.frombuffer(native.tobytes(), dtype="<u4").reshape(8, -1)
            if bits == 8:
                scales = sp.fp8_block_scales_to_mx(scales, 8, 64)
            per = 32 // bits
            codes = np.stack([(w >> (bits * j)) & ((1 << bits) - 1) for j in range(per)], axis=-1).reshape(8, -1)
            table = sp.FP4_TABLE if bits == 4 else sp.E4M3
            want = table[codes] * np.repeat(sp.e8m0(scales), 32, axis=1)
            np.testing.assert_array_equal(sp.decode_mx_numpy(w, scales, bits), want)

    def test_transplant_round_trip(self):
        for rows, cols in ((256, 512), (320, 384), (128, 1024)):
            packed, s4 = fp4_native(rows, cols)
            src_w = {"dtype": "I8", "shape": [rows, cols // 2]}
            dst_w = {"dtype": "U32", "shape": [rows, cols // 8]}
            w = sp.transplant("x.weight", src_w, packed.tobytes(), dst_w, None)
            s = sp.transplant("x.scale", {"dtype": "F8_E8M0", "shape": list(s4.shape)}, s4.tobytes(),
                              {"dtype": "U8", "shape": list(s4.shape)}, "I8")
            mw = np.frombuffer(w, "<u4").reshape(rows, cols // 8)
            ms = np.frombuffer(s, np.uint8).reshape(s4.shape)
            self.assertEqual(sp.max_abs_error(sp.decode_mx_numpy(mw, ms, 4), sp.decode_fp4_native(packed, s4)), 0.0)

            raw, s8 = fp8_native(rows, cols)
            w = sp.transplant("y.weight", {"dtype": "F8_E4M3", "shape": [rows, cols]}, raw.tobytes(),
                              {"dtype": "U32", "shape": [rows, cols // 4]}, None)
            s = sp.transplant("y.scale", {"dtype": "F8_E8M0", "shape": list(s8.shape)}, s8.tobytes(),
                              {"dtype": "U8", "shape": [rows, cols // 32]}, "F8_E4M3")
            mw = np.frombuffer(w, "<u4").reshape(rows, cols // 4)
            ms = np.frombuffer(s, np.uint8).reshape(rows, cols // 32)
            self.assertEqual(sp.max_abs_error(sp.decode_mx_numpy(mw, ms, 8), sp.decode_fp8_native(raw, s8)), 0.0)
            try:
                import mlx.core  # noqa: F401
            except ImportError:
                continue
            self.assertEqual(sp.max_abs_error(sp.decode_mx_mlx(mw, ms, 8), sp.decode_fp8_native(raw, s8)), 0.0)

    def test_transplant_refuses_unknown(self):
        with self.assertRaises(sp.Blocker):
            sp.transplant("z.weight", {"dtype": "BF16", "shape": [4, 4]}, b"\0" * 32, {"dtype": "U32", "shape": [4, 1]}, None)
        with self.assertRaises(sp.Blocker):
            sp.transplant("z.scale", {"dtype": "F8_E8M0", "shape": [1, 1]}, b"\0", {"dtype": "U8", "shape": [256, 8]}, "F8_E4M3")


class Splice(unittest.TestCase):
    """A two-shard toy of layer 17 in both layouts, then the splice end to end."""

    def build(self, root: Path, touch: set):
        native = {
            "layers.17.attn.wo_b": fp8_native(256, 256),
            "layers.17.attn.wq_a": fp8_native(128, 256),
            "layers.17.ffn.shared_experts.w1": fp8_native(128, 256),
            "layers.17.ffn.shared_experts.w2": fp8_native(256, 128),
            "layers.17.ffn.experts.5.w2": fp4_native(64, 64),
            "layers.17.ffn.experts.0.w2": fp4_native(64, 64),
        }
        norm = RNG.integers(0, 256, size=64, dtype=np.uint8).tobytes()
        src, base, edited = {}, {}, {}
        for m, (w, s) in native.items():
            fp4 = ".experts." in m
            src[m + ".weight"] = ("I8" if fp4 else "F8_E4M3", w.shape, w.tobytes())
            src[m + ".scale"] = ("F8_E8M0", s.shape, s.tobytes())
            r, c = w.shape[0], w.shape[1] * (2 if fp4 else 1)
            base[m + ".weight"] = ("U32", (r, c // 8 if fp4 else c // 4), w.tobytes())
            ms = s if fp4 else sp.fp8_block_scales_to_mx(s, r, c)
            base[m + ".scales"] = ("U8", ms.shape, ms.tobytes())
            if m in touch:
                w2 = w.copy()
                w2[0, :4] ^= 0x11
                edited[m] = w2
        for m, w2 in edited.items():
            dt, shape, _ = src[m + ".weight"]
            src[m + ".weight"] = (dt, shape, w2.tobytes())
        src["layers.17.attn_norm.weight"] = ("BF16", (32,), norm)
        base["layers.17.attn_norm.weight"] = ("BF16", (32,), norm)

        (root / "src").mkdir()
        (root / "base").mkdir()
        write_safetensors(root / "src" / "model-00019-of-00048.safetensors", src)
        names = sorted(base)
        write_safetensors(root / "base" / "model-00013.safetensors", {n: base[n] for n in names[:5]})
        write_safetensors(root / "base" / "model-00014.safetensors", {n: base[n] for n in names[5:]})
        (root / "base" / "config.json").write_text("{}")
        (root / "base" / "model.safetensors.index.json").write_text(json.dumps(
            {"weight_map": {n: "model-00013.safetensors" if i < 5 else "model-00014.safetensors" for i, n in enumerate(names)}}))
        (root / "src" / "model.safetensors.index.json").write_text(json.dumps(
            {"weight_map": {n: "model-00019-of-00048.safetensors" for n in src}}))
        (root / "src" / "edited_experts.json").write_text(json.dumps({"17": [5]}))
        shard = root / "src" / "model-00019-of-00048.safetensors"
        want = {}
        for p in (root / "base").iterdir():
            want[p.name] = ({"sha256": sp.sha256_file(p), "size": p.stat().st_size} if p.suffix == ".safetensors"
                            else {"blob_sha1": sp.git_blob_sha1(p), "size": p.stat().st_size})
        fetch = {"source": {}, "source_base": {}, "served_base": {}, "unchanged_shards": {},
                 "changed_shards": {shard.name: {"sha256": sp.sha256_file(shard), "size": shard.stat().st_size}},
                 "served_base_files": want}
        (root / "fetch.json").write_text(json.dumps(fetch))
        subprocess.run(["/bin/cp", "-c", "-R", str(root / "base"), str(root / "out")], check=True)

    def run_splice(self, root: Path) -> int:
        a = SimpleNamespace(base=str(root / "base"), source=str(root / "src"), fetch=str(root / "fetch.json"),
                            out=str(root / "out"), manifest=str(root / "diff.json"), numeric=True, require_mlx=False)
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                return sp.cmd_splice(a)
            except sp.Blocker as exc:
                self.blocker = str(exc)
                return 1

    def test_splice_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.build(root, {"layers.17.attn.wo_b", "layers.17.ffn.experts.5.w2"})
            base_before = {p.name: sp.sha256_file(p) for p in (root / "base").iterdir()}
            self.assertEqual(self.run_splice(root), 0)
            m = json.loads((root / "diff.json").read_text())
            self.assertEqual(sorted(m["changed_tensors"]), ["layers.17.attn.wo_b.weight", "layers.17.ffn.experts.5.w2.weight"])
            self.assertEqual(m["compared"]["identical"], m["compared"]["tensors"] - 2)
            self.assertTrue(m["numeric"]["pass"])
            self.assertEqual(m["numeric"]["worst_max_abs_err"], 0.0)
            self.assertEqual(len([r for r in m["numeric"]["modules"] if r["control"]]), 3)
            self.assertIn("layers.17.ffn.shared_experts.w2", m["steered_modules_unchanged"])
            # The base is never written; only the touched shard differs in OUT.
            self.assertEqual(base_before, {p.name: sp.sha256_file(p) for p in (root / "base").iterdir()})
            out_now = {p.name: sp.sha256_file(p) for p in (root / "out").iterdir()}
            self.assertEqual({n for n in out_now if out_now[n] != base_before[n]}, set(m["touched_shards"]))

    def test_splice_refuses_unsteered_change(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.build(root, {"layers.17.attn.wq_a"})
            self.assertEqual(self.run_splice(root), 1)
            self.assertIn("outside the card's steered modules", self.blocker)
            self.assertFalse((root / "diff.json").exists())

    def test_splice_refuses_identical_source(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.build(root, set())
            self.assertEqual(self.run_splice(root), 1)
            self.assertIn("no tensor differs", self.blocker)


if __name__ == "__main__":
    unittest.main()
