#!/usr/bin/env python3
"""Refuse a lab directory outside the lab root before anything touches it.

The lab scripts move, delete and write keys and configs under LAB, so LAB must
be an absolute path with no `.`/`..` components that resolves to itself (no
symlink anywhere on it) and lies within LAB_ROOT (default
/Users/a1/lab-1690-m6, itself absolute and symlink-free).

  lab_guard.py [--strict] <LAB> [<SUBDIR>...]   print the canonical LAB, or exit 2

--strict requires LAB strictly beneath the root (a caller that moves LAB
aside must never move the root itself). Each SUBDIR (relative to LAB) is a
directory the caller writes into: no existing component of LAB/SUBDIR and no
entry directly inside it may be a symlink, so a shell redirect or cp into it
cannot land outside LAB. Python writers use write_file, which opens every
component with O_NOFOLLOW.
"""
import errno
import os
import stat
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


def _rel_parts(rel):
    parts = [p for p in rel.split("/") if p]
    if not parts or os.path.isabs(rel) or any(p in (".", "..") for p in parts):
        raise ValueError(f"write target must be a relative path without . or ..: {rel!r}")
    return parts


def check_tree(lab, rels):
    """Refuse when any existing component of LAB/<rel>, or any entry directly
    inside an existing LAB/<rel> directory, is a symlink. LAB itself must
    already have passed check()."""
    for rel in rels:
        path = lab
        for part in _rel_parts(rel):
            path = os.path.join(path, part)
            if os.path.islink(path):
                raise ValueError(f"write target must not traverse a symlink: {path}")
            if not os.path.lexists(path):
                break
        else:
            if os.path.isdir(path):
                with os.scandir(path) as entries:
                    for entry in entries:
                        if entry.is_symlink():
                            raise ValueError(f"write target must not contain a symlink: {entry.path}")


def write_file(lab, rel, data, mode=0o644):
    """Write data to LAB/<rel>, creating parent directories, without following
    a symlink at any component: each directory is opened relative to its parent
    with O_NOFOLLOW, so a symlink anywhere below LAB fails the write (ELOOP or
    ENOTDIR) instead of redirecting it outside the lab."""
    parts = _rel_parts(rel)
    if isinstance(data, str):
        data = data.encode()
    nofollow_dir = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(lab, nofollow_dir)
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, 0o755, dir_fd=fd)
            except FileExistsError:
                pass
            nxt = os.open(part, nofollow_dir, dir_fd=fd)
            os.close(fd)
            fd = nxt
        # Write a fresh file and rename it over the target, never truncating
        # an existing inode: a hard link planted at the target would otherwise
        # carry the write to its other name outside the lab.
        try:
            existing = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and stat.S_ISLNK(existing.st_mode):
            raise OSError(errno.ELOOP, "write target is a symlink", os.path.join(lab, *parts))
        tmp = f".{parts[-1]}.lab-guard-{os.getpid()}"
        out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode, dir_fd=fd)
        try:
            with os.fdopen(out, "wb") as f:
                os.fchmod(f.fileno(), mode)
                f.write(data)
            os.rename(tmp, parts[-1], src_dir_fd=fd, dst_dir_fd=fd)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=fd)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(fd)
    return os.path.join(lab, *parts)


def main(argv):
    args = argv[1:]
    strict = bool(args) and args[0] == "--strict"
    if strict:
        args = args[1:]
    if not args:
        print("usage: lab_guard.py [--strict] <LAB> [<SUBDIR>...]", file=sys.stderr)
        return 2
    try:
        lab = check(args[0], strict=strict)
        check_tree(lab, args[1:])
        print(lab)
    except ValueError as err:
        print(f"refusing: {err}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
