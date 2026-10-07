#!/usr/bin/env python3
"""Bounded raw-source collector for privacy-class beta v2 evidence.

This tool only captures reviewed raw inputs for a later isolated Studio
campaign. It does not launch processes, sign material, connect to services,
change databases, or claim journey status.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sqlite3
import stat
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from privacy_class_beta_journey_evidence import (  # noqa: E402
    Bundle,
    Checks,
    V2_DB_COLUMNS,
    V2_DB_TABLES,
    V2_SOURCE_CONTRACT,
    V2_SOURCE_PROFILE,
    V2RawSourceView,
)


EXTRACTOR = Path(__file__).with_name("extract-primary-evidence.py")
_spec = importlib.util.spec_from_file_location("privacy_class_beta_primary_extractor_limits", EXTRACTOR)
if _spec is None or _spec.loader is None:
    raise RuntimeError("unable to load privacy-class beta primary extractor limits")
_extractor_limits = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_extractor_limits)

MAX_FILE_SOURCE_BYTES = _extractor_limits.V2_SOURCE_MAX_BYTES
MAX_DB_SOURCE_BYTES = 256 << 20
INVENTORY_DIR = "capture-v2-inventory"
SECRET_COLUMN = (
    "secret",
    "token",
    "password",
    "passwd",
    "api_key",
    "apikey",
    "authorization",
    "bearer",
    "private_key",
    "seed",
)
SNAPSHOT_BASE_BUDGET = 2048

DB_SNAPSHOT_KINDS = frozenset(
    kind
    for manifest, sources in V2_SOURCE_CONTRACT.items()
    for kind in sources
    if kind.endswith("_db")
    or "_db_" in kind
    or kind
    in {
        "enrollment_before",
        "enrollment_after_first",
        "enrollment_after_second",
        "enrollment_after_reuse",
        "enrollment_after_failed_posture",
        "reenroll_initial",
        "reenroll_key_change",
        "reenroll_expiry_retry",
        "reenroll_operator_clear",
        "reenroll_after",
    }
)


class CaptureError(RuntimeError):
    pass


def die(message: str) -> None:
    raise CaptureError(message)


def all_kinds() -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    for manifest, sources in V2_SOURCE_CONTRACT.items():
        for kind, relative in sources.items():
            if kind in result:
                die(f"duplicate source kind in contract: {kind}")
            result[kind] = (manifest, relative)
    return result


KINDS = all_kinds()


def require_existing_private_dir(path: Path, label: str) -> None:
    try:
        st = path.lstat()
    except FileNotFoundError:
        die(f"{label} is absent: {path}")
    if stat.S_ISLNK(st.st_mode):
        die(f"{label} must not be a symlink: {path}")
    if not stat.S_ISDIR(st.st_mode):
        die(f"{label} must be a directory: {path}")
    if st.st_uid != os.getuid():
        die(f"{label} must be owned by the current lab user: {path}")
    if stat.S_IMODE(st.st_mode) != 0o700:
        die(f"{label} mode must be 0700: {path}")


def require_no_symlink_components(path: Path, label: str, *, allow_missing_leaf: bool) -> None:
    absolute = path if path.is_absolute() else Path.cwd() / path
    parts = absolute.parts
    probe = Path(parts[0])
    for index, part in enumerate(parts[1:], start=1):
        probe = probe / part
        try:
            st = probe.lstat()
        except FileNotFoundError:
            if allow_missing_leaf and index == len(parts) - 1:
                return
            die(f"{label} component is absent: {probe}")
        if stat.S_ISLNK(st.st_mode):
            die(f"{label} must not traverse a symlink: {probe}")


def mkdir_private_chain(root: Path, path: Path) -> None:
    current = root
    for part in path.relative_to(root).parts:
        current = current / part
        if current.exists() or current.is_symlink():
            require_existing_private_dir(current, "output directory")
            continue
        os.mkdir(current, 0o700)


def write_private(root: Path, path: Path, data: bytes) -> None:
    try:
        path.relative_to(root)
    except ValueError:
        die("output path escaped output root")
    if path.exists() or path.is_symlink():
        die(f"refusing to overwrite output: {path}")
    mkdir_private_chain(root, path.parent)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            die(f"output is not a single-link regular file: {path}")
        with os.fdopen(fd, "wb") as handle:
            fd = -1
            handle.write(data)
    except BaseException:
        if fd != -1:
            os.close(fd)
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        raise


def write_json_private(root: Path, path: Path, value: Any) -> None:
    data = json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False).encode("utf-8") + b"\n"
    write_private(root, path, data)


def prepare_output_root(raw: Path) -> Path:
    require_no_symlink_components(raw, "output root", allow_missing_leaf=True)
    if raw.is_symlink():
        die("output root must not be a symlink")
    if raw.exists() and not raw.is_dir():
        die("output root must be a directory")
    if not raw.exists():
        parent = raw.parent if raw.parent != Path("") else Path(".")
        require_existing_private_dir(parent, "output root parent")
        os.mkdir(raw, 0o700)
    root = raw.resolve()
    require_existing_private_dir(root, "output root")
    return root


def open_source_fd(path: Path, max_bytes: int) -> tuple[int, Path, os.stat_result]:
    require_no_symlink_components(path, "source", allow_missing_leaf=False)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        die(f"source is absent: {path}")
    except OSError as exc:
        die(f"source cannot be opened safely: {exc.strerror}")
    st = os.fstat(fd)
    try:
        validate_source_stat(st, max_bytes)
    except CaptureError:
        os.close(fd)
        raise
    return fd, path.resolve(), st


def validate_source_stat(st: os.stat_result, max_bytes: int) -> None:
    if not stat.S_ISREG(st.st_mode):
        die("source must be a regular file")
    if st.st_uid != os.getuid():
        die("source must be owned by the current lab user")
    if stat.S_IMODE(st.st_mode) & 0o022:
        die("source must not be group- or world-writable")
    if st.st_nlink != 1:
        die("source must not be hard-linked")
    if st.st_size <= 0 or st.st_size > max_bytes:
        die(f"source must be between 1 and {max_bytes} bytes")


def require_source_path_matches_fd(path: Path, fd: int, expected: os.stat_result, max_bytes: int) -> None:
    require_no_symlink_components(path, "source", allow_missing_leaf=False)
    try:
        current = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        die(f"source is absent: {path}")
    validate_source_stat(current, max_bytes)
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        die("source changed while capturing SQLite snapshot")
    pinned = os.fstat(fd)
    validate_source_stat(pinned, max_bytes)
    if (pinned.st_dev, pinned.st_ino) != (expected.st_dev, expected.st_ino):
        die("source changed while capturing SQLite snapshot")


def read_source_bytes(path: Path, max_bytes: int) -> tuple[bytes, Path, os.stat_result]:
    fd, resolved, st = open_source_fd(path, max_bytes)
    try:
        data = os.read(fd, max_bytes + 1)
    finally:
        os.close(fd)
    if len(data) != st.st_size:
        die("source changed while being read")
    return data, resolved, st


def source_file(path: Path, max_bytes: int) -> Path:
    fd, resolved, _st = open_source_fd(path, max_bytes)
    os.close(fd)
    return resolved


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            die(f"JSON source repeats key {key!r}")
        result[key] = value
    return result


def parse_json_bytes(data: bytes, label: str) -> Any:
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_json_object)
    except UnicodeDecodeError as exc:
        die(f"{label} must be UTF-8 JSON ({exc.__class__.__name__})")
    except CaptureError:
        raise
    except ValueError as exc:
        die(f"{label} must be JSON ({exc.__class__.__name__})")


def validate_source_bytes(kind: str, relative: str, data: bytes) -> None:
    suffix = Path(relative).suffix
    if suffix == ".json":
        parse_json_bytes(data, kind)
    elif suffix == ".pem":
        text = data.decode("utf-8", errors="strict")
        if "PRIVATE KEY" in text or "PUBLIC KEY" not in text:
            die(f"{kind} must be a public key PEM")
    elif suffix == ".sig":
        return
    else:
        die(f"{kind} has unsupported contract file type: {suffix}")


def typed_cell(value: Any) -> Any:
    if value is None or isinstance(value, (int, float, str)):
        return value
    if isinstance(value, bytes):
        return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}
    return str(value)


def open_readonly_db(path: Path) -> sqlite3.Connection:
    uri = f"file:{quote(path.as_posix())}?mode=ro"
    db = sqlite3.connect(uri, uri=True, isolation_level=None)
    db.execute("PRAGMA query_only = ON")
    db.execute("BEGIN")
    return db


def db_columns(db: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in db.execute(f'PRAGMA table_info("{table}")')]


def serialized_len(value: Any) -> int:
    return len(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


class SnapshotBudget:
    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.used = SNAPSHOT_BASE_BUDGET

    def add(self, value: Any, label: str) -> None:
        self.used += serialized_len(value) + 64
        if self.used > self.limit:
            die(f"DB snapshot exceeds bounded raw-source budget while exporting {label}")


def export_snapshot(path: Path, source_fd: int | None = None, source_st: os.stat_result | None = None) -> dict[str, Any]:
    if (source_fd is None) != (source_st is None):
        die("internal SQLite source identity mismatch")
    if source_fd is not None and source_st is not None:
        require_source_path_matches_fd(path, source_fd, source_st, MAX_DB_SOURCE_BYTES)
    db = open_readonly_db(path)
    try:
        if source_fd is not None and source_st is not None:
            require_source_path_matches_fd(path, source_fd, source_st, MAX_DB_SOURCE_BYTES)
        budget = SnapshotBudget(MAX_FILE_SOURCE_BYTES)
        tables: dict[str, Any] = {}
        existing = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        missing_tables = [name for name in V2_DB_TABLES if name not in existing]
        if missing_tables:
            die(f"database missing required v2 table(s): {', '.join(missing_tables)}")
        for table in V2_DB_TABLES:
            allowed = list(V2_DB_COLUMNS[table])
            actual = db_columns(db, table)
            missing_columns = [column for column in allowed if column not in actual]
            if missing_columns:
                die(f"{table} missing required column(s): {', '.join(missing_columns)}")
            dropped = [
                column
                for column in actual
                if column not in allowed and not any(marker in column.lower() for marker in SECRET_COLUMN)
            ]
            selected = ", ".join(f'"{column}"' for column in allowed)
            rows = []
            for raw in db.execute(f'SELECT {selected} FROM "{table}"'):
                row = {column: typed_cell(value) for column, value in zip(allowed, raw)}
                budget.add(row, table)
                rows.append(row)
            rows.sort(key=lambda row: json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
            export = {
                "table": table,
                "columns": allowed,
                "dropped_columns": dropped,
                "row_count": len(rows),
                "truncated": False,
                "rows": rows,
            }
            budget.add({"table": table, "columns": allowed, "dropped_columns": dropped, "row_count": len(rows)}, table)
            tables[table] = export
        if source_fd is not None and source_st is not None:
            require_source_path_matches_fd(path, source_fd, source_st, MAX_DB_SOURCE_BYTES)
        return {"captured_at_unix": int(time.time()), "tables": tables}
    finally:
        try:
            db.execute("ROLLBACK")
        finally:
            db.close()


def provenance(kind: str, relative: str, source: Path, output: Path, out_root: Path) -> dict[str, Any]:
    return {
        "schema_version": "macprovider.privacy-class-beta-v2-capture-source.v1",
        "kind": kind,
        "path": relative,
        "source_name": source.name,
        "output_path": output.relative_to(out_root).as_posix(),
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "bytes": output.stat().st_size,
        "captured_at_unix": int(time.time()),
    }


def encode_bounded_json(value: Any, label: str) -> bytes:
    data = json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False).encode("utf-8") + b"\n"
    if len(data) > MAX_FILE_SOURCE_BYTES:
        die(f"{label} exceeds bounded raw-source budget")
    return data


def capture_kind(args: argparse.Namespace) -> None:
    if args.kind not in KINDS:
        die(f"unknown v2 source kind: {args.kind}")
    _manifest, relative = KINDS[args.kind]
    out_root = prepare_output_root(Path(args.out_root))
    source_path = Path(args.source)
    target = out_root / relative
    try:
        target.relative_to(out_root)
    except ValueError:
        die("contract output path escaped output root")
    if args.kind in DB_SNAPSHOT_KINDS:
        source_fd, source, source_st = open_source_fd(source_path, MAX_DB_SOURCE_BYTES)
        try:
            snapshot = export_snapshot(source, source_fd, source_st)
            data = encode_bounded_json(snapshot, args.kind)
        finally:
            os.close(source_fd)
    else:
        data, source, _st = read_source_bytes(source_path, MAX_FILE_SOURCE_BYTES)
        validate_source_bytes(args.kind, relative, data)
    write_private(out_root, target, data)
    write_json_private(out_root, out_root / INVENTORY_DIR / f"{args.kind}.json", provenance(args.kind, relative, source, target, out_root))


def finalize(args: argparse.Namespace) -> None:
    out_root = prepare_output_root(Path(args.out_root))
    rows = collect_closed_raw_source_rows(out_root)
    write_json_private(
        out_root,
        out_root / INVENTORY_DIR / "FINALIZED.json",
        {
            "schema_version": "macprovider.privacy-class-beta-v2-capture-inventory.v1",
            "captured_at_unix": int(time.time()),
            "raw_sources": rows,
        },
    )


def collect_closed_raw_source_rows(out_root: Path) -> list[dict[str, Any]]:
    expected = {relative for _manifest, relative in KINDS.values()}
    raw_root = out_root / "evidence" / "v2-raw"
    if raw_root.is_symlink() or not raw_root.is_dir():
        die("evidence/v2-raw must be a real directory")
    actual = set()
    for path in raw_root.rglob("*"):
        if path.is_symlink():
            die(f"finalized raw source tree must not contain symlinks: {path}")
        if path.is_file():
            actual.add(path.relative_to(out_root).as_posix())
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        if missing:
            die(f"missing closed v2 raw source(s): {', '.join(missing)}")
        die(f"unexpected v2 raw source(s): {', '.join(extra)}")
    rows = []
    for kind, (_manifest, relative) in sorted(KINDS.items()):
        path = out_root / relative
        inventory_path = out_root / INVENTORY_DIR / f"{kind}.json"
        inventory_raw, _inventory_resolved, _inventory_st = read_source_bytes(inventory_path, MAX_FILE_SOURCE_BYTES)
        inventory = parse_json_bytes(inventory_raw, f"{kind} capture inventory")
        if not isinstance(inventory, dict) or set(inventory) != {"schema_version", "kind", "path", "source_name", "output_path", "sha256", "bytes", "captured_at_unix"}:
            die(f"{kind} capture inventory has invalid shape")
        if inventory.get("kind") != kind or inventory.get("path") != relative or inventory.get("output_path") != relative:
            die(f"{kind} capture inventory does not match the closed contract path")
        data, _resolved, st = read_source_bytes(path, MAX_FILE_SOURCE_BYTES)
        validate_source_bytes(kind, relative, data)
        digest = hashlib.sha256(data).hexdigest()
        if inventory.get("sha256") != digest or inventory.get("bytes") != st.st_size:
            die(f"{kind} finalized source drifted after capture")
        rows.append({"kind": kind, "path": relative, "sha256": digest, "bytes": st.st_size})
    return rows


def require_finalized_current(out_root: Path) -> list[dict[str, Any]]:
    finalized_path = out_root / INVENTORY_DIR / "FINALIZED.json"
    raw, _resolved, _st = read_source_bytes(finalized_path, MAX_FILE_SOURCE_BYTES)
    finalized = parse_json_bytes(raw, "FINALIZED capture inventory")
    if not isinstance(finalized, dict) or set(finalized) != {"schema_version", "captured_at_unix", "raw_sources"}:
        die("FINALIZED capture inventory has invalid shape")
    if finalized.get("schema_version") != "macprovider.privacy-class-beta-v2-capture-inventory.v1":
        die("FINALIZED capture inventory has invalid schema_version")
    if not isinstance(finalized.get("captured_at_unix"), int) or isinstance(finalized.get("captured_at_unix"), bool):
        die("FINALIZED capture inventory has invalid captured_at_unix")
    current = collect_closed_raw_source_rows(out_root)
    if finalized.get("raw_sources") != current:
        die("FINALIZED capture inventory is stale")
    return current


def parse_binding(path: Path) -> dict[str, str]:
    data, _resolved, _st = read_source_bytes(path, MAX_FILE_SOURCE_BYTES)
    bundle = Bundle("binding", {"step-01-bind-signed-release/binding.txt": data}, b"")
    return Checks(bundle).binding()


def preflight_source_manifest_outputs(out_root: Path) -> dict[str, Path]:
    targets = {name: out_root / "evidence" / "v2-source" / name for name in sorted(V2_SOURCE_CONTRACT)}
    for name, path in targets.items():
        try:
            path.relative_to(out_root)
        except ValueError:
            die(f"source manifest output escaped output root: {name}")
        if path.exists() or path.is_symlink():
            die(f"refusing to overwrite output: {path}")
        absolute = path if path.is_absolute() else Path.cwd() / path
        probe = Path(absolute.parts[0])
        for part in absolute.parts[1:]:
            probe = probe / part
            try:
                st = probe.lstat()
            except FileNotFoundError:
                break
            if stat.S_ISLNK(st.st_mode):
                die(f"source manifest output must not traverse a symlink: {probe}")
        if path.parent.exists() or path.parent.is_symlink():
            require_existing_private_dir(path.parent, "source manifest output directory")
    return targets


def compose_source_manifest(out_root: Path, binding: dict[str, str], finalized_by_kind: dict[str, dict[str, Any]], name: str) -> dict[str, Any]:
    errors: list[str] = []

    def source_bytes(manifest: str, kind: str) -> bytes:
        if manifest != name:
            die(f"internal source manifest mismatch: {manifest} != {name}")
        relative = V2_SOURCE_CONTRACT[manifest][kind]
        data, _resolved, _st = read_source_bytes(out_root / relative, MAX_FILE_SOURCE_BYTES)
        row = finalized_by_kind.get(kind)
        if row is None or row.get("path") != relative:
            die(f"FINALIZED inventory is missing {kind}")
        digest = hashlib.sha256(data).hexdigest()
        if row.get("sha256") != digest or row.get("bytes") != len(data):
            die(f"{kind} finalized source drifted before compose")
        return data

    view = V2RawSourceView(source_bytes, binding)
    derived = view.manifest(name, errors)
    if errors:
        die("; ".join(errors))
    provenance = []
    for kind, relative in sorted(V2_SOURCE_CONTRACT[name].items()):
        row = finalized_by_kind.get(kind)
        if row is None or row.get("path") != relative:
            die(f"FINALIZED inventory is missing {kind}")
        provenance.append({"kind": kind, "path": relative, "sha256": row["sha256"]})
    return {
        "profile": V2_SOURCE_PROFILE,
        "provenance": {"raw_sources": provenance},
        **derived,
    }


def compose_source_manifests(args: argparse.Namespace) -> None:
    if not args.binding:
        die("--binding is required with --compose-source-manifests")
    out_root = prepare_output_root(Path(args.out_root))
    finalized = require_finalized_current(out_root)
    finalized_by_kind = {row["kind"]: row for row in finalized}
    binding = parse_binding(Path(args.binding))
    targets = preflight_source_manifest_outputs(out_root)
    manifests = {
        name: compose_source_manifest(out_root, binding, finalized_by_kind, name)
        for name in sorted(V2_SOURCE_CONTRACT)
    }
    for path in targets.values():
        mkdir_private_chain(out_root, path.parent)
    for path in targets.values():
        if path.exists() or path.is_symlink():
            die(f"refusing to overwrite output: {path}")
    for name, doc in manifests.items():
        write_json_private(out_root, targets[name], doc)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-root", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--kind")
    mode.add_argument("--finalize", action="store_true")
    mode.add_argument("--compose-source-manifests", action="store_true")
    parser.add_argument("--source")
    parser.add_argument("--binding")
    args = parser.parse_args(argv)
    try:
        if args.finalize:
            if args.source or args.binding:
                die("--source/--binding are not accepted with --finalize")
            finalize(args)
        elif args.compose_source_manifests:
            if args.source:
                die("--source is not accepted with --compose-source-manifests")
            compose_source_manifests(args)
        else:
            if args.binding:
                die("--binding is accepted only with --compose-source-manifests")
            if not args.source:
                die("--source is required with --kind")
            capture_kind(args)
    except CaptureError as exc:
        print(f"capture-v2-sources: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
