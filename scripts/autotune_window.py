#!/usr/bin/env python3
"""Maintain the autotune `.previous-target` compatibility window.

The coordinator (phase4-coordinator/internal/buyer/autotune_feeds.go,
PreviousAutotuneReleaseTargets) reads `<root>/.previous-target`: one
`releases/<id>` per line, blank and `#` lines skipped, at most
MaxCompatiblePreviousReleases (3) entries, and a fourth entry is fail-closed.
This module is the single writer of that file: it computes the window, and
publishes it with the same guarantees as the deploy writer (NOFOLLOW dir fd,
O_EXCL temp, fchown root:<group> 0640, fsync, rename via dir fds).
"""

from __future__ import annotations

import argparse
import grp
import hashlib
import json
import os
import re
import stat
import sys

MAX_ENTRIES = 3
FILE_NAME = ".previous-target"
ENTRY_RE = re.compile(r"releases/[A-Za-z0-9][A-Za-z0-9._-]{0,191}")
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
MAX_FILE_BYTES = 64 * 1024


class WindowError(Exception):
    """A refusal: the window cannot be read, computed, or written safely."""


def validate_entry(entry: str) -> str:
    if not isinstance(entry, str) or ENTRY_RE.fullmatch(entry) is None:
        raise ValueError(f"invalid previous-target entry {entry!r}")
    return entry


def compute_window(existing: list[str], outgoing: str | None, incoming: str) -> list[str]:
    validate_entry(incoming)
    for entry in existing:
        validate_entry(entry)
    if outgoing:
        validate_entry(outgoing)
    if outgoing == incoming:
        return list(existing)
    out: list[str] = []
    for entry in ([outgoing] if outgoing else []) + list(existing):
        if entry == incoming or entry in out:
            continue
        out.append(entry)
    return out[:MAX_ENTRIES]


def parse_entries(text: str) -> list[str]:
    entries = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entries.append(line)
    if len(entries) > MAX_ENTRIES:
        raise WindowError(f"previous-target has {len(entries)} releases; max {MAX_ENTRIES}")
    for entry in entries:
        try:
            validate_entry(entry)
        except ValueError as exc:
            raise WindowError(str(exc)) from exc
    return entries


def _check_owned(info: os.stat_result, required_uid: int, label: str) -> None:
    if info.st_uid != required_uid:
        raise WindowError(f"{label} is owned by uid {info.st_uid}, not {required_uid}")


def open_root(root: str, *, required_uid: int = 0) -> int:
    """Open root by walking from / with no-follow opens.

    Every directory on the path must be owned by root (or required_uid) and not
    group/other-writable, so no less-privileged user can swap a path component
    between validation and the write. A root-owned sticky ancestor (e.g. /tmp)
    is allowed: others cannot rename entries they do not own there. The root
    itself is never allowed to be writable by group/other.
    """
    if not os.path.isabs(root):
        raise WindowError(f"autotune root {root} must be absolute")
    fd = None
    label = "/"
    try:
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW)
        for part in [p for p in root.split("/") if p]:
            _check_trusted_dir(os.fstat(fd), label, required_uid, allow_sticky=True)
            label = os.path.join(label, part)
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=fd)
            except OSError as exc:
                raise WindowError(f"cannot open {label} without following symlinks: {exc}") from exc
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        _check_trusted_dir(info, label, required_uid, allow_sticky=False)
        _check_owned(info, required_uid, f"autotune root {root}")
    except OSError as exc:
        if fd is not None:
            os.close(fd)
        raise WindowError(f"cannot open autotune root {root}: {exc}") from exc
    except WindowError:
        if fd is not None:
            os.close(fd)
        raise
    return fd


def _check_trusted_dir(info: os.stat_result, label: str, required_uid: int, *, allow_sticky: bool) -> None:
    writable = info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    sticky_ok = allow_sticky and info.st_uid == 0 and info.st_mode & stat.S_ISVTX
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid not in (0, required_uid)
        or (writable and not sticky_ok)
    ):
        raise WindowError(f"unsafe directory on autotune root path: {label}")


