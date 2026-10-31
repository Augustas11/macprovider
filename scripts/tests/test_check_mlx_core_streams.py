import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_mlx_core_streams import strip_comments_and_strings, REQUIRED, CoreRootError, scan

SCRIPT = Path(__file__).resolve().parents[1] / "check_mlx_core_streams.py"

OPS_H = """
namespace mlx::core {
array add(const array& a, const array& b, StreamOrDevice s = {});
array quantized_matmul(array x, array w, array scales, array biases, bool transpose,
    int group_size, int bits, const char* mode, StreamOrDevice s = {}, bool reference_prefill = false);
array multiply(const array& a, const array& b, StreamOrDevice s = {});
array equal(const array& a, const array& b, StreamOrDevice s = {});
array astype(array a, Dtype dtype, StreamOrDevice s = {});
array zeros_like(const array& a, StreamOrDevice s = {});
std::vector<array> broadcast_arrays(const std::vector<array>& inputs, StreamOrDevice s = {});
array operator+(const array& a, const array& b);
array operator*(const array& a, const array& b);
array operator%(const array& a, const array& b);
array operator==(const array& a, const array& b);
array operator<<(const array& a, const array& b);
array operator~(const array& a);
} // namespace mlx::core
"""

RANDOM_H = """
class KeySequence {
 public:
  array next(StreamOrDevice s = {});
};
"""


def core() -> Path:
    """A minimal core root: every required file exists, ops.h declares the ops."""
    root = Path(tempfile.mkdtemp())
    (root / "mlx").mkdir()
    for name in REQUIRED:
        (root / name).write_text("")
    (root / "mlx" / "ops.h").write_text(OPS_H)
    (root / "mlx" / "random.h").write_text(RANDOM_H)
    return root


def ops_cpp(text: str) -> Path:
    root = core()
    (root / "mlx" / "ops.cpp").write_text(text)
    return root


