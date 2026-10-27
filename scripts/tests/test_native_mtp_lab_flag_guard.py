from __future__ import annotations

import ast
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
# These exact lab-only surfaces build the isolated measurement binary and test
# its fixed commands. Release, signing and CI entry points remain scanned.
LAB_BUILD_SURFACES = {
    ROOT / "scripts" / "ops" / "studio-mtp-measurement.py",
    ROOT / "scripts" / "tests" / "test_studio_mtp_measurement.py",
}
# These proof-only files quote the forbidden flag to verify that production
# inputs exclude it; they never invoke a release, signing, or CI build.
LAB_FLAG_REFERENCE_SURFACES = {
    ROOT / "scripts" / "native_mtp_source_equivalence.py",
    ROOT / "scripts" / "tests" / "test_native_mtp_journey_lab_steps.py",
    ROOT / "scripts" / "tests" / "test_native_mtp_source_equivalence.py",
}
CLI_SOURCES = ROOT / "phase3-binary" / "Sources" / "macprovider-cli"
LAB_GUARD = "DEBUG || " + FORBIDDEN
QUALIFICATION_GUARD = LAB_GUARD + " || MACPROVIDER_SIGNED_QUALIFICATION"
SIGNED_ONLY_GUARD = "!DEBUG && !" + FORBIDDEN
QUALIFICATION_SYMBOLS = {
    "NativeMTPHardwareE2ECommand", "NativeMTPBenchCommand", "NativeMTPRequestShapeReplayCommand",
    "NativeMTPLabDecodeOutputCap", "NativeMTPLabCommittedTokenTimingObserver",
    "NativeMTPLabConversationCacheObserver", "installLabNativeMTPConversationCacheObserver",
    "labNativeMTPConversationCacheObserver", "recordLabNativeMTPConversationCacheBegin",
    "installLabNativeMTPDecodeOutputCap", "installLabNativeMTPCommitTimingObserver",
}
# Lab-only command types: every declaration and every reference, including
# the subcommand registration, must sit inside the lab guard so a plain
# release build compiles none of them.
LAB_COMMAND_TYPES = (
    "NativeMTPHardwareE2ECommand",
    "NativeMTPBenchCommand",
    "NativeMTPJourneyE2ECommand",
    "NativeMTPRequestShapeReplayCommand",
)
# Lab-only hooks that change decode inputs or bypass serving: every
# declaration and reference must also sit inside the lab guard.
LAB_HOOK_SYMBOLS = (
    "NativeMTPLabProposalOverride",
    "NativeMTPLabDecodeOutputCap",
    "NativeMTPLabCommittedTokenTimingObserver",
    "NativeMTPLabConversationCacheObserver",
    "installLabNativeMTPConversationCacheObserver",
    "labNativeMTPConversationCacheObserver",
    "recordLabNativeMTPConversationCacheBegin",
    "installLabNativeMTPDecodeOutputCap",
    "installLabNativeMTPCommitTimingObserver",
    "installLabNativeMTPProposalOverride",
    "labNativeMTPProposalOverride",
    "labTokenProbe",
    "readLabStaticFeedOverride",
    "labStaticFeedOriginKey",
    "labNativeMTPSourceCommit",
)


def _unguarded_references(text: str, names: tuple[str, ...], *, qualification_helpers: bool = False) -> list[int]:
    """Line numbers naming `names` outside an active `#if LAB_GUARD` branch."""
    stack: list[str | None] = []  # Active exact compile guards only.
    offenders: list[int] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped[len("#if "):].strip())
            continue
        if stripped.startswith("#elseif") or stripped == "#else":
            if stack:
                stack[-1] = None
            continue
        if stripped == "#endif":
            if stack:
                stack.pop()
            continue
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for name in names:
            if name not in line:
                continue
            guarded = LAB_GUARD in stack or (name in QUALIFICATION_SYMBOLS and qualification_helpers)
            if not guarded:
                offenders.append(lineno)
                break
    return offenders


def _is_process_launch(call: ast.Call, subprocess_modules: set[str], os_modules: set[str], direct_launchers: set[str]) -> bool:
    function = call.func
    if isinstance(function, ast.Name):
        return function.id in direct_launchers
    return isinstance(function, ast.Attribute) and isinstance(function.value, ast.Name) and (
        (function.value.id in subprocess_modules and function.attr in {"run", "call", "check_call", "check_output", "Popen"})
        or (function.value.id in os_modules and (function.attr in {"system", "popen"} or function.attr.startswith(("exec", "spawn"))))
    )


