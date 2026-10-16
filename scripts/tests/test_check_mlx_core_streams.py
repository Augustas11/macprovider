import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_mlx_core_streams import scan

SCRIPT = Path(__file__).resolve().parents[1] / "check_mlx_core_streams.py"

HEADER = """
namespace mlx::core {
array add(const array& a, const array& b, StreamOrDevice s = {});
array multiply(const array& a, const array& b, StreamOrDevice s = {});
array astype(array a, Dtype dtype, StreamOrDevice s = {});
std::vector<array> broadcast_arrays(const std::vector<array>& inputs, StreamOrDevice s = {});
array to_stream_free(const array& a);
} // namespace mlx::core
"""

RANDOM_HEADER = """
class KeySequence {
 public:
  array next(StreamOrDevice s = {});
};
"""


def core(ops_cpp: str, random_cpp: str = "") -> Path:
    root = Path(tempfile.mkdtemp())
    (root / "mlx").mkdir()
    (root / "mlx" / "ops.h").write_text(HEADER)
    (root / "mlx" / "random.h").write_text(RANDOM_HEADER)
    (root / "mlx" / "ops.cpp").write_text(ops_cpp)
    (root / "mlx" / "random.cpp").write_text(random_cpp)
    return root


class CheckMLXCoreStreamsTests(unittest.TestCase):
    def test_call_that_passes_the_stream_is_clean(self):
        root = core("""
array f(const array& x, StreamOrDevice s /* = {} */) {
  auto y = astype(x, float32, s);
  return add(y, multiply(y, x, to_stream(s)), s);
}
""")
        self.assertEqual(scan(root), [])

    def test_call_without_the_stream_is_reported(self):
        root = core("""
array quantized_matmul(array x, array scales, StreamOrDevice s) {
  std::vector<array> inputs = {astype(x, float32), astype(scales, float32, s)};
  auto b = broadcast_arrays(inputs);
  return add(b[0], b[1], s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)
        self.assertIn("[quantized_matmul] stream-less call: astype(x, float32)", findings[0] + findings[1])
        self.assertTrue(any("broadcast_arrays(inputs)" in f for f in findings))

    def test_operator_overload_on_arrays_is_reported(self):
        root = core("""
array l2(const array& a, StreamOrDevice s) {
  auto y = add(a, a, s);
  return multiply(a, y, s) * y;
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("operator on array", findings[0])

    def test_shape_and_dtype_arithmetic_is_not_an_array_operator(self):
        root = core("""
array f(const array& a, const array& b, StreamOrDevice s) {
  if (a.ndim() == 0 || a.shape(-1) != b.shape(-1) || a.dtype() == float32) {
    return add(a, b, s);
  }
  int n = a.shape()[a.shape().size() - 2] * 2;
  Shape shape(a.ndim(), 1);
  return add(a, b, s);
}
""")
        self.assertEqual(scan(root), [])

    def test_primitive_rule_using_stream_is_checked(self):
        root = core("""
std::vector<array> Thing::vjp(const std::vector<array>& primals) {
  auto s = stream();
  auto n = add(primals[0], primals[0]);
  return {multiply(n, primals[0], s), add(n, n, stream())};
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("[vjp] stream-less call: add(primals[0], primals[0])", findings[0])

    def test_implicit_random_key_must_take_the_stream(self):
        root = core(
            "",
            """
array bits(const std::optional<array>& key_, StreamOrDevice s) {
  auto key = key_ ? *key_ : KeySequence::default_().next();
  return add(key, key, s);
}
""",
        )
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("[bits] stream-less call: next()", findings[0])

    def test_cli_exit_codes(self):
        clean = core("array f(const array& x, StreamOrDevice s) {\n  return add(x, x, s);\n}\n")
        dirty = core("array f(const array& x, StreamOrDevice s) {\n  return add(x, x);\n}\n")
        run = lambda root: subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(root)], capture_output=True, text=True
        )
        self.assertEqual(run(clean).returncode, 0)
        result = run(dirty)
        self.assertEqual(result.returncode, 1)
        self.assertIn("stream-less call: add(x, x)", result.stdout)
        self.assertEqual(run(Path(tempfile.mkdtemp())).returncode, 2)


if __name__ == "__main__":
    unittest.main()