def read_current(root_fd: int) -> str | None:
    try:
        target = os.readlink("current", dir_fd=root_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise WindowError(f"cannot read current: {exc}") from exc
    if target.startswith("./"):
        target = target[2:]
    return target


def _existing_info(root_fd: int) -> os.stat_result | None:
    try:
        return os.stat(FILE_NAME, dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def read_window(root_fd: int, *, required_uid: int = 0) -> list[str]:
    info = _existing_info(root_fd)
    if info is None:
        return []
    if not stat.S_ISREG(info.st_mode):
        raise WindowError(f"{FILE_NAME} is not a regular file (symlink or special)")
    _check_owned(info, required_uid, FILE_NAME)
    fd = os.open(FILE_NAME, os.O_RDONLY | NOFOLLOW, dir_fd=root_fd)
    try:
        data = os.read(fd, MAX_FILE_BYTES + 1)
    finally:
        os.close(fd)
    if len(data) > MAX_FILE_BYTES:
        raise WindowError(f"{FILE_NAME} is too large")
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise WindowError(f"{FILE_NAME} is not ascii") from exc
    return parse_entries(text)


def _resolve_gid(group: str | int) -> int:
    if isinstance(group, int):
        return group
    return grp.getgrnam(group).gr_gid


def write_window(
    root: str,
    entries: list[str],
    *,
    group: str | int = "macprovider",
    expect_current: str | None = None,
    required_uid: int = 0,
) -> None:
    if len(entries) > MAX_ENTRIES:
        raise WindowError(f"refusing to write {len(entries)} releases; max {MAX_ENTRIES}")
    for entry in entries:
        try:
            validate_entry(entry)
        except ValueError as exc:
            raise WindowError(str(exc)) from exc
    root_fd = open_root(root, required_uid=required_uid)
    try:
        if expect_current is not None:
            live = read_current(root_fd)
            if live != expect_current:
                raise WindowError(f"current is {live!r}, expected {expect_current!r}; not writing")
        info = _existing_info(root_fd)
        if info is not None:
            if not stat.S_ISREG(info.st_mode):
                raise WindowError(f"{FILE_NAME} is not a regular file (symlink or special)")
            _check_owned(info, required_uid, FILE_NAME)
        if not entries:
            if info is not None:
                os.unlink(FILE_NAME, dir_fd=root_fd)
                os.fsync(root_fd)
            return
        gid = _resolve_gid(group)
        tmp_name = f"{FILE_NAME}.tmp.{os.getpid()}"
        fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, 0o640, dir_fd=root_fd)
        try:
            try:
                os.fchown(fd, required_uid, gid)
                os.fchmod(fd, 0o640)
                tinfo = os.fstat(fd)
                if (
                    not stat.S_ISREG(tinfo.st_mode)
                    or tinfo.st_uid != required_uid
                    or tinfo.st_gid != gid
                    or stat.S_IMODE(tinfo.st_mode) != 0o640
                    or tinfo.st_nlink != 1
                ):
                    raise WindowError("unsafe previous-target temp file")
                os.write(fd, "".join(e + "\n" for e in entries).encode("ascii"))
                os.fsync(fd)
            finally:
                os.close(fd)
            os.rename(tmp_name, FILE_NAME, src_dir_fd=root_fd, dst_dir_fd=root_fd)
        except BaseException:
            try:
                os.unlink(tmp_name, dir_fd=root_fd)
            except FileNotFoundError:
                pass
            raise
        os.fsync(root_fd)
    finally:
        os.close(root_fd)


def _plan(args: argparse.Namespace) -> dict:
    validate_entry(args.incoming)
    root_fd = open_root(args.root, required_uid=args.required_uid)
    try:
        current = read_current(root_fd)
        before = read_window(root_fd, required_uid=args.required_uid)
    finally:
        os.close(root_fd)
    outgoing = args.outgoing if args.outgoing is not None else current
    after = compute_window(before, outgoing or None, args.incoming)
    return {
        "current": current,
        "incoming": args.incoming,
        "window_before": before,
        "window_after": after,
        "changed": after != before,
    }


# Mirrors cmd/coordinator/main.go loadSameVersionRestampCatalogs: dirs named
# <current version>-<16 lowercase hex>, at most 16 examined in name order.
MAX_RESTAMP_EXAMINED = 16
RESTAMP_SUFFIX_RE = re.compile(r"-[0-9a-f]{16}")
SHA_RE = re.compile(r"[0-9a-fA-F]{64}")
MAX_FEED_BYTES = 16 * 1024 * 1024
MAX_POOLZ_BYTES = 16 * 1024 * 1024
CANDIDATES = "autotune-candidates.json"


def _read_bounded_at(dir_fd: int, name: str, limit: int) -> bytes:
    fd = os.open(name, os.O_RDONLY | NOFOLLOW, dir_fd=dir_fd)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise WindowError(f"{name} is not a regular file")
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise WindowError(f"{name} is too large")
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def load_release(releases_fd: int, name: str) -> dict:
    """Return the admission identity of releases/<name>.

    release_id/sha are what the coordinator matches a provider hello against:
    autotune-candidates.json "version" and sha256 of its exact bytes. signer is
    the release.json signer bound to that same sha (None if unbound).
    """
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=releases_fd)
    try:
        raw = _read_bounded_at(fd, CANDIDATES, MAX_FEED_BYTES)
        try:
            feed = json.loads(_read_bounded_at(fd, "release.json", MAX_FEED_BYTES))["feeds"][CANDIDATES]
        except (OSError, ValueError, KeyError, TypeError, WindowError):
            feed = None
    finally:
        os.close(fd)
    sha = hashlib.sha256(raw).hexdigest()
    try:
        version = json.loads(raw).get("version")
    except (ValueError, AttributeError) as exc:
        raise WindowError(f"releases/{name}/{CANDIDATES} is not a JSON object") from exc
    if not isinstance(version, str) or not version.strip():
        raise WindowError(f"releases/{name}/{CANDIDATES} has no version")
    signer = None
    if (
        isinstance(feed, dict)
        and isinstance(feed.get("signer_key_id"), str)
        and str(feed.get("sha256", "")).lower() == sha
    ):
        signer = feed["signer_key_id"]
    return {"dir": f"releases/{name}", "release_id": version, "sha": sha, "signer": signer}