def _expanded_argv(argument: ast.expr, assignments: dict[str, ast.expr]) -> list[ast.expr] | None:
    if isinstance(argument, ast.Name):
        return _expanded_argv(assignments[argument.id], assignments) if argument.id == "prefix" and argument.id in assignments else None
    if isinstance(argument, ast.BinOp) and isinstance(argument.op, ast.Add):
        left = _expanded_argv(argument.left, assignments)
        right = _expanded_argv(argument.right, assignments)
        return left + right if left is not None and right is not None else None
    return list(argument.elts) if isinstance(argument, (ast.List, ast.Tuple)) else None


def _constant(element: ast.expr) -> str | None:
    return element.value if isinstance(element, ast.Constant) and isinstance(element.value, str) else None


def _known_git_helper_calls(tree: ast.AST) -> bool:
    allowed = {"init", "fetch", "ls-tree", "diff"}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name) or node.func.id != "git":
            continue
        verb = _constant(node.args[0]) if node.args else None
        if verb not in allowed:
            return False
        if verb == "init" and [_constant(arg) for arg in node.args] != ["init", "--bare", "-q"]:
            return False
        if verb == "fetch" and [_constant(arg) for arg in node.args[:3]] != ["fetch", "--no-tags", "--depth=1"]:
            return False
        if verb == "ls-tree" and (len(node.args) < 4 or _constant(node.args[1]) != "-r" or _constant(node.args[3]) != "--"):
            return False
        if verb == "diff" and [_constant(arg) for arg in node.args[:2]] != ["diff", "--name-only"]:
            return False
    return True


def _known_git_command(argument: ast.expr, assignments: dict[str, ast.expr], tree: ast.AST) -> bool:
    argv = _expanded_argv(argument, assignments)
    if not argv or _constant(argv[0]) != "git":
        return False
    index = 1
    if index < len(argv) and _constant(argv[index]) == "-C":
        index += 2
    if index == len(argv) - 1 and isinstance(argv[index], ast.Starred) and isinstance(argv[index].value, ast.Name) and argv[index].value.id == "arguments":
        return _known_git_helper_calls(tree)
    verb = _constant(argv[index]) if index < len(argv) else None
    return verb in {"show", "ls-tree"} and not any(isinstance(arg, ast.Starred) for arg in argv)


