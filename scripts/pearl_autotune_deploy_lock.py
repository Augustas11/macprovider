#!/usr/bin/env python3
"""Validate Pearl coordinator-deploy lock files.

Matches the deploy-pearl-vps.sh contract: existing regular files, root:root,
0600, nlink==1, opened with O_NOFOLLOW. Does not create lock files and does
not chmod /run/lock. flock stays in the caller so the lease is held across
the bash mutation window.
"""

from __future__ import annotations

import os
import stat
import sys

UPDATER_LOCK = "/run/lock/macprovider-pearl-updater.lock"
COORDINATOR_LOCK = "/opt/macprovider/.coordinator-deploy.lock"
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def validate_lock_file(path: str, *, require_root: bool = True) -> None:
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW)
    except FileNotFoundError as exc:
        raise SystemExit(f"missing lock file: {path}") from exc
    except OSError as exc:
        raise SystemExit(f"cannot open lock file {path}: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SystemExit(f"unsafe lock (not a regular file): {path}")
        if require_root and (info.st_uid != 0 or info.st_gid != 0):
            raise SystemExit(f"unsafe lock (not root:root): {path}")
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise SystemExit(f"unsafe lock (mode not 0600): {path}")
        if info.st_nlink != 1:
            raise SystemExit(f"unsafe lock (nlink != 1): {path}")
    finally:
        os.close(fd)


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["validate"]:
        validate_lock_file(UPDATER_LOCK)
        validate_lock_file(COORDINATOR_LOCK)
        return 0
    if len(args) >= 1 and args[0] == "validate-path":
        require_root = True
        paths = args[1:]
        if paths and paths[0] == "--no-require-root":
            require_root = False
            paths = paths[1:]
        if len(paths) != 1:
            raise SystemExit("usage: validate-path [--no-require-root] PATH")
        validate_lock_file(paths[0], require_root=require_root)
        return 0
    raise SystemExit("usage: pearl_autotune_deploy_lock.py validate | validate-path [--no-require-root] PATH")


if __name__ == "__main__":
    sys.exit(main())