def admissible_releases(root_fd: int, incoming: str, *, required_uid: int = 0) -> list[dict]:
    """Every release a provider may be admitted on after incoming becomes current."""
    current = read_current(root_fd)
    window = compute_window(read_window(root_fd, required_uid=required_uid), current or None, incoming)
    releases_fd = os.open("releases", os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW, dir_fd=root_fd)
    try:
        active = load_release(releases_fd, incoming[len("releases/"):])
        out = [active]
        # previous-target is fail-closed in the coordinator: an unloadable
        # entry blocks boot, so it is a refusal here too.
        for entry in window:
            prev = load_release(releases_fd, entry[len("releases/"):])
            # ws/server.go: a same-version previous catalog must keep the
            # active signer.
            if prev["release_id"] == active["release_id"] and (
                prev["signer"] is None or prev["signer"] != active["signer"]
            ):
                continue
            out.append(prev)
        prefix = active["release_id"] + "-"
        examined = 0
        for entry in sorted(os.scandir(releases_fd), key=lambda e: e.name):
            if not entry.is_dir(follow_symlinks=False) or not entry.name.startswith(prefix):
                continue
            if RESTAMP_SUFFIX_RE.fullmatch(entry.name[len(prefix) - 1:]) is None:
                continue
            if examined >= MAX_RESTAMP_EXAMINED:
                break
            examined += 1
            try:
                restamp = load_release(releases_fd, entry.name)
            except (OSError, WindowError):
                continue
            if (
                restamp["release_id"] != active["release_id"]
                or restamp["sha"] == active["sha"]
                or restamp["signer"] is None
                or restamp["signer"] != active["signer"]
            ):
                continue
            out.append(restamp)
    finally:
        os.close(releases_fd)
    return out