def _proof_surface_uses_only_literal_git(text: str) -> bool:
    """Allow quoted flag proofs only when every process launch is a git argv."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return False
    subprocess_modules = {"subprocess"}
    os_modules = {"os"}
    direct_launchers: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "subprocess":
                    subprocess_modules.add(alias.asname or alias.name)
                elif alias.name == "os":
                    os_modules.add(alias.asname or alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module in {"subprocess", "os"}:
            for alias in node.names:
                if node.module == "subprocess" and alias.name in {"run", "call", "check_call", "check_output", "Popen"}:
                    direct_launchers.add(alias.asname or alias.name)
                elif node.module == "os" and (alias.name in {"system", "popen"} or alias.name.startswith(("exec", "spawn"))):
                    direct_launchers.add(alias.asname or alias.name)
    assignments = {
        target.id: node.value
        for node in ast.walk(tree) if isinstance(node, (ast.Assign, ast.AnnAssign))
        for target in (node.targets if isinstance(node, ast.Assign) else (node.target,))
        if isinstance(target, ast.Name) and node.value is not None
    }
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not _is_process_launch(node, subprocess_modules, os_modules, direct_launchers):
            continue
        if not node.args or not _known_git_command(node.args[0], assignments, tree):
            return False
        if any(keyword.arg in {"shell", "executable"} for keyword in node.keywords):
            return False
    return True


def _permitted_flag_reference(path: Path, text: str) -> bool:
    if path in LAB_BUILD_SURFACES:
        return True
    return path in LAB_FLAG_REFERENCE_SURFACES and _proof_surface_uses_only_literal_git(text)


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
                if (FORBIDDEN in text or FORBIDDEN_DEFINE in text) and not _permitted_flag_reference(path, text):
                    offenders.append(str(path.relative_to(ROOT)))

        self.assertEqual(
            [],
            offenders,
            "Lab-only native MTP harness compile flag must not be passed by release, signing, or CI scripts.",
        )

    def test_proof_reference_rejects_non_git_or_dynamic_process_launch(self) -> None:
        self.assertTrue(_proof_surface_uses_only_literal_git('import subprocess\nsubprocess.run(["git", "show", "HEAD:README.md"])\n'))
        self.assertFalse(_proof_surface_uses_only_literal_git('import subprocess\nsubprocess.run(["swift", "build"])\n'))
        self.assertFalse(_proof_surface_uses_only_literal_git('import subprocess\ncommand = ["git", "status"]\nsubprocess.run(command)\n'))
        self.assertFalse(_proof_surface_uses_only_literal_git('import subprocess\nsubprocess.run(["git", "-c", "alias.show=!xcodebuild", "show"])\n'))
        self.assertFalse(_proof_surface_uses_only_literal_git('import subprocess\nsubprocess.run(["git", "config", "core.hooksPath", "/tmp"])\n'))
        proof_path = ROOT / "scripts" / "native_mtp_source_equivalence.py"
        self.assertFalse(_permitted_flag_reference(proof_path, 'import subprocess\nsubprocess.run(["swift", "-D" + FORBIDDEN])\n'))
        self.assertFalse(_permitted_flag_reference(proof_path, 'import subprocess\ncommand = ["swift", "-D" + FORBIDDEN]\nsubprocess.run(command)\n'))

    def test_unknown_flag_reference_path_is_not_permitted(self) -> None:
        self.assertFalse(_permitted_flag_reference(ROOT / "scripts" / "new-proof.py", FORBIDDEN))

    def test_qualification_helpers_do_not_expose_lab_serving_mutations(self) -> None:
        offenders: list[str] = []
        declared: set[str] = set()
        for path in sorted(CLI_SOURCES.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            for name in LAB_COMMAND_TYPES:
                if f"struct {name}" in text:
                    declared.add(name)
            for lineno in _unguarded_references(text, LAB_COMMAND_TYPES + LAB_HOOK_SYMBOLS, qualification_helpers=True):
                offenders.append(f"{path.relative_to(ROOT)}:{lineno}")
        self.assertEqual(set(LAB_COMMAND_TYPES), declared)
        self.assertEqual([], offenders, "Lab-only native MTP commands must be declared and registered only under the lab guard.")

    def test_signed_entry_has_only_isolated_qualification_children(self) -> None:
        source = (CLI_SOURCES / "MacProviderCLI.swift").read_text()
        lab_registration = source[source.index("private static func labSubcommands"):source.index("struct LifecycleStateCommand")]
        self.assertIn("#if " + LAB_GUARD, lab_registration)
        self.assertNotIn("MACPROVIDER_SIGNED_QUALIFICATION", lab_registration)
        qualification = (CLI_SOURCES / "NativeMTPQualificationCommand.swift").read_text()
        self.assertIn("NativeMTPSignedAcceptanceCommand.self, NativeMTPSignedBenchCommand.self, NativeMTPSignedReplayCommand.self", qualification)
        self.assertNotIn("ServeCommand.self", qualification)
        self.assertIn("@TaskLocal static var identity", qualification)
        self.assertIn("SecCodeCopySelf", qualification)
        self.assertIn("SecStaticCodeCheckValidity", qualification)
        self.assertIn("initial.st_ino == final.st_ino", qualification)
        self.assertIn("flags.uint32Value & 2 == 0", qualification)

    def test_guard_scanner_flags_unguarded_registration(self) -> None:
        guarded = f"#if {LAB_GUARD}\nlet a = NativeMTPBenchCommand.self\n#endif\n"
        else_branch = f"#if {LAB_GUARD}\n#else\nlet a = NativeMTPBenchCommand.self\n#endif\n"
        bare = "subcommands: [NativeMTPBenchCommand.self]\n"
        self.assertEqual([], _unguarded_references(guarded, LAB_COMMAND_TYPES))
        self.assertEqual([3], _unguarded_references(else_branch, LAB_COMMAND_TYPES))
        self.assertEqual([1], _unguarded_references(bare, LAB_COMMAND_TYPES))


if __name__ == "__main__":
    unittest.main()