class CheckMLXCoreStreamsTests(unittest.TestCase):
    def test_call_that_passes_the_stream_is_clean(self):
        root = ops_cpp("""
array f(const array& x, StreamOrDevice s /* = {} */) {
  auto t = to_stream(s);
  auto y = astype(x, float32, s);
  return add(y, multiply(y, x, to_stream(s)), t);
}
""")
        self.assertEqual(scan(root), [])

    def test_quantized_prefill_option_preserves_the_stream_slot(self):
        root = ops_cpp("""
array f(const array& x, StreamOrDevice s) {
  auto old = quantized_matmul(x, x, x, x, true, 64, 4, mode, s);
  return quantized_matmul(x, x, x, x, true, 64, 4, mode, s, true);
}
std::vector<array> QuantizedMatmul::jvp(array x) {
  return {quantized_matmul(x, x, x, x, true, 64, 4, mode, stream(), reference_prefill_)};
}
""")
        self.assertEqual(scan(root), [])

    def test_quantized_prefill_option_does_not_hide_wrong_or_missing_stream(self):
        root = ops_cpp("""
array f(const array& x, StreamOrDevice s) {
  auto missing = quantized_matmul(x, x, x, x, true, 64, 4, mode);
  auto wrong = quantized_matmul(x, x, x, x, true, 64, 4, mode, Device::gpu, true);
  return quantized_matmul(x, x, x, x, true, 64, 4, mode, other, s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 3, findings)

    def test_call_without_the_stream_is_reported(self):
        root = ops_cpp("""
array quantized_matmul(array x, array scales, StreamOrDevice s) {
  std::vector<array> inputs = {astype(x, float32), astype(scales, float32, s)};
  auto b = broadcast_arrays(inputs);
  return add(b[0], b[1], s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)
        self.assertTrue(any("astype(x, float32)" in f for f in findings))
        self.assertTrue(any("broadcast_arrays(inputs)" in f for f in findings))

    def test_qualified_core_call_is_checked_and_std_is_not(self):
        root = ops_cpp("""
array f(const array& x, StreamOrDevice s) {
  auto n = std::max(0, 1);
  return mlx::core::add(x, x);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("mlx::core::add(x, x)", findings[0])

    def test_a_device_is_not_the_callers_stream(self):
        root = ops_cpp("""
array f(const array& x, const array& y, StreamOrDevice s) {
  if (to_stream(s).device == Device::gpu) {
    return add(x, y, Device::gpu);
  }
  return add(x, y, to_stream(other));
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)

    def test_operator_overloads_on_arrays_are_reported(self):
        root = ops_cpp("""
array f(const array& a, const std::vector<array>& v, StreamOrDevice s) {
  auto y = add(a, a, s);
  auto p = multiply(a, y, s) * y;
  auto q = a % y;
  auto r = v[0] + a;
  auto t = ~a;
  auto u = a << y;
  return add(p, add(q, add(r, add(t, u, s), s), s), s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 5, findings)
        self.assertTrue(all("operator on array" in f for f in findings))

    def test_declarations_messages_and_shape_math_are_not_operators(self):
        root = ops_cpp("""
array f(const array& a, const array& b, StreamOrDevice s) {
  const array& c = b;
  auto check = [&a](int ax) { return ax < a.ndim(); };
  if (a.ndim() == 0 || a.shape(-1) != b.shape(-1) || a.dtype() == float32) {
    std::ostringstream msg;
    msg << "bad shape " << a.shape() << " and " << b.ndim();
    throw std::invalid_argument(msg.str());
  }
  int n = a.shape()[a.shape().size() - 2] * 2;
  Shape shape(a.ndim(), 1);
  std::vector<array> parts;
  return add(a, c, s);
}
""")
        self.assertEqual(scan(root), [])

    def test_primitive_rules_run_on_the_primitives_stream(self):
        root = core()
        (root / "mlx" / "primitives.cpp").write_text("""
std::vector<array> Thing::vjp(const std::vector<array>& primals) {
  return {zeros_like(primals[0])};
}

std::vector<array> Other::jvp(const std::vector<array>& primals) {
  const auto& s = stream();
  auto n = add(primals[0], primals[0], s);
  return {equal(n, n, stream()), multiply(n, primals[0])};
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)
        self.assertTrue(any("[vjp]" in f and "zeros_like(primals[0])" in f for f in findings))
        self.assertTrue(any("[jvp]" in f and "multiply(n, primals[0])" in f for f in findings))

    def test_implicit_random_key_must_take_the_stream(self):
        root = core()
        (root / "mlx" / "random.cpp").write_text("""
array bits(const std::optional<array>& key_, StreamOrDevice s) {
  auto key = key_ ? *key_ : KeySequence::default_().next();
  return add(key, key, s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("next()", findings[0])

    def test_inline_header_definitions_and_extra_sources_are_scanned(self):
        root = core()
        (root / "mlx" / "extra.h").write_text("""
inline array g(const array& x, StreamOrDevice s = {}) {
  return add(x, x);
}
""")
        (root / "mlx" / "einsum.cpp").write_text("""
array h(const array& x, StreamOrDevice s) {
  return multiply(x, x);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)

    def test_every_stream_parameter_spelling_is_inspected(self):
        root = ops_cpp("""
array f(const array& x, const StreamOrDevice& s) {
  return add(x, x);
}

array g(const array& x, const Stream& stream) {
  return multiply(x, x);
}

array h(const array& x, Stream s) {
  return add(x, x, s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)
        self.assertTrue(any("[f]" in f for f in findings) and any("[g]" in f for f in findings))

    def test_operator_split_across_lines_is_reported(self):
        root = ops_cpp("""
array f(const array& a, StreamOrDevice s) {
  auto y = add(a, a, s);
  return y
      * a;
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("operator on array", findings[0])

    def test_call_result_as_left_operand_is_reported(self):
        root = ops_cpp("""
array f(const array& a, StreamOrDevice s) {
  if (std::isnan(1.0) || std::max(1, 2) > 0) {
    return add(a, a, s);
  }
  return add(a, a, s) << multiply(a, a, s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("add(a, a, s) << multiply(a, a, s)", findings[0])

    def test_local_lambda_shadowing_an_op_is_not_the_op(self):
        root = ops_cpp("""
array f(const array& a, const Stream& stream) {
  auto add = [stream](auto in) { return multiply(in, in, stream); };
  return add(a);
}
""")
        self.assertEqual(scan(root), [])

    def test_a_shadowing_lambda_does_not_hide_the_op_outside_its_scope(self):
        root = ops_cpp("""
array f(const array& a, const Stream& stream) {
  auto b = add(a, a);
  if (a.ndim() > 1) {
    auto add = [stream](auto in) { return multiply(in, in, stream); };
    b = add(b);
  }
  return add(b, b);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 2, findings)
        self.assertTrue(all("add(" in f for f in findings))

    def test_lexer_keeps_code_after_a_string_holding_comment_markers(self):
        # A "//" inside a string is not a comment, so the call after it on the
        # same line is still checked (#2028 audit carry).
        root = ops_cpp("""
array f(const array& x, StreamOrDevice s) {
  auto msg = "see // and /* here"; auto y = astype(x, float32);
  return add(y, x, s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)
        self.assertIn("astype(x, float32)", findings[0])

    def test_lexer_keeps_code_after_a_comment_holding_a_quote(self):
        root = ops_cpp("""
array f(const array& x, StreamOrDevice s) {
  // the caller's "stream
  auto y = astype(x, float32);
  return add(y, x, s);
}
""")
        findings = scan(root)
        self.assertEqual(len(findings), 1, findings)

    def test_lexer_blanks_raw_strings_and_char_literals(self):
        text = 'auto a = R"x(astype(y, f))x"; char q = \'"\'; int n = 1\'000; f(z);'
        stripped = strip_comments_and_strings(text)
        self.assertEqual(len(stripped), len(text))
        self.assertNotIn("astype", stripped)
        self.assertIn("1'000", stripped)
        self.assertIn("f(z);", stripped)

    def test_missing_required_file_fails_closed(self):
        root = core()
        (root / "mlx" / "primitives.cpp").unlink()
        with self.assertRaises(CoreRootError):
            scan(root)

    def test_cli_exit_codes(self):
        clean = ops_cpp("array f(const array& x, StreamOrDevice s) {\n  return add(x, x, s);\n}\n")
        dirty = ops_cpp("array f(const array& x, StreamOrDevice s) {\n  return add(x, x);\n}\n")
        run = lambda root: subprocess.run(
            [sys.executable, "-I", str(SCRIPT), str(root)], capture_output=True, text=True
        )
        self.assertEqual(run(clean).returncode, 0)
        result = run(dirty)
        self.assertEqual(result.returncode, 1)
        self.assertIn("call off the caller's stream: add(x, x)", result.stdout)
        self.assertEqual(run(Path(tempfile.mkdtemp())).returncode, 2)


if __name__ == "__main__":
    unittest.main()
