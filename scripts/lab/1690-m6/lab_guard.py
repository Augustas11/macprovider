#!/usr/bin/env python3
"""Refuse a lab directory outside the lab root before anything touches it.

The lab scripts move, delete and write keys and configs under LAB, so LAB must
be an absolute path with no `.`/`..` components that resolves to itself (no
symlink anywhere on it) and lies within LAB_ROOT (default
/Users/a1/lab-1690-m6, itself absolute and symlink-free).

  lab_guard.py [--strict] <LAB>   print the canonical LAB, or exit 2

--strict requires LAB strictly beneath the root (a caller that moves LAB
aside must never move the root itself).
"""
import os
import sys

DEFAULT_ROOT = "/Users/a1/lab-1690-m6"


def check(lab, root=None, strict=False):
    """Return the canonical LAB, or raise ValueError."""
    root = root if root is not None else os.environ.get("LAB_ROOT", DEFAULT_ROOT)
    for name, path in (("LAB_ROOT", root), ("LAB", lab)):
        if not path or not os.path.isabs(path):
            raise ValueError(f"{name} must be an absolute path: {path!r}")
        if any(part in (".", "..") for part in path.split("/")):
            raise ValueError(f"{name} must not contain . or .. components: {path!r}")
    root_n, lab_n = os.path.normpath(root), os.path.normpath(lab)
    if root_n == "/":
        raise ValueError("LAB_ROOT must not be /")
    if os.path.realpath(root_n) != root_n:
        raise ValueError(f"LAB_ROOT must not traverse a symlink: {root_n}")
    if os.path.realpath(lab_n) != lab_n:
        raise ValueError(f"LAB must not traverse a symlink: {lab_n}")
    inside = lab_n.startswith(root_n + os.sep)
    if not inside and (strict or lab_n != root_n):
        raise ValueError(f"LAB must be {'strictly ' if strict else ''}under {root_n}: {lab_n}")
    return lab_n


def main(argv):
    args = argv[1:]
    strict = bool(args) and args[0] == "--strict"
    if strict:
        args = args[1:]
    if len(args) != 1:
        print("usage: lab_guard.py [--strict] <LAB>", file=sys.stderr)
        return 2
    try:
        print(check(args[0], strict=strict))
    except ValueError as err:
        print(f"refusing: {err}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
