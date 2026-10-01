from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FORBIDDEN = "MACPROVIDER_" + "LAB_HARNESS"
FORBIDDEN_DEFINE = "D" + FORBIDDEN
SCAN_ROOTS = (
    ROOT / "scripts",
    ROOT / "phase3-binary" / "scripts",
    ROOT / ".github" / "workflows",
)
TEXT_SUFFIXES = {".bash", ".json", ".mjs", ".py", ".sh", ".yaml", ".yml"}
CLI_SOURCES = ROOT / "phase3-binary" / "Sources" / "macprovider-cli"
LAB_GUARD = "DEBUG || " + FORBIDDEN
# Lab-only command types: every declaration and every reference, including
# the subcommand registration, must sit inside the lab guard so a plain
# release build compiles none of them.
LAB_COMMAND_TYPES = ("NativeMTPHardwareE2ECommand", "NativeMTPBenchCommand")


def _unguarded_references(text: str, names: tuple[str, ...]) -> list[int]:
    """Line numbers naming `names` outside an active `#if LAB_GUARD` branch."""
    stack: list[bool] = []  # True while inside the lab-guarded (non-#else) branch
    offenders: list[int] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped[len("#if "):].strip() == LAB_GUARD)
            continue
        if stripped.startswith("#elseif") or stripped == "#else":
            if stack:
                stack[-1] = False
            continue
        if stripped == "#endif":
            if stack:
                stack.pop()
            continue
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        if any(name in line for name in names) and not any(stack):
            offenders.append(lineno)
    return offenders


class NativeMTPLabFlagGuardTests(unittest.TestCase):
    def test_release_signing_ci_surfaces_do_not_pass_lab_harness_flag(self) -> None:
        offenders: list[str] = []
        this_file = Path(__file__).resolve()

        for root in SCAN_ROOTS:
            if not root.exists():
                continue
            for path in sorted(p for p in root.rglob("*") if p.is_file()):
                if path.resolve() == this_file or "__pycache__" in path.parts:
                    continue
                if path.suffix not in TEXT_SUFFIXES and path.name != "Makefile":
                    continue
                try:
                    text = path.read_text(encoding="utf-8")
                except UnicodeDecodeError:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                if FORBIDDEN in text or FORBIDDEN_DEFINE in text:
                    offenders.append(str(path.relative_to(ROOT)))

        self.assertEqual(
            [],
            offenders,
            "Lab-only native MTP harness compile flag must not be passed by release, signing, or CI scripts.",
        )

    def test_lab_commands_and_registration_are_compiled_out_of_release(self) -> None:
        offenders: list[str] = []
        declared: set[str] = set()
        for path in sorted(CLI_SOURCES.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for name in LAB_COMMAND_TYPES:
                if f"struct {name}" in text:
                    declared.add(name)
            for lineno in _unguarded_references(text, LAB_COMMAND_TYPES):
                offenders.append(f"{path.relative_to(ROOT)}:{lineno}")
        self.assertEqual(set(LAB_COMMAND_TYPES), declared)
        self.assertEqual([], offenders, "Lab-only native MTP commands must be declared and registered only under the lab guard.")

    def test_guard_scanner_flags_unguarded_registration(self) -> None:
        guarded = f"#if {LAB_GUARD}\nlet a = NativeMTPBenchCommand.self\n#endif\n"
        else_branch = f"#if {LAB_GUARD}\n#else\nlet a = NativeMTPBenchCommand.self\n#endif\n"
        bare = "subcommands: [NativeMTPBenchCommand.self]\n"
        self.assertEqual([], _unguarded_references(guarded, LAB_COMMAND_TYPES))
        self.assertEqual([3], _unguarded_references(else_branch, LAB_COMMAND_TYPES))
        self.assertEqual([1], _unguarded_references(bare, LAB_COMMAND_TYPES))


if __name__ == "__main__":
    unittest.main()
