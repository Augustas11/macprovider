#!/usr/bin/env python3
"""Fail when MLX core runs an internal op off the caller's stream.

mlx-swift runs every op on its own pooled GPU stream. An internal call inside
a stream-taking MLX core op that omits the stream argument (or uses a C++
operator overload such as ``a * b`` on arrays) runs on the thread's default
stream instead: a second Metal queue, a cross-queue event wait and a separate
command-buffer submit for every such op (#2028: gpt-oss-20b decode lost 30%).

The check reads the stream-taking op names from the core headers, then scans
the bodies of stream-taking ops and primitive rules (functions that take a
``StreamOrDevice`` or bind ``auto s = stream()``) for:

- a call to one of those ops whose last argument is not the caller's stream;
- an operator overload applied to an array value.

Usage: check_mlx_core_streams.py <core-root>   (the directory holding mlx/)
Exit 0 when clean, 1 with one line per finding otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HEADERS = (
    "mlx/ops.h",
    "mlx/fast.h",
    "mlx/random.h",
    "mlx/linalg.h",
    "mlx/fft.h",
    "mlx/einsum.h",
)
SOURCES = (
    "mlx/primitives.cpp",
    "mlx/ops.cpp",
    "mlx/fast.cpp",
    "mlx/random.cpp",
    "mlx/linalg.cpp",
    "mlx/fft.cpp",
    "mlx/einsum.cpp",
)
# KeySequence::next is called as a method; it takes a stream like the ops.
METHOD_OPS = ("next",)
OPERATORS = r"(?:\*|/|\+(?!\+)|-(?![->])|@|==|!=|<=|>=|&&|\|\|)"


def strip_comments(text: str) -> str:
    """Blank comments while keeping offsets and line numbers."""
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    return re.sub(r"//[^\n]*", lambda m: " " * len(m.group(0)), text)


def matching_paren(text: str, open_index: int) -> int:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return -1


def matching_brace(text: str, open_index: int) -> int:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return len(text) - 1


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


def stream_taking_ops(root: Path) -> set[str]:
    names: set[str] = set()
    for header in HEADERS:
        path = root / header
        if not path.exists():
            continue
        text = strip_comments(path.read_text())
        for match in re.finditer(r"\b([a-z_][a-z0-9_]*)\s*\(([^;]*?)\)\s*;", text, re.S):
            if "StreamOrDevice" in match.group(2):
                names.add(match.group(1))
    names.discard("to_stream")
    return names


def scan_source(source: str, text: str, ops: set[str]) -> list[str]:
    # A leading newline lets a definition on the file's first line match; line
    # numbers below subtract it back out.
    text = "\n" + strip_comments(text)
    findings: list[str] = []
    op_alternation = "|".join(sorted(ops | set(METHOD_OPS), key=len, reverse=True))
    call_pattern = re.compile(
        r"(?<![\w>:])(?<![^\s(,=!?:{\[])(" + op_alternation + r")\s*\(|(?<=\.)(" + "|".join(METHOD_OPS) + r")\s*\("
    )
    returns_array = "|".join(sorted(ops))
    for definition in re.finditer(r"\n[A-Za-z_][\w:<>,\s*&]*?\b([a-z_][a-z0-9_]*)\s*\(", text):
        open_paren = definition.end() - 1
        close_paren = matching_paren(text, open_paren)
        if close_paren < 0:
            continue
        if not re.match(r"\s*(const\s*)?(override\s*)?\{", text[close_paren + 1 : close_paren + 60]):
            continue
        params = text[open_paren + 1 : close_paren]
        body_start = text.index("{", close_paren)
        stream = re.search(r"StreamOrDevice\s+(\w+)", params)
        if not stream:
            stream = re.search(r"auto\s+(\w+)\s*=\s*stream\(\)", text[body_start : body_start + 400])
            if not stream:
                continue
        body = text[body_start : matching_brace(text, body_start) + 1]
        stream_names = {stream.group(1)}
        for alias in re.finditer(r"auto\s+(\w+)\s*=\s*to_stream\(\s*" + re.escape(stream.group(1)), body):
            stream_names.add(alias.group(1))
        stream_argument = re.compile(
            r"^(?:" + "|".join(map(re.escape, sorted(stream_names)))
            + r"|to_stream\(\s*\w+\s*\)|stream\(\)|Device::cpu|Device::gpu)$"
        )
        first_line = text[:body_start].count("\n")
        name = definition.group(1)

        for call in call_pattern.finditer(body):
            preceding = body[: call.start()].rstrip()
            # A type before the name is a declaration (Shape shape(...), array x(...)).
            if re.search(r"[A-Za-z_][\w:<>]*\s*[&*]?$", preceding) and not re.search(
                r"\b(return|else|case)$", preceding
            ):
                continue
            open_index = call.end() - 1
            close_index = matching_paren(body, open_index)
            arguments = split_arguments(body[open_index + 1 : close_index])
            if arguments and stream_argument.match(arguments[-1]):
                continue
            line = first_line + body[: call.start()].count("\n")
            snippet = " ".join(body[call.start() : close_index + 1].split())[:100]
            findings.append(f"{source}:{line}: [{name}] stream-less call: {snippet}")

        arrays = set(re.findall(r"(?:const\s+)?array\s*&?\s+(\w+)", params))
        arrays |= set(re.findall(r"(?:^|[;{\s])array\s+(\w+)\s*[=;({]", body))
        arrays |= set(re.findall(r"auto\s+(\w+)\s*=\s*(?:" + returns_array + r")\s*\(", body))
        patterns = [re.compile(r"\)\s*" + OPERATORS + r"\s*(?:" + returns_array + r")\s*\(")]
        if arrays:
            identifiers = "|".join(sorted(arrays, key=len, reverse=True))
            patterns += [
                re.compile(r"(?<![\w.])(?:" + identifiers + r")\b\s*" + OPERATORS + r"(?!=)"),
                re.compile(r"(?<![-+*/=!<>&|])" + OPERATORS + r"\s*\b(?:" + identifiers + r")\b(?!\s*[.(\[])"),
            ]
        for offset, line_text in enumerate(body.split("\n")):
            if "<<" in line_text:
                continue
            # Member calls on arrays (a.ndim(), x.shape(0), (*w).size(), s.shape()[i])
            # return integers, dtypes or shapes; replace them so their arithmetic
            # and comparisons are not mistaken for array operator overloads.
            probe = re.sub(r"(?:\(\*\w+\)|\w+)(?:\.\w+\([^()]*\)(?:\[[^\]]*\])*)+", "0", line_text)
            if any(pattern.search(probe) for pattern in patterns):
                findings.append(
                    f"{source}:{first_line + offset}: [{name}] operator on array: {line_text.strip()[:100]}"
                )
    return findings


def scan(root: Path) -> list[str]:
    ops = stream_taking_ops(root)
    if not ops:
        return [f"{root}: no stream-taking ops found in {', '.join(HEADERS)}"]
    findings: list[str] = []
    for source in SOURCES:
        path = root / source
        if path.exists():
            findings += scan_source(source, path.read_text(), ops)
    return sorted(set(findings))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 2
    root = Path(argv[1])
    if not (root / "mlx" / "ops.h").exists():
        print(f"{root}: not an MLX core root (no mlx/ops.h)", file=sys.stderr)
        return 2
    findings = scan(root)
    for finding in findings:
        print(finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