def advertised_catalogs(poolz: object) -> tuple[dict[tuple[str, str], dict], int]:
    if not isinstance(poolz, dict) or not isinstance(poolz.get("pool"), list):
        raise WindowError("poolz JSON has no pool list")
    advertised: dict[tuple[str, str], dict] = {}
    total = 0
    for provider in poolz["pool"]:
        if not isinstance(provider, dict):
            raise WindowError("poolz pool entry is not an object")
        release_id = provider.get("catalog_release_id") or ""
        sha = provider.get("catalog_candidate_sha256") or ""
        if not isinstance(release_id, str) or not isinstance(sha, str):
            raise WindowError("poolz catalog fields must be strings")
        if not release_id and not sha:
            continue  # legacy/bridge provider: advertises no catalog
        if not release_id or SHA_RE.fullmatch(sha) is None:
            raise WindowError("poolz provider advertises a partial or malformed catalog")
        total += 1
        slot = advertised.setdefault((release_id, sha.lower()), {"providers": 0, "routing_eligible": 0})
        slot["providers"] += 1
        if provider.get("routing_eligible") is True:
            slot["routing_eligible"] += 1
    return advertised, total


def _coverage(args: argparse.Namespace) -> dict:
    validate_entry(args.incoming)
    with open(args.poolz_json, "rb") as fh:
        data = fh.read(MAX_POOLZ_BYTES + 1)
    if len(data) > MAX_POOLZ_BYTES:
        raise WindowError("poolz JSON is too large")
    advertised, total = advertised_catalogs(json.loads(data))
    root_fd = open_root(args.root, required_uid=args.required_uid)
    try:
        admissible = admissible_releases(root_fd, args.incoming, required_uid=args.required_uid)
    finally:
        os.close(root_fd)
    keys = {(r["release_id"], r["sha"]) for r in admissible}
    covered = [{"dir": r["dir"], "release_id": r["release_id"], "sha": r["sha"]} for r in admissible]
    uncovered = [
        {"release_id": rid, "sha": sha, **counts}
        for (rid, sha), counts in sorted(advertised.items())
        if (rid, sha) not in keys
    ]
    return {"covered": covered, "uncovered": uncovered, "advertised_total": total}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--root", required=True, help="autotune catalog root holding current and .previous-target")
        p.add_argument("--required-uid", type=int, default=0, help=argparse.SUPPRESS)
        p.add_argument("--group", default="macprovider", help=argparse.SUPPRESS)

    for name, help_text in (("plan", "print the window a switch to --incoming would write"),
                            ("apply", "write the window for a switch to --incoming")):
        p = sub.add_parser(name, help=help_text)
        common(p)
        p.add_argument("--incoming", required=True, help="releases/<id> about to become current")
        p.add_argument("--outgoing", help="releases/<id> leaving current (default: readlink current)")
        if name == "apply":
            p.add_argument("--expect-current", required=True, help="refuse unless current still points here")
    p = sub.add_parser("restore", help="write the exact entries of a saved window (rollback)")
    common(p)
    p.add_argument("--from-file", required=True)
    p.add_argument("--expect-current", required=True)
    p = sub.add_parser("coverage", help="exit 4 if a connected provider's catalog would stop being admissible")
    common(p)
    p.add_argument("--incoming", required=True, help="releases/<id> about to become current")
    p.add_argument("--poolz-json", required=True, help="coordinator /poolz response body")

    args = parser.parse_args(argv)
    group: str | int = int(args.group) if args.group.isdigit() else args.group
    try:
        if args.cmd == "coverage":
            result = _coverage(args)
            print(json.dumps(result, sort_keys=True))
            return 4 if result["uncovered"] else 0
        if args.cmd == "restore":
            with open(args.from_file, "rb") as fh:
                data = fh.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise WindowError("restore source is too large")
            entries = parse_entries(data.decode("ascii"))
            write_window(args.root, entries, group=group, expect_current=args.expect_current,
                         required_uid=args.required_uid)
            result = {"current": args.expect_current, "window_after": entries}
        else:
            result = _plan(args)
            if args.cmd == "apply" and result["changed"]:
                write_window(args.root, result["window_after"], group=group,
                             expect_current=args.expect_current, required_uid=args.required_uid)
            elif args.cmd == "apply" and result["current"] != args.expect_current:
                raise WindowError(f"current is {result['current']!r}, expected {args.expect_current!r}")
    except (WindowError, ValueError, OSError, KeyError, TypeError) as exc:
        print(f"autotune_window: refusing: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
