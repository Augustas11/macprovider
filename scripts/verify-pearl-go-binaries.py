#!/usr/bin/env python3
"""Verify Pearl Go binaries against the coordinator module toolchain contract."""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
COORDINATOR_GO_MOD = ROOT / "phase4-coordinator" / "go.mod"
GO_DIRECTIVE_RE = re.compile(r"(?m)^go ([0-9]+\.[0-9]+(?:\.[0-9]+)?)$")
EXPECTED_MAIN_PACKAGES = {
    "coordinator-linux-amd64": "github.com/augstar/macprovider-coordinator/cmd/coordinator",
    "coordinator-cli-linux-amd64": "github.com/augstar/macprovider-coordinator/cmd/coordinator-cli",
    "gateway-linux-amd64": "github.com/augstar/macprovider-gateway/cmd/gateway",
}


def expected_go_version() -> str:
    match = GO_DIRECTIVE_RE.search(COORDINATOR_GO_MOD.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError("phase4-coordinator/go.mod lacks a valid Go directive")
    return f"go{match.group(1)}"


def repository_head() -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise ValueError("cannot resolve reviewed repository HEAD") from exc
    head = result.stdout.strip()
    if re.fullmatch(r"[0-9a-f]{40}", head) is None:
        raise ValueError("reviewed repository HEAD is not a full lowercase commit hash")
    return head


def expected_revision() -> str:
    revision = os.environ.get("EXPECTED_REVISION", "")
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("EXPECTED_REVISION must be a full lowercase commit hash")
    head = repository_head()
    if head != revision:
        raise ValueError(f"reviewed repository HEAD {head} does not match {revision}")
    return revision


def verify_build_info(
    binary: pathlib.Path, output: str, expected: str, revision: str
) -> None:
    expected_package = EXPECTED_MAIN_PACKAGES.get(binary.name)
    if expected_package is None:
        raise ValueError(f"{binary}: unexpected Pearl binary role")
    lines = output.splitlines()
    if not lines or lines[0].rsplit(": ", 1)[-1] != expected:
        actual = lines[0].rsplit(": ", 1)[-1] if lines else "missing"
        raise ValueError(f"{binary}: compiler version {actual!r}, expected {expected!r}")

    packages = [
        line.strip().split("\t", 1)[1]
        for line in lines[1:]
        if line.strip().startswith("path\t")
    ]
    if packages != [expected_package]:
        raise ValueError(f"{binary}: main package {packages!r}, expected {expected_package!r}")
    required_settings = {
        "GOOS": "linux",
        "GOARCH": "amd64",
        "vcs": "git",
        "vcs.revision": revision,
        "vcs.modified": "false",
    }
    for key, expected_value in required_settings.items():
        values = [
            line.strip().split("=", 1)[1]
            for line in lines[1:]
            if line.strip().startswith(f"build\t{key}=")
        ]
        if values != [expected_value]:
            raise ValueError(
                f"{binary}: build setting {key} is {values!r}, expected {[expected_value]!r}"
            )


def verify_binary(binary: pathlib.Path, expected: str, revision: str) -> None:
    if not binary.is_file():
        raise ValueError(f"{binary}: binary is missing")
    try:
        result = subprocess.run(
            ["go", "version", "-m", str(binary)],
            check=True,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        raise ValueError(f"{binary}: cannot read Go build information") from exc
    verify_build_info(binary, result.stdout, expected, revision)


def self_test() -> None:
    expected = expected_go_version()
    revision = repository_head()
    previous_revision = os.environ.get("EXPECTED_REVISION")
    try:
        os.environ["EXPECTED_REVISION"] = revision
        if expected_revision() != revision:
            raise AssertionError("reviewed revision binding changed unexpectedly")
        os.environ["EXPECTED_REVISION"] = "0" * 40
        try:
            expected_revision()
        except ValueError:
            pass
        else:
            raise AssertionError("mismatched reviewed revision was accepted")
    finally:
        if previous_revision is None:
            os.environ.pop("EXPECTED_REVISION", None)
        else:
            os.environ["EXPECTED_REVISION"] = previous_revision
    binary = pathlib.Path("coordinator-linux-amd64")
    valid = (
        f"{binary}: {expected}\n"
        f"\tpath\t{EXPECTED_MAIN_PACKAGES[binary.name]}\n"
        "\tbuild\tGOOS=linux\n"
        "\tbuild\tGOARCH=amd64\n"
        "\tbuild\tvcs=git\n"
        f"\tbuild\tvcs.revision={revision}\n"
        "\tbuild\tvcs.modified=false\n"
    )
    verify_build_info(binary, valid, expected, revision)
    for invalid in (
        valid.replace(expected, "go0.0.0", 1),
        valid.replace("\tbuild\tGOOS=linux\n", "", 1),
        valid.replace("\tbuild\tGOARCH=amd64\n", "", 1),
        valid.replace("/cmd/coordinator\n", "/cmd/coordinator-cli\n", 1),
        valid.replace(revision, "0" * 40, 1),
        valid.replace("vcs.modified=false", "vcs.modified=true", 1),
        valid + f"\tbuild\tvcs.revision={revision}\n",
        valid + "\tbuild\tvcs.modified=true\n",
    ):
        try:
            verify_build_info(binary, invalid, expected, revision)
        except ValueError:
            continue
        raise AssertionError("invalid Pearl Go build information was accepted")


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        self_test()
        print("Pearl Go binary verifier self-test passed")
        return 0
    if not argv:
        print("usage: verify-pearl-go-binaries.py BINARY [BINARY ...]", file=sys.stderr)
        return 2

    basenames = [pathlib.Path(value).name for value in argv]
    if basenames != list(EXPECTED_MAIN_PACKAGES):
        print(
            "verify-pearl-go-binaries: expected coordinator, coordinator-cli, and gateway in order",
            file=sys.stderr,
        )
        return 2

    try:
        expected = expected_go_version()
        revision = expected_revision()
        for value in argv:
            verify_binary(pathlib.Path(value), expected, revision)
    except ValueError as exc:
        print(f"verify-pearl-go-binaries: {exc}", file=sys.stderr)
        return 1

    print(f"verified {len(argv)} Pearl Go binaries with {expected} at {revision}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
