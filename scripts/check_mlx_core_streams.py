#!/usr/bin/env python3
"""Fail when MLX core runs an internal op off the caller's stream.

mlx-swift runs every op on its own pooled GPU stream. An internal call inside
a stream-taking MLX core op that omits the stream argument, passes a device
instead of the caller's stream, or uses a C++ operator overload such as
``a * b`` on arrays, runs on the thread's default stream instead: a second
Metal queue, a cross-queue event wait and a separate command-buffer submit
for every such op (#2028: gpt-oss-20b decode lost 30%).

The check reads every top-level core header and source (``mlx/*.h``,
``mlx/*.cpp``; the backends are out of scope). It collects the names of
functions declared with a ``StreamOrDevice`` parameter and the array operator
overloads the headers declare. It then inspects every function body that has
a caller stream, meaning a ``StreamOrDevice`` or ``Stream`` parameter (by value
or reference) or, for primitive
rules (``Class::vjp``/``jvp``/``vmap``, or any body using ``stream()``), the
primitive's ``stream()``, and reports:

- a call to one of those functions (unqualified or ``mlx::core::``-style
  qualified) whose last argument is not the caller's stream or an alias of
  it;
- an operator overload applied to an array value (a parameter or local of
  type ``array`` or ``std::vector<array>``, an element of one, or the result
  of a stream-taking call).

It fails closed: a missing required file, no stream-taking declarations, no
operator overloads, or no inspected function is an error.

Usage: check_mlx_core_streams.py <core-root>   (the directory holding mlx/)
Exit 0 when clean, 1 with one line per finding, 2 on an unusable core root.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REQUIRED = (
    "mlx/ops.h",
    "mlx/ops.cpp",
    "mlx/primitives.cpp",
    "mlx/fast.h",
    "mlx/fast.cpp",
    "mlx/random.h",
    "mlx/random.cpp",
    "mlx/linalg.cpp",
    "mlx/fft.cpp",
)
# Namespace qualifiers that still name a core op (mlx::core::split, random::split).
CORE_QUALIFIERS = {"mlx", "core", "random", "fast", "linalg", "fft", "einsum", "detail"}
# Optional core namespace prefix on an op name (never std::).
CORE_PREFIX = r"(?:(?:mlx|core|random|fast|linalg|fft|einsum|detail)::)*"
# KeySequence::next is called as a method and takes the caller's stream.
METHOD_OPS = ("next",)


class CoreRootError(Exception):
    pass


def strip_comments_and_strings(text: str) -> str:
    """Blank comments and string literals, keeping offsets and line numbers."""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    text = re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)
    return re.sub(r'"(?:\\.|[^"\\\n])*"', lambda m: '"' + " " * (len(m.group(0)) - 2) + '"', text)


def matching(text: str, open_index: int, opener: str, closer: str) -> int:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index
    return -1


def enclosing_block_end(text: str, index: int) -> int:
    """Offset of the `}` closing the innermost block that contains `index`."""
    depth = 0
    for position in range(index, len(text)):
        if text[position] == "{":
            depth += 1
        elif text[position] == "}":
            if depth == 0:
                return position
            depth -= 1
    return len(text)


def split_arguments(text: str) -> list[str]:
    arguments, depth, current = [], 0, ""
    for char in text:
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        if char == "," and depth == 0:
            arguments.append(current.strip())
            current = ""
        else:
            current += char
    if current.strip():
        arguments.append(current.strip())
    return arguments


def core_files(root: Path) -> tuple[list[Path], list[Path]]:
    missing = [name for name in REQUIRED if not (root / name).is_file()]
    if missing:
        raise CoreRootError(f"{root}: required core files missing: {', '.join(missing)}")
    headers = sorted((root / "mlx").glob("*.h"))
    sources = sorted((root / "mlx").glob("*.cpp"))
    return headers, sources


def declarations(headers: list[Path]) -> tuple[set[str], set[str]]:
    """Stream-taking function names and array operator overload symbols."""
    names: set[str] = set()
    operators: set[str] = set()
    for header in headers:
        text = strip_comments_and_strings(header.read_text())
        for match in re.finditer(r"\b([a-z_][a-z0-9_]*)\s*\(([^;{]*(?:\{\}[^;{]*)*)\)\s*(?:const\s*)?[;{]", text, re.S):
            if "StreamOrDevice" in match.group(2):
                names.add(match.group(1))
        for match in re.finditer(r"\boperator\s*([-+*/%^&|~!<>=]{1,2})\s*\(([^)]*)\)", text):
            if "array" in match.group(2):
                operators.add(match.group(1))
    names.discard("to_stream")
    operators.discard("=")
    return names, operators


def operator_regex(operators: set[str]) -> str:
    parts = []
    for op in sorted(operators, key=len, reverse=True):
        escaped = re.escape(op)
        # Never part of ->, ++, --, <<=, >>=, ==, !=, <=, >= when op is shorter.
        if op in ("-", "+"):
            escaped += r"(?![-+>=])"
        elif op in ("<", ">", "&", "|", "!", "^", "%", "*", "/"):
            escaped += r"(?![=" + re.escape(op) + r"])" if op in ("<", ">", "&", "|") else r"(?!=)"
        parts.append(escaped)
    return "(?:" + "|".join(parts) + ")"


def function_bodies(text: str):
    """Yield (name, params, body_start, body, is_primitive_rule) per definition."""
    for definition in re.finditer(r"(?:^|\n)[ \t]*[A-Za-z_][\w:<>,\s*&]*?\b(?:\w+::)*([a-z_][a-z0-9_]*)\s*\(", text):
        open_paren = definition.end() - 1
        close_paren = matching(text, open_paren, "(", ")")
        if close_paren < 0:
            continue
        tail = text[close_paren + 1 : close_paren + 80]
        if not re.match(r"\s*(?:const\s*)?(?:override\s*)?(?:->\s*[\w:<>]+\s*)?\{", tail):
            continue
        body_start = text.index("{", close_paren)
        body_end = matching(text, body_start, "{", "}")
        if body_end < 0:
            continue
        is_rule = re.search(r"\w::(?:vjp|jvp|vmap)\s*\($", definition.group(0)) is not None
        yield definition.group(1), text[open_paren + 1 : close_paren], body_start, text[body_start : body_end + 1], is_rule


def scan_text(source: str, text: str, ops: set[str], operators: set[str]) -> tuple[list[str], int]:
    text = "\n" + strip_comments_and_strings(text)
    findings: list[str] = []
    inspected = 0
    op_names = "|".join(sorted(ops | set(METHOD_OPS), key=len, reverse=True))
    call_pattern = re.compile(r"(?<![\w.>])((?:\w+::)*)(" + op_names + r")\s*\(|(?<=\.)(" + "|".join(METHOD_OPS) + r")\s*\(")
    stream_call_names = "|".join(sorted(ops, key=len, reverse=True))
    op_alt = operator_regex(operators)
    shift_ops = {o for o in operators if o in ("<<", ">>")}
    for name, params, body_start, body, is_rule in function_bodies(text):
        parameter = re.search(r"\b(?:StreamOrDevice|Stream)\s*(?:const\s*)?&?\s*(\w+)\s*(?:=|,|$|/\*)", params.strip())
        if parameter:
            callers = {parameter.group(1)}
        elif is_rule or re.search(r"(?<![\w.>])stream\s*\(\s*\)", body):
            # Primitive rules (Class::vjp/jvp/vmap) run on the primitive's stream().
            callers = set()
        else:
            continue
        inspected += 1
        for alias in re.finditer(r"(?:auto|Stream|StreamOrDevice)\s*&?\s*(\w+)\s*=\s*(?:to_stream\(\s*(\w+)\s*\)|stream\(\)|(\w+)\s*;)", body):
            source_name = alias.group(2) or alias.group(3)
            if alias.group(0).rstrip().endswith("stream()") or source_name in callers:
                callers.add(alias.group(1))
        caller_names = "|".join(map(re.escape, sorted(callers))) or r"(?!x)x"
        stream_argument = re.compile(r"^(?:" + caller_names + r"|to_stream\(\s*(?:" + caller_names + r")\s*\)|stream\(\))$")
        first_line = text[:body_start].count("\n")

        # A local lambda or std::function that shadows an op name
        # (auto expand_dims = [stream](...)) is not the op, but only where C++
        # sees it: after its declaration, to the end of its enclosing block.
        shadows = []
        for binding in re.finditer(r"\bauto\s+(\w+)\s*=\s*\[|\bstd::function<[^;]*?>\s+(\w+)\s*=", body):
            block_end = enclosing_block_end(body, binding.start())
            shadows.append((binding.group(1) or binding.group(2), binding.end(), block_end))
        for call in call_pattern.finditer(body):
            qualifier = call.group(1) or ""
            if not qualifier and any(
                call.group(2) == shadow and start <= call.start() < end for shadow, start, end in shadows
            ):
                continue
            if qualifier and not set(filter(None, qualifier.split("::"))) <= CORE_QUALIFIERS:
                continue
            preceding = body[: call.start()].rstrip()
            # A type before the name is a declaration (Shape shape(...), array x(...)).
            if re.search(r"[A-Za-z_][\w:<>]*\s*[&*]?$", preceding) and not re.search(r"\b(?:return|else|case)$", preceding):
                continue
            open_index = call.end() - 1
            close_index = matching(body, open_index, "(", ")")
            arguments = split_arguments(body[open_index + 1 : close_index])
            if arguments and stream_argument.match(arguments[-1]):
                continue
            line = first_line + body[: call.start()].count("\n")
            snippet = " ".join(body[call.start() : close_index + 1].split())[:100]
            findings.append(f"{source}:{line}: [{name}] call off the caller's stream: {snippet}")

        arrays = set(re.findall(r"(?:const\s+)?array\s*&?\s+(\w+)", params))
        arrays |= set(re.findall(r"(?:^|[;{(,\s])array\s*&?\s+(\w+)\s*[=;({,)]", body))
        arrays |= set(re.findall(r"auto\s*&?\s+(\w+)\s*=\s*" + CORE_PREFIX + r"(?:" + stream_call_names + r")\s*\(", body))
        vectors = set(re.findall(r"std::vector<array>\s*&?\s+(\w+)", params + "\n" + body))
        arrays.discard("array")
        operand = []
        if arrays:
            operand.append(r"\b(?:" + "|".join(sorted(arrays, key=len, reverse=True)) + r")\b(?!\s*[.(\[:])")
        if vectors:
            operand.append(r"\b(?:" + "|".join(sorted(vectors, key=len, reverse=True)) + r")\s*\[[^\]]*\](?!\s*\.)")
        result = r"" + CORE_PREFIX + r"(?:" + stream_call_names + r")\s*\([^;]*?\)"
        call_open = CORE_PREFIX + r"(?:" + stream_call_names + r")\s*\("
        # A stream-call result as the right operand of any op.
        patterns = [re.compile(r"\)\s*" + op_alt + r"\s*" + call_open)]
        # ...and as the left operand (checked with balanced parentheses below).
        left_call = re.compile(r"(?<![\w.>:])" + call_open)
        followed_by_op = re.compile(r"\s*" + op_alt + r"\s*[\w(~!-]")
        if operand:
            value = "(?:" + "|".join(operand) + ")"
            patterns.append(re.compile(r"(?<![\w.])" + value + r"\s*" + op_alt))
            non_shift = operator_regex(operators - shift_ops)
            patterns.append(re.compile(r"(?<![-+*/%=!<>&|^~])" + non_shift + r"\s*" + value))
            patterns.append(re.compile(r"(?:^|[(,=\s])[~!-]\s*" + value))
        # Scan statements, not physical lines, so an operator split across lines
        # is still one expression.
        for statement in re.finditer(r"[^;{}]+", body):
            line_text = " ".join(statement.group(0).split())
            if not line_text:
                continue
            offset = body[: statement.start() + len(statement.group(0)) - len(statement.group(0).lstrip())].count("\n")
            # Member calls on arrays (a.ndim(), x.shape(0), (*w).size(), s.shape()[i])
            # return integers, dtypes or shapes, not arrays.
            probe = re.sub(r"(?:\(\*\w+\)|\w+(?:\[[^\]]*\])?)(?:\.\w+\([^()]*\)(?:\[[^\]]*\])*)+", "0", line_text)
            probe = re.sub(r"<\s*array\s*>", "", probe)
            # Declarations and captures, not operators: `const array& x`,
            # `auto& in = ...`, `[&a](...)`, `[&shape, &axes]`.
            probe = re.sub(r"\b(?:const\s+)?(?:array|auto|Stream|StreamOrDevice)\s*&", " ", probe)
            probe = re.sub(r"\[[^\]]*\]\s*(?=\()", " ", probe)
            left_operand = False
            for call in left_call.finditer(probe):
                close_index = matching(probe, call.end() - 1, "(", ")")
                if close_index > 0 and followed_by_op.match(probe, close_index + 1):
                    left_operand = True
                    break
            if left_operand or any(pattern.search(probe) for pattern in patterns):
                findings.append(f"{source}:{first_line + offset}: [{name}] operator on array: {line_text[:100]}")
    return findings, inspected


def scan(root: Path) -> list[str]:
    headers, sources = core_files(root)
    ops, operators = declarations(headers)
    if not ops:
        raise CoreRootError(f"{root}: no stream-taking declarations found in mlx/*.h")
    if not operators:
        raise CoreRootError(f"{root}: no array operator overloads found in mlx/*.h")
    findings: list[str] = []
    inspected = 0
    for path in headers + sources:
        found, count = scan_text(str(path.relative_to(root)), path.read_text(), ops, operators)
        findings += found
        inspected += count
    if inspected == 0:
        raise CoreRootError(f"{root}: no stream-taking function bodies found")
    return sorted(set(findings))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: check_mlx_core_streams.py <core-root>", file=sys.stderr)
        return 2
    try:
        findings = scan(Path(argv[1]))
    except CoreRootError as error:
        print(error, file=sys.stderr)
        return 2
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
