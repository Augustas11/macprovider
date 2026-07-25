#!/usr/bin/env python3
"""Fail-closed, app-only install and exact-previous rollback for Malibu.app.

Before mutation, the transaction cryptographically validates the signed release
index and envelope against a hard-pinned production SPKI, verifies the source app's
code-signing requirement and Gatekeeper assessment, and records deterministic app
and sidecar evidence. Operator rollback additionally consumes a one-use signed
current-to-target authorization; in-process install failure recovery does not.
"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid


SCHEMA = "malibu.app-transaction.v1"
JOURNAL_SCHEMA = "malibu.app-transaction-journal.v1"
ROLLBACK_RECEIPT_SCHEMA = "malibu.rollback-authorization-receipt.v1"
BUNDLE_ID = "tech.malibu.app"
EXPECTED_TEAM_ID = "YF7XNRJUG4"
PINNED_SPKI_SHA256 = "2cd6171cea8cd7964c12292e3443078c2b3d0cdcc20ae600fe8261090392c7f8"
PINNED_PUBLIC_KEY_NAME = "release-signing-public.pem"
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX32 = re.compile(r"[0-9a-f]{32}")
FAIL_ENV = "MALIBU_TRANSACTION_FAIL_AT"
CRASH_ENV = "MALIBU_TRANSACTION_CRASH_AT"
RENAME_SWAP = 0x00000002


class TransactionError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise TransactionError(message)


def sha256_file(path: pathlib.Path, label: str) -> str:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_safe_file(path: pathlib.Path, label: str, allowed_uids: set[int]) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file")
    if metadata.st_uid not in allowed_uids:
        fail(f"{label} has unexpected owner uid {metadata.st_uid}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        fail(f"{label} must not be group/world writable")


def strict_json(path: pathlib.Path, label: str) -> dict:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular non-symlink file")
    raw = path.read_bytes()

    def pairs(items: list[tuple[str, object]]) -> dict:
        value: dict = {}
        for key, item in items:
            if key in value:
                fail(f"{label} contains duplicate key {key!r}")
            value[key] = item
        return value

    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=pairs,
            parse_float=lambda _: fail(f"{label} contains a floating-point number"),
            parse_constant=lambda item: fail(f"{label} contains invalid number {item}"),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def require_absolute_clean(path: pathlib.Path, label: str) -> pathlib.Path:
    text = str(path)
    if not path.is_absolute() or ".." in path.parts or "\x00" in text:
        fail(f"{label} must be an absolute path without traversal components")
    return pathlib.Path(os.path.normpath(text))


def reject_symlink_ancestors(path: pathlib.Path, label: str) -> None:
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if not current.exists() and not current.is_symlink():
            continue
        metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            fail(f"{label} has symlink ancestor {current}")


def require_safe_directory(path: pathlib.Path, label: str, allowed_uids: set[int]) -> None:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        fail(f"{label} must be a non-symlink directory")
    if metadata.st_uid not in allowed_uids:
        fail(f"{label} has unexpected owner uid {metadata.st_uid}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        fail(f"{label} must not be group/world writable")


def tree_evidence(app: pathlib.Path, expected_uid: int, *, require_malibu_name: bool = True) -> dict:
    if require_malibu_name and app.name != "Malibu.app":
        fail("app path must end in Malibu.app")
    reject_symlink_ancestors(app, "app")
    require_safe_directory(app, "app", {expected_uid})
    digest = hashlib.sha256()
    root_mode = stat.S_IMODE(app.lstat().st_mode)
    digest.update(f"d\0.\0{root_mode:04o}\0{0}\0-\0".encode("utf-8"))
    count = 0
    for root, directories, files in os.walk(app, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        root_path = pathlib.Path(root)
        for name in directories + files:
            path = root_path / name
            metadata = path.lstat()
            relative = path.relative_to(app).as_posix()
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"app contains symlink {relative}")
            if metadata.st_uid != expected_uid:
                fail(f"app entry has unexpected owner uid: {relative}")
            mode = stat.S_IMODE(metadata.st_mode)
            if mode & 0o022:
                fail(f"app entry is group/world writable: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                kind = "d"
                content = "-"
                size = 0
            elif stat.S_ISREG(metadata.st_mode):
                kind = "f"
                content = sha256_file(path, f"app entry {relative}")
                size = metadata.st_size
            else:
                fail(f"app contains unsupported entry type: {relative}")
            record = f"{kind}\0{relative}\0{mode:04o}\0{size}\0{content}\0"
            digest.update(record.encode("utf-8"))
            count += 1
    info_path = app / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"app Info.plist is invalid: {error}")
    bundle = info.get("CFBundleIdentifier")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    if bundle != BUNDLE_ID or not isinstance(version, str) or not version:
        fail("app bundle identity/version is invalid")
    if not isinstance(build, str) or not build.isdigit() or int(build) < 1:
        fail("app build is invalid")
    return {
        "build": int(build),
        "bundle_id": bundle,
        "entry_count": count,
        "marketing_version": version,
        "root_mode": root_mode,
        "tree_sha256": digest.hexdigest(),
    }


def validate_sidecars(envelope_path: pathlib.Path, index_path: pathlib.Path) -> dict:
    envelope = strict_json(envelope_path, "release envelope")
    index = strict_json(index_path, "release index")
    if envelope.get("schema_version") != "malibu-release-envelope.v1":
        fail("release envelope schema is unsupported")
    if index.get("schema_version") != "malibu-release-index.v1":
        fail("release index schema is unsupported")
    try:
        app = envelope["signed"]["app"]
        envelope_generation = envelope["signed"]["envelope_generation"]
        indexed = index["signed"]["envelope"]
        index_generation = index["signed"]["index_generation"]
    except (KeyError, TypeError):
        fail("release sidecars are missing transaction binding fields")
    if not isinstance(app, dict) or app.get("bundle_id") != BUNDLE_ID:
        fail("release envelope has the wrong app bundle identity")
    if not isinstance(app.get("marketing_version"), str):
        fail("release envelope app version is invalid")
    if isinstance(app.get("build"), bool) or not isinstance(app.get("build"), int):
        fail("release envelope app build is invalid")
    if isinstance(app.get("entry_count"), bool) or not isinstance(app.get("entry_count"), int) or app["entry_count"] < 1:
        fail("release envelope app entry count is invalid")
    if isinstance(app.get("root_mode"), bool) or not isinstance(app.get("root_mode"), int) or not 0 < app["root_mode"] <= 0o7777:
        fail("release envelope app root mode is invalid")
    if not isinstance(app.get("tree_sha256"), str) or HEX64.fullmatch(app["tree_sha256"]) is None:
        fail("release envelope app tree digest is invalid")
    if not all(isinstance(value, int) and not isinstance(value, bool) and value > 0 for value in (envelope_generation, index_generation)):
        fail("release sidecar generation is invalid")
    envelope_digest = sha256_file(envelope_path, "release envelope")
    if not isinstance(indexed, dict) or indexed.get("sha256") != envelope_digest:
        fail("release index does not bind the exact envelope bytes")
    if indexed.get("build") != app["build"] or indexed.get("generation") != envelope_generation:
        fail("release index and envelope app evidence disagree")
    return {
        "app_build": app["build"],
        "app_entry_count": app["entry_count"],
        "app_root_mode": app["root_mode"],
        "app_tree_sha256": app["tree_sha256"],
        "app_version": app["marketing_version"],
        "envelope_generation": envelope_generation,
        "index_generation": index_generation,
    }


def signed_legacy_source_versions(envelope_path: pathlib.Path, evidence: dict) -> set[str]:
    envelope = strict_json(envelope_path, "release envelope")
    try:
        cohorts = envelope["signed"]["legacy_bootstrap"]["allowed_source_cohorts"]
    except (KeyError, TypeError):
        fail("release envelope lacks signed legacy source cohorts")
    if not isinstance(cohorts, list):
        fail("release envelope legacy source cohorts are invalid")
    matches: set[str] = set()
    for cohort in cohorts:
        if not isinstance(cohort, dict):
            fail("release envelope legacy source cohort is invalid")
        expected = {
            "build": cohort.get("app_build"),
            "bundle_id": BUNDLE_ID,
            "entry_count": cohort.get("app_entry_count"),
            "marketing_version": cohort.get("app_version"),
            "root_mode": cohort.get("app_root_mode"),
            "tree_sha256": cohort.get("app_tree_sha256"),
        }
        if evidence == expected:
            matches.add(expected["marketing_version"])
    return matches


def check_expected(actual: str, expected: object, label: str) -> None:
    if not isinstance(expected, str) or HEX64.fullmatch(expected) is None or actual != expected:
        fail(f"{label} SHA-256 mismatch")


def validate_pinned_public_key(keyring: pathlib.Path, expected_key_id: str, expected_uid: int) -> None:
    keyring_value = strict_json(keyring, "release keyring")
    selected = None
    for candidate in keyring_value.get("keys", []):
        if isinstance(candidate, dict) and candidate.get("key_id") == expected_key_id:
            selected = candidate
            break
    if selected is None or selected.get("public_key_spki_sha256") != PINNED_SPKI_SHA256:
        fail("release keyring does not bind the hard-pinned production SPKI digest")
    public_path_text = selected.get("public_key_path")
    if public_path_text != PINNED_PUBLIC_KEY_NAME:
        fail("release keyring public key path escapes the self-contained trust bundle")
    public_path = keyring.parent / public_path_text
    reject_symlink_ancestors(public_path, "release public key")
    require_safe_file(public_path, "release public key", {0, expected_uid, os.geteuid()})
    result = subprocess.run(
        ["/usr/bin/openssl", "pkey", "-pubin", "-in", str(public_path), "-outform", "DER"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0 or hashlib.sha256(result.stdout).hexdigest() != PINNED_SPKI_SHA256:
        fail("release public key differs from the hard-pinned production SPKI digest")


def validated_trust_context(
    keyring: pathlib.Path,
    revocations: pathlib.Path,
    expected_key_id: str,
) -> dict:
    keyring_value = strict_json(keyring, "release keyring")
    revocations_value = strict_json(revocations, "release revocations")
    keyring_generation = keyring_value.get("generation")
    revocations_generation = revocations_value.get("generation")
    if not all(isinstance(value, int) and not isinstance(value, bool) and value > 0 for value in (
        keyring_generation, revocations_generation,
    )):
        fail("release trust generations are invalid")
    selected = next((
        candidate for candidate in keyring_value.get("keys", [])
        if isinstance(candidate, dict) and candidate.get("key_id") == expected_key_id
    ), None)
    if selected is None or not isinstance(selected.get("public_key_spki_sha256"), str):
        fail("release trust context lacks the validated signing key")
    return {
        "key_id": expected_key_id,
        "keyring_generation": keyring_generation,
        "keyring_sha256": sha256_file(keyring, "release keyring"),
        "public_key_spki_sha256": selected["public_key_spki_sha256"],
        "revocations_generation": revocations_generation,
        "revocations_sha256": sha256_file(revocations, "release revocations"),
    }


def cryptographically_validate_release(
    *,
    envelope: pathlib.Path,
    index: pathlib.Path,
    keyring: pathlib.Path,
    revocations: pathlib.Path,
    expected_key_id: str,
    minimum_keyring_generation: int,
    minimum_index_generation: int,
    minimum_envelope_generation: int,
    minimum_build: int,
    expected_uid: int,
) -> None:
    for path, label in (
        (envelope, "release envelope"),
        (index, "release index"),
        (keyring, "release keyring"),
        (revocations, "release revocations"),
    ):
        reject_symlink_ancestors(path, label)
        require_safe_file(path, label, {0, expected_uid, os.geteuid()})
    validator = pathlib.Path(__file__).with_name("malibu-release-envelope.py")
    reject_symlink_ancestors(validator, "release validator")
    require_safe_file(validator, "release validator", {0, os.geteuid()})
    validate_pinned_public_key(keyring, expected_key_id, expected_uid)
    command = [
        sys.executable,
        str(validator),
        "validate-index",
        "--input", str(index),
        "--envelope", str(envelope),
        "--keyring", str(keyring),
        "--revocations", str(revocations),
        "--expected-key-id", expected_key_id,
        "--minimum-keyring-generation", str(minimum_keyring_generation),
        "--minimum-index-generation", str(minimum_index_generation),
        "--minimum-envelope-generation", str(minimum_envelope_generation),
        "--minimum-build", str(minimum_build),
        "--installed-transaction",
    ]
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown validator failure"
        fail(f"cryptographic release validation failed: {detail}")


def verify_source_app_signature(app: pathlib.Path) -> None:
    verify = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--deep", "--verbose=2", str(app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if verify.returncode != 0:
        fail(f"source app code signature verification failed: {verify.stderr.strip()}")
    requirement = (
        f'identifier "{BUNDLE_ID}" and anchor apple generic and '
        f'certificate leaf[subject.OU] = "{EXPECTED_TEAM_ID}"'
    )
    identity = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", f"-R={requirement}", str(app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if identity.returncode != 0:
        fail("source app code signature does not match Malibu bundle/Team identity")
    assessment = subprocess.run(
        ["/usr/sbin/spctl", "-a", "-vvv", "-t", "exec", str(app)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if assessment.returncode != 0:
        fail(f"source app failed Gatekeeper assessment: {assessment.stderr.strip()}")


def authorize_operator_rollback(
    *,
    authorization: pathlib.Path,
    current_state: dict,
    target_state: dict,
    state_dir: pathlib.Path,
    keyring: pathlib.Path,
    revocations: pathlib.Path,
    expected_key_id: str,
    minimum_keyring_generation: int,
    expected_uid: int,
    token: str,
    validator_receipts: pathlib.Path,
) -> None:
    for path, label in (
        (authorization, "rollback authorization"),
        (keyring, "release keyring"),
        (revocations, "release revocations"),
    ):
        reject_symlink_ancestors(path, label)
        require_safe_file(path, label, {0, expected_uid, os.geteuid()})
    validator = pathlib.Path(__file__).with_name("malibu-release-envelope.py")
    reject_symlink_ancestors(validator, "release validator")
    require_safe_file(validator, "release validator", {0, os.geteuid()})
    validate_pinned_public_key(keyring, expected_key_id, expected_uid)
    current_path = state_dir / f".rollback-current-{token}.json"
    target_path = state_dir / f".rollback-target-{token}.json"
    write_file(current_path, json.dumps(current_state, sort_keys=True, separators=(",", ":")).encode())
    write_file(target_path, json.dumps(target_state, sort_keys=True, separators=(",", ":")).encode())
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(validator),
                "validate-rollback",
                "--input", str(authorization),
                "--current-state", str(current_path),
                "--target-state", str(target_path),
                "--receipt-directory", str(validator_receipts),
                "--keyring", str(keyring),
                "--revocations", str(revocations),
                "--expected-key-id", expected_key_id,
                "--minimum-keyring-generation", str(minimum_keyring_generation),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    finally:
        current_path.unlink(missing_ok=True)
        target_path.unlink(missing_ok=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown validator failure"
        fail(f"signed rollback authorization failed: {detail}")


def copy_app(source: pathlib.Path, target: pathlib.Path) -> None:
    if target.exists():
        fail("internal staging path already exists")
    ditto = pathlib.Path("/usr/bin/ditto")
    if ditto.exists():
        result = subprocess.run(
            [str(ditto), "--rsrc", "--extattr", "--noqtn", str(source), str(target)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            fail(f"could not stage Malibu.app: {result.stderr.strip()}")
    else:
        shutil.copytree(source, target, symlinks=False, copy_function=shutil.copy2)


def rename_swap(left: pathlib.Path, right: pathlib.Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = getattr(libc, "renamex_np", None)
    if function is None:
        fail("atomic directory exchange is unavailable on this platform")
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(os.fsencode(left), os.fsencode(right), RENAME_SWAP) != 0:
        error = ctypes.get_errno()
        fail(f"atomic directory exchange failed: {os.strerror(error)}")
    fsync_directory(left.parent)
    if right.parent != left.parent:
        fsync_directory(right.parent)


def fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def durable_rename(source: pathlib.Path, target: pathlib.Path) -> None:
    os.rename(source, target)
    fsync_directory(source.parent)
    if target.parent != source.parent:
        fsync_directory(target.parent)


def remove_path(path: pathlib.Path) -> None:
    if path.is_symlink():
        fail(f"refusing to remove symlinked transaction path {path}")
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()
    else:
        return
    fsync_directory(path.parent)


def write_file(path: pathlib.Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        fsync_directory(path.parent)
    except BaseException:
        try:
            path.unlink()
            fsync_directory(path.parent)
        except FileNotFoundError:
            pass
        raise


def replace_file(path: pathlib.Path, data: bytes) -> None:
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    write_file(temporary, data)
    try:
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        if temporary.exists():
            remove_path(temporary)


def canonical_json(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def make_state_stage(
    state_dir: pathlib.Path,
    record: dict,
    envelope: pathlib.Path,
    index: pathlib.Path,
    token: str,
    *,
    previous_envelope: pathlib.Path | None = None,
    previous_index: pathlib.Path | None = None,
) -> pathlib.Path:
    target = state_dir / f".active-new-{token}"
    target.mkdir(mode=0o700)
    fsync_directory(state_dir)
    write_file(target / "transaction.json", canonical_json(record))
    write_file(target / "release-envelope.json", envelope.read_bytes())
    write_file(target / "release-index.json", index.read_bytes())
    if (previous_envelope is None) != (previous_index is None):
        fail("previous release sidecars must be staged as a pair")
    if previous_envelope is not None and previous_index is not None:
        write_file(target / "previous-release-envelope.json", previous_envelope.read_bytes())
        write_file(target / "previous-release-index.json", previous_index.read_bytes())
    return target


def replace_active_state(state_dir: pathlib.Path, staged: pathlib.Path) -> pathlib.Path | None:
    active = state_dir / "active"
    if active.exists():
        require_safe_directory(active, "active transaction evidence", {os.geteuid()})
        rename_swap(staged, active)
        return staged
    durable_rename(staged, active)
    return None


def read_active(state_dir: pathlib.Path) -> tuple[dict, pathlib.Path] | tuple[None, None]:
    active = state_dir / "active"
    if not active.exists():
        return None, None
    require_safe_directory(active, "active transaction evidence", {os.geteuid()})
    entries = {entry.name for entry in active.iterdir()}
    expected_entries = {"release-envelope.json", "release-index.json", "transaction.json"}
    if (active / "previous-release-envelope.json").exists() or (active / "previous-release-index.json").exists():
        expected_entries |= {"previous-release-envelope.json", "previous-release-index.json"}
    if entries != expected_entries:
        fail("active transaction evidence has unexpected entries")
    record_path = active / "transaction.json"
    for name in entries:
        require_safe_file(active / name, f"active transaction evidence {name}", {os.geteuid()})
    record = strict_json(record_path, "active transaction evidence")
    if record.get("schema_version") != SCHEMA:
        fail("active transaction evidence schema is unsupported")
    base_keys = {
        "destination_app", "installed", "installed_release_state", "previous",
        "legacy_source_app_version",
        "previous_release", "previous_release_index_sha256", "previous_release_state", "release",
        "release_envelope_sha256", "release_index_sha256", "rollback_backup",
        "schema_version", "state", "transaction_id", "unix_time",
    }
    state = record.get("state")
    expected_keys = base_keys | ({
        "rollback_authorization_sha256", "rolled_back_from", "rolled_back_from_release_state",
    } if state == "rolled_back" else set())
    if set(record) != expected_keys:
        fail("active transaction evidence fields differ from the transaction schema")
    if state not in {"installed", "rolled_back"}:
        fail("active transaction evidence has an invalid state")
    if not isinstance(record.get("transaction_id"), str) or HEX32.fullmatch(record["transaction_id"]) is None:
        fail("active transaction evidence has an invalid transaction ID")
    if isinstance(record.get("unix_time"), bool) or not isinstance(record.get("unix_time"), int) or record["unix_time"] < 1:
        fail("active transaction evidence has an invalid timestamp")
    for field in ("release_envelope_sha256", "release_index_sha256"):
        if not isinstance(record.get(field), str) or HEX64.fullmatch(record[field]) is None:
            fail(f"active transaction evidence has invalid {field}")
    if state == "installed" and not isinstance(record.get("installed"), dict):
        fail("installed transaction evidence lacks installed app evidence")
    if record.get("previous") is not None and not isinstance(record.get("previous"), dict):
        fail("active transaction evidence has invalid previous app evidence")
    legacy_source_version = record.get("legacy_source_app_version")
    if legacy_source_version is not None and (
        not isinstance(legacy_source_version, str) or SEMVER.fullmatch(legacy_source_version) is None
    ):
        fail("active transaction evidence has invalid legacy source app version")
    if state == "rolled_back" and record.get("rollback_backup") is not None:
        fail("rolled-back transaction evidence must not retain a rollback target")
    if not isinstance(record.get("installed_release_state"), dict):
        fail("active transaction evidence lacks installed release state")
    if record.get("previous_release_state") is not None and not isinstance(record.get("previous_release_state"), dict):
        fail("active transaction evidence has invalid previous release state")
    has_previous_release = record.get("previous_release_state") is not None
    if has_previous_release != isinstance(record.get("previous_release"), dict):
        fail("active transaction evidence has inconsistent previous release")
    if has_previous_release != isinstance(record.get("previous_release_index_sha256"), str):
        fail("active transaction evidence has inconsistent previous release index")
    if has_previous_release != ("previous-release-envelope.json" in entries):
        fail("active transaction evidence has inconsistent previous release sidecars")
    return record, active


def safe_old_backup(record: dict | None, destination: pathlib.Path, expected_uid: int) -> pathlib.Path | None:
    if not record or record.get("state") != "installed" or record.get("previous") is None:
        return None
    backup_text = record.get("rollback_backup")
    if not isinstance(backup_text, str):
        fail("active transaction evidence lacks rollback backup")
    backup = require_absolute_clean(pathlib.Path(backup_text), "recorded rollback backup")
    expected_prefix = f".{destination.name}.rollback-"
    if backup.parent != destination.parent or not backup.name.startswith(expected_prefix):
        fail("active transaction evidence names an unsafe rollback backup")
    evidence = tree_evidence(backup, expected_uid, require_malibu_name=False)
    if evidence != record.get("previous"):
        fail("recorded rollback backup evidence does not match its app")
    return backup


def validate_active_release(record: dict, active: pathlib.Path) -> None:
    state = record.get("state")
    if state not in {"installed", "rolled_back"}:
        fail("active transaction evidence has an invalid state")
    envelope = active / "release-envelope.json"
    index = active / "release-index.json"
    check_expected(sha256_file(envelope, "active release envelope"), record.get("release_envelope_sha256"), "active release envelope")
    check_expected(sha256_file(index, "active release index"), record.get("release_index_sha256"), "active release index")
    if validate_sidecars(envelope, index) != record.get("release"):
        fail("active release sidecars do not match transaction evidence")


def release_state(release: dict, envelope_sha256: str) -> dict:
    return {
        "build": release["app_build"],
        "envelope_generation": release["envelope_generation"],
        "envelope_sha256": envelope_sha256,
        "index_generation": release["index_generation"],
    }


def evidence_if_present(path: pathlib.Path, expected_uid: int) -> dict | None:
    if not path.exists() and not path.is_symlink():
        return None
    return tree_evidence(path, expected_uid, require_malibu_name=False)


def journal_path(state_dir: pathlib.Path) -> pathlib.Path:
    return state_dir / "transaction-journal.json"


def write_journal(state_dir: pathlib.Path, journal: dict) -> None:
    replace_file(journal_path(state_dir), canonical_json(journal))


def read_journal(state_dir: pathlib.Path, destination: pathlib.Path, expected_uid: int) -> dict | None:
    path = journal_path(state_dir)
    if not path.exists():
        return None
    require_safe_file(path, "transaction journal", {os.geteuid()})
    journal = strict_json(path, "transaction journal")
    expected_keys = {
        "authorization_nonce", "authorization_sha256", "backup_app", "completed_receipt",
        "current_release_state", "destination_app", "expected_owner_uid", "failed_app", "had_active_state",
        "new_app", "obsolete_backup", "old_app", "operation", "pending_receipt", "phase",
        "schema_version", "stage_app", "staged_state", "target_release_state", "transaction_id",
        "trust_context", "unix_time", "validator_receipts",
    }
    if set(journal) != expected_keys or journal.get("schema_version") != JOURNAL_SCHEMA:
        fail("transaction journal fields differ from the journal schema")
    token = journal.get("transaction_id")
    if not isinstance(token, str) or HEX32.fullmatch(token) is None:
        fail("transaction journal has an invalid transaction ID")
    if journal.get("operation") not in {"install", "rollback"}:
        fail("transaction journal has an invalid operation")
    if journal.get("phase") not in {"prepared", "app-swapped", "state-committed"}:
        fail("transaction journal has an invalid phase")
    if journal.get("destination_app") != str(destination) or journal.get("expected_owner_uid") != expected_uid:
        fail("transaction journal is bound to another destination or owner")
    if not isinstance(journal.get("new_app"), dict):
        fail("transaction journal lacks target app evidence")
    if journal.get("old_app") is not None and not isinstance(journal.get("old_app"), dict):
        fail("transaction journal has invalid prior app evidence")
    if not isinstance(journal.get("had_active_state"), bool):
        fail("transaction journal has invalid active-state evidence")
    for field in ("target_release_state", "trust_context"):
        if not isinstance(journal.get(field), dict):
            fail(f"transaction journal has invalid {field}")
    if journal.get("current_release_state") is not None and not isinstance(journal.get("current_release_state"), dict):
        fail("transaction journal has invalid current_release_state")
    trust_context = journal["trust_context"]
    if set(trust_context) != {
        "key_id", "keyring_generation", "keyring_sha256", "public_key_spki_sha256",
        "revocations_generation", "revocations_sha256",
    }:
        fail("transaction journal trust context fields are invalid")
    for field in ("keyring_sha256", "public_key_spki_sha256", "revocations_sha256"):
        if not isinstance(trust_context.get(field), str) or HEX64.fullmatch(trust_context[field]) is None:
            fail("transaction journal trust context digest is invalid")
    for field in ("keyring_generation", "revocations_generation"):
        value = trust_context.get(field)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            fail("transaction journal trust context generation is invalid")
    if not isinstance(trust_context.get("key_id"), str) or not trust_context["key_id"]:
        fail("transaction journal trust context key ID is invalid")
    if isinstance(journal.get("unix_time"), bool) or not isinstance(journal.get("unix_time"), int) or journal["unix_time"] < 1:
        fail("transaction journal has an invalid timestamp")

    def bound_path(field: str, parent: pathlib.Path, prefix: str, *, optional: bool = False) -> pathlib.Path | None:
        value = journal.get(field)
        if optional and value is None:
            return None
        if not isinstance(value, str):
            fail(f"transaction journal has invalid {field}")
        candidate = require_absolute_clean(pathlib.Path(value), f"transaction journal {field}")
        if candidate.parent != parent or not candidate.name.startswith(prefix + token):
            fail(f"transaction journal has unsafe {field}")
        return candidate

    bound_path("stage_app", destination.parent, f".{destination.name}.stage-")
    backup_value = journal.get("backup_app")
    if backup_value is not None:
        candidate = require_absolute_clean(pathlib.Path(backup_value), "transaction journal backup_app")
        backup_pattern = re.compile(rf"^{re.escape('.' + destination.name + '.rollback-')}[0-9a-f]{{32}}$")
        if candidate.parent != destination.parent or backup_pattern.fullmatch(candidate.name) is None:
            fail("transaction journal has unsafe backup_app")
        if journal["operation"] == "install" and candidate.name != f".{destination.name}.rollback-{token}":
            fail("install journal rollback backup differs from its transaction ID")
    bound_path("failed_app", destination.parent, f".{destination.name}.rolled-back-", optional=True)
    obsolete = journal.get("obsolete_backup")
    if obsolete is not None:
        candidate = require_absolute_clean(pathlib.Path(obsolete), "transaction journal obsolete_backup")
        if candidate.parent != destination.parent or not candidate.name.startswith(f".{destination.name}.rollback-"):
            fail("transaction journal has unsafe obsolete_backup")
    bound_path("staged_state", state_dir, ".active-new-")
    bound_path("validator_receipts", state_dir, ".rollback-validator-", optional=True)

    receipt_root = state_dir / "rollback-authorizations"
    for field, prefix in (("pending_receipt", "pending-"), ("completed_receipt", "completed-")):
        value = journal.get(field)
        if value is None:
            continue
        candidate = require_absolute_clean(pathlib.Path(value), f"transaction journal {field}")
        if candidate.parent != receipt_root or not candidate.name.startswith(prefix) or candidate.suffix != ".json":
            fail(f"transaction journal has unsafe {field}")
    if journal["operation"] == "rollback":
        if not all(isinstance(journal.get(field), str) for field in (
            "authorization_nonce", "authorization_sha256", "backup_app", "failed_app",
            "pending_receipt", "completed_receipt", "validator_receipts",
        )):
            fail("rollback journal lacks authorization or app paths")
        if HEX64.fullmatch(journal["authorization_nonce"]) is None or HEX64.fullmatch(journal["authorization_sha256"]) is None:
            fail("rollback journal has invalid authorization evidence")
    elif any(journal.get(field) is not None for field in (
        "authorization_nonce", "authorization_sha256", "failed_app", "pending_receipt",
        "completed_receipt", "validator_receipts",
    )):
        fail("install journal unexpectedly contains rollback authorization evidence")
    return journal


def active_matches_journal(
    state_dir: pathlib.Path,
    journal: dict,
) -> bool:
    record, active = read_active(state_dir)
    if record is None or active is None:
        return False
    validate_active_release(record, active)
    return record.get("transaction_id") == journal["transaction_id"] and record.get("installed") == journal["new_app"]


def verify_target_app(destination: pathlib.Path, expected_uid: int, journal: dict) -> None:
    if evidence_if_present(destination, expected_uid) != journal["new_app"]:
        fail("transaction target app does not match journal evidence")


def rollback_receipt_value(journal: dict, status: str, transaction_sha256: str | None) -> dict:
    return {
        "authorization_sha256": journal["authorization_sha256"],
        "current": journal["current_release_state"],
        "nonce": journal["authorization_nonce"],
        "schema_version": ROLLBACK_RECEIPT_SCHEMA,
        "status": status,
        "target": journal["target_release_state"],
        "transaction_id": journal["transaction_id"],
        "transaction_sha256": transaction_sha256,
        "trust": journal["trust_context"],
    }


def validate_receipt(path: pathlib.Path, expected: dict, label: str) -> None:
    require_safe_file(path, label, {os.geteuid()})
    if strict_json(path, label) != expected or path.read_bytes() != canonical_json(expected):
        fail(f"{label} does not match exact transaction authorization evidence")


def rollback_receipt_paths(state_dir: pathlib.Path, nonce: str) -> tuple[pathlib.Path, pathlib.Path]:
    digest = hashlib.sha256(b"rollback\x00" + nonce.encode("ascii")).hexdigest()
    root = state_dir / "rollback-authorizations"
    return root / f"pending-{digest}.json", root / f"completed-{digest}.json"


def ensure_private_directory(path: pathlib.Path) -> None:
    if path.exists() or path.is_symlink():
        require_safe_directory(path, "rollback authorization receipt directory", {os.geteuid()})
        os.chmod(path, 0o700)
        return
    path.mkdir(mode=0o700)
    fsync_directory(path.parent)


def complete_rollback_receipt(state_dir: pathlib.Path, journal: dict) -> str:
    active_transaction = state_dir / "active" / "transaction.json"
    transaction_sha256 = sha256_file(active_transaction, "committed transaction state")
    pending = pathlib.Path(journal["pending_receipt"])
    completed = pathlib.Path(journal["completed_receipt"])
    pending_value = rollback_receipt_value(journal, "pending", None)
    completed_value = rollback_receipt_value(journal, "completed", transaction_sha256)
    if completed.exists():
        validate_receipt(completed, completed_value, "completed rollback authorization receipt")
    else:
        if not pending.exists():
            fail("committed rollback lacks its pending authorization receipt")
        validate_receipt(pending, pending_value, "pending rollback authorization receipt")
        write_file(completed, canonical_json(completed_value))
    if pending.exists():
        remove_path(pending)
    return transaction_sha256


def discard_pending_rollback(journal: dict) -> None:
    for field in ("pending_receipt", "validator_receipts"):
        value = journal.get(field)
        if isinstance(value, str):
            remove_path(pathlib.Path(value))


def restore_prepared_app(
    state_dir: pathlib.Path,
    destination: pathlib.Path,
    expected_uid: int,
    journal: dict,
) -> None:
    old = journal["old_app"]
    new = journal["new_app"]
    current = evidence_if_present(destination, expected_uid)
    stage = pathlib.Path(journal["stage_app"])
    backup = pathlib.Path(journal["backup_app"]) if journal["backup_app"] is not None else None
    failed_app = pathlib.Path(journal["failed_app"]) if journal["failed_app"] is not None else None
    if current == old:
        if journal["operation"] == "rollback":
            if backup is None:
                fail("prepared rollback lacks its exact target backup path")
            if evidence_if_present(backup, expected_uid) != new:
                if failed_app is None or evidence_if_present(failed_app, expected_uid) != new:
                    fail("prepared rollback cannot restore its exact target backup")
                durable_rename(failed_app, backup)
        elif backup is not None and evidence_if_present(backup, expected_uid) == new:
            remove_path(backup)
    elif current == new:
        candidates = [candidate for candidate in (stage, backup, failed_app) if candidate is not None]
        prior = next((candidate for candidate in candidates if evidence_if_present(candidate, expected_uid) == old), None)
        if old is None:
            remove_path(destination)
        elif prior is None:
            fail("prepared transaction cannot recover its exact prior app")
        else:
            rename_swap(destination, prior)
            if journal["operation"] == "rollback" and backup is not None and prior == failed_app:
                durable_rename(failed_app, backup)
            elif prior != backup or journal["operation"] == "install":
                remove_path(prior)
    else:
        fail("prepared transaction destination matches neither old nor target app")
    if evidence_if_present(destination, expected_uid) != old:
        fail("prepared transaction did not restore exact prior app")
    if stage.exists():
        if evidence_if_present(stage, expected_uid) != new:
            fail("prepared transaction staging app differs from target evidence")
        remove_path(stage)
    staged_state = pathlib.Path(journal["staged_state"])
    if staged_state.exists():
        remove_path(staged_state)
    discard_pending_rollback(journal)
    remove_path(journal_path(state_dir))


def commit_journal_state(state_dir: pathlib.Path, destination: pathlib.Path, expected_uid: int, journal: dict) -> dict:
    verify_target_app(destination, expected_uid, journal)
    staged_state = pathlib.Path(journal["staged_state"])
    if not active_matches_journal(state_dir, journal):
        if not staged_state.exists():
            fail("app-swapped transaction lacks staged target state")
        staged_record = strict_json(staged_state / "transaction.json", "staged target transaction evidence")
        if staged_record.get("transaction_id") != journal["transaction_id"] or staged_record.get("installed") != journal["new_app"]:
            fail("staged target state differs from journal evidence")
        replace_active_state(state_dir, staged_state)
        maybe_crash("after_state_swap_before_phase")
    if not active_matches_journal(state_dir, journal):
        fail("transaction could not commit exact target state")
    journal["phase"] = "state-committed"
    write_journal(state_dir, journal)
    maybe_crash("after_state_committed")
    return journal


def finalize_journal(state_dir: pathlib.Path, destination: pathlib.Path, expected_uid: int, journal: dict) -> dict:
    verify_target_app(destination, expected_uid, journal)
    if not active_matches_journal(state_dir, journal):
        fail("state-committed transaction lacks exact active target state")
    transaction_sha256 = sha256_file(state_dir / "active" / "transaction.json", "committed transaction state")
    if journal["operation"] == "rollback":
        transaction_sha256 = complete_rollback_receipt(state_dir, journal)
    for field in ("stage_app", "staged_state", "failed_app", "validator_receipts", "obsolete_backup"):
        value = journal.get(field)
        if isinstance(value, str):
            path = pathlib.Path(value)
            if path.exists() or path.is_symlink():
                remove_path(path)
    remove_path(journal_path(state_dir))
    return {
        "authorization_sha256": journal.get("authorization_sha256"),
        "transaction_sha256": transaction_sha256,
    }


def recover_journal(state_dir: pathlib.Path, destination: pathlib.Path, expected_uid: int) -> dict | None:
    journal = read_journal(state_dir, destination, expected_uid)
    if journal is None:
        return None
    if journal["phase"] == "prepared":
        restore_prepared_app(state_dir, destination, expected_uid, journal)
        return {"recovered": "old"}
    if journal["phase"] == "app-swapped":
        journal = commit_journal_state(state_dir, destination, expected_uid, journal)
    result = finalize_journal(state_dir, destination, expected_uid, journal)
    result["recovered"] = "new"
    return result


def ensure_state_dir(path: pathlib.Path) -> None:
    reject_symlink_ancestors(path, "state directory")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require_safe_directory(path, "state directory", {os.geteuid()})
    fsync_directory(path)


class Lock:
    def __init__(self, state_dir: pathlib.Path):
        self.path = state_dir / ".transaction-lock"
        self.descriptor: int | None = None

    def __enter__(self) -> "Lock":
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.descriptor = os.open(self.path, flags, 0o600)
        os.fchmod(self.descriptor, 0o600)
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.descriptor)
            self.descriptor = None
            fail("another Malibu app transaction is active")
        os.ftruncate(self.descriptor, 0)
        os.write(self.descriptor, f"{os.getpid()}\n".encode())
        os.fsync(self.descriptor)
        fsync_directory(self.path.parent)
        return self

    def __exit__(self, *_: object) -> None:
        if self.descriptor is not None:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = None


def maybe_fail(point: str) -> None:
    if os.environ.get(FAIL_ENV) == point:
        fail(f"injected failure at {point}")


def maybe_crash(point: str) -> None:
    if os.environ.get(CRASH_ENV) == point:
        os._exit(86)


def common_paths(args: argparse.Namespace) -> tuple[pathlib.Path, pathlib.Path, int]:
    destination = require_absolute_clean(pathlib.Path(args.destination_app), "destination app")
    state_dir = require_absolute_clean(pathlib.Path(args.state_dir), "state directory")
    if destination.name != "Malibu.app":
        fail("destination app path must end in Malibu.app")
    if state_dir.parts[-2:] != ("Malibu", "Release"):
        fail("state directory must end in Malibu/Release")
    expected_uid = args.expected_owner_uid
    if expected_uid < 0:
        fail("expected owner uid must be non-negative")
    reject_symlink_ancestors(destination.parent, "destination parent")
    require_safe_directory(destination.parent, "destination parent", {0, os.geteuid()})
    if state_dir == destination or destination in state_dir.parents or state_dir in destination.parents:
        fail("state directory and destination app must be separate")
    ensure_state_dir(state_dir)
    return destination, state_dir, expected_uid


def install(args: argparse.Namespace) -> None:
    expected_uid = args.expected_owner_uid
    if expected_uid < 0:
        fail("expected owner uid must be non-negative")
    if any(value < 1 for value in (
        args.minimum_keyring_generation,
        args.minimum_index_generation,
        args.minimum_envelope_generation,
    )):
        fail("minimum release generations must be positive")
    if not args.expected_key_id:
        fail("expected release signing key ID is required")
    source = require_absolute_clean(pathlib.Path(args.source_app), "source app")
    envelope = require_absolute_clean(pathlib.Path(args.envelope), "release envelope")
    index = require_absolute_clean(pathlib.Path(args.index), "release index")
    keyring = require_absolute_clean(pathlib.Path(args.keyring), "release keyring")
    revocations = require_absolute_clean(pathlib.Path(args.revocations), "release revocations")
    destination_lexical = require_absolute_clean(pathlib.Path(args.destination_app), "destination app")
    if source == destination_lexical or destination_lexical in source.parents or source in destination_lexical.parents:
        fail("source and destination app must be separate")
    source_evidence = tree_evidence(source, expected_uid)
    verify_source_app_signature(source)
    cryptographically_validate_release(
        envelope=envelope,
        index=index,
        keyring=keyring,
        revocations=revocations,
        expected_key_id=args.expected_key_id,
        minimum_keyring_generation=args.minimum_keyring_generation,
        minimum_index_generation=args.minimum_index_generation,
        minimum_envelope_generation=args.minimum_envelope_generation,
        minimum_build=source_evidence["build"],
        expected_uid=expected_uid,
    )
    envelope_sha256 = sha256_file(envelope, "release envelope")
    index_sha256 = sha256_file(index, "release index")
    release = validate_sidecars(envelope, index)
    if (
        source_evidence["bundle_id"] != BUNDLE_ID
        or source_evidence["marketing_version"] != release["app_version"]
        or source_evidence["build"] != release["app_build"]
        or source_evidence["entry_count"] != release["app_entry_count"]
        or source_evidence["root_mode"] != release["app_root_mode"]
        or source_evidence["tree_sha256"] != release["app_tree_sha256"]
    ):
        fail("source app evidence does not match the signed release sidecars")
    trust_context = validated_trust_context(keyring, revocations, args.expected_key_id)
    destination, state_dir, expected_uid = common_paths(args)
    if destination != destination_lexical:
        fail("destination changed during preflight")

    token = uuid.uuid4().hex
    stage = destination.parent / f".{destination.name}.stage-{token}"
    backup = destination.parent / f".{destination.name}.rollback-{token}"
    had_previous = False
    previous: dict | None = None
    result: dict | None = None
    with Lock(state_dir):
        recover_journal(state_dir, destination, expected_uid)
        active_record, active = read_active(state_dir)
        if active_record is not None and active is not None:
            validate_active_release(active_record, active)
            if active_record.get("destination_app") != str(destination):
                fail("active transaction evidence is bound to another destination")
        if destination.exists() or destination.is_symlink():
            previous = tree_evidence(destination, expected_uid)
            had_previous = True
        if active_record is not None and previous != active_record.get("installed"):
            fail("current app does not match active transaction evidence")
        legacy_source_app_version = None
        if active_record is None and previous is not None:
            legacy_versions = signed_legacy_source_versions(envelope, previous)
            if len(legacy_versions) > 1:
                fail("installed legacy app matches multiple signed source versions")
            legacy_source_app_version = next(iter(legacy_versions), None)
        if (
            active_record is not None
            and previous == source_evidence
            and active_record.get("release") == release
            and active_record.get("release_envelope_sha256") == envelope_sha256
            and active_record.get("release_index_sha256") == index_sha256
        ):
            transaction_sha256 = sha256_file(active / "transaction.json", "committed transaction state")
            print(json.dumps({
                "installed": source_evidence,
                "rollback_available": active_record.get("previous") is not None,
                "transaction_sha256": transaction_sha256,
            }, sort_keys=True))
            return
        old_backup = safe_old_backup(active_record, destination, expected_uid)
        copy_app(source, stage)
        staged = tree_evidence(stage, expected_uid, require_malibu_name=False)
        if staged != source_evidence:
            fail("staged app evidence differs from verified source")
        if previous is not None and staged["build"] <= previous["build"]:
            fail("normal app install must increase the Malibu build; use exact rollback evidence to go backward")
        maybe_fail("after_stage")
        record = {
            "destination_app": str(destination),
            "installed": staged,
            "installed_release_state": release_state(release, envelope_sha256),
            "legacy_source_app_version": legacy_source_app_version,
            "previous_release": active_record.get("release") if active_record is not None else None,
            "previous_release_index_sha256": active_record.get("release_index_sha256") if active_record is not None else None,
            "previous_release_state": active_record.get("installed_release_state") if active_record is not None else None,
            "release": release,
            "release_envelope_sha256": envelope_sha256,
            "release_index_sha256": index_sha256,
            "rollback_backup": str(backup) if had_previous else None,
            "previous": previous,
            "schema_version": SCHEMA,
            "state": "installed",
            "transaction_id": token,
            "unix_time": int(time.time()),
        }
        staged_state = make_state_stage(
            state_dir,
            record,
            envelope,
            index,
            token,
            previous_envelope=(active / "release-envelope.json") if active is not None else None,
            previous_index=(active / "release-index.json") if active is not None else None,
        )
        try:
            staged_envelope = staged_state / "release-envelope.json"
            staged_index = staged_state / "release-index.json"
            check_expected(sha256_file(staged_envelope, "staged release envelope"), envelope_sha256, "staged release envelope")
            check_expected(sha256_file(staged_index, "staged release index"), index_sha256, "staged release index")
            if validate_sidecars(staged_envelope, staged_index) != release:
                fail("staged release sidecars differ from verified release evidence")
            if active_record is not None:
                staged_previous_envelope = staged_state / "previous-release-envelope.json"
                staged_previous_index = staged_state / "previous-release-index.json"
                check_expected(
                    sha256_file(staged_previous_envelope, "staged previous release envelope"),
                    active_record["release_envelope_sha256"],
                    "staged previous release envelope",
                )
                check_expected(
                    sha256_file(staged_previous_index, "staged previous release index"),
                    active_record["release_index_sha256"],
                    "staged previous release index",
                )
                if validate_sidecars(staged_previous_envelope, staged_previous_index) != active_record["release"]:
                    fail("staged previous release sidecars differ from active evidence")
            journal = {
                "authorization_nonce": None,
                "authorization_sha256": None,
                "backup_app": str(backup) if had_previous else None,
                "completed_receipt": None,
                "current_release_state": active_record.get("installed_release_state") if active_record is not None else None,
                "destination_app": str(destination),
                "expected_owner_uid": expected_uid,
                "failed_app": None,
                "had_active_state": active_record is not None,
                "new_app": staged,
                "obsolete_backup": str(old_backup) if old_backup is not None else None,
                "old_app": previous,
                "operation": "install",
                "pending_receipt": None,
                "phase": "prepared",
                "schema_version": JOURNAL_SCHEMA,
                "stage_app": str(stage),
                "staged_state": str(staged_state),
                "target_release_state": release_state(release, envelope_sha256),
                "transaction_id": token,
                "trust_context": trust_context,
                "unix_time": int(time.time()),
                "validator_receipts": None,
            }
            write_journal(state_dir, journal)
            maybe_crash("after_journal_prepared")
            if had_previous:
                if tree_evidence(destination, expected_uid) != previous:
                    fail("destination app changed after preflight")
                rename_swap(stage, destination)
                durable_rename(stage, backup)
            else:
                durable_rename(stage, destination)
            if tree_evidence(destination, expected_uid) != staged:
                fail("installed app evidence differs from verified staging")
            maybe_crash("after_app_swap_before_phase")
            maybe_fail("after_replace")
            journal["phase"] = "app-swapped"
            write_journal(state_dir, journal)
            maybe_crash("after_app_swapped")
            journal = commit_journal_state(state_dir, destination, expected_uid, journal)
            result = finalize_journal(state_dir, destination, expected_uid, journal)
        except BaseException:
            if journal_path(state_dir).exists():
                recover_journal(state_dir, destination, expected_uid)
            raise
        finally:
            if not journal_path(state_dir).exists():
                if stage.exists():
                    remove_path(stage)
                if staged_state.exists():
                    remove_path(staged_state)
    if result is None:
        fail("install transaction completed without commit evidence")
    print(json.dumps({
        "installed": source_evidence,
        "rollback_available": had_previous,
        "transaction_sha256": result["transaction_sha256"],
    }, sort_keys=True))


def rollback(args: argparse.Namespace) -> None:
    destination, state_dir, expected_uid = common_paths(args)
    authorization = require_absolute_clean(pathlib.Path(args.authorization), "rollback authorization")
    keyring = require_absolute_clean(pathlib.Path(args.keyring), "release keyring")
    revocations = require_absolute_clean(pathlib.Path(args.revocations), "release revocations")
    if args.minimum_keyring_generation < 1 or not args.expected_key_id:
        fail("rollback trust minimum and expected key ID are required")
    authorization_document = strict_json(authorization, "rollback authorization")
    try:
        authorization_nonce = authorization_document["signed"]["nonce"]
    except (KeyError, TypeError):
        fail("rollback authorization lacks a nonce")
    if not isinstance(authorization_nonce, str) or HEX64.fullmatch(authorization_nonce) is None:
        fail("rollback authorization nonce is invalid")
    authorization_sha256 = sha256_file(authorization, "rollback authorization")
    if HEX64.fullmatch(args.expected_authorization_sha256 or "") is None:
        fail("expected rollback authorization digest is invalid")
    if authorization_sha256 != args.expected_authorization_sha256:
        fail("rollback authorization differs from the caller-validated bytes")
    trust_context = validated_trust_context(keyring, revocations, args.expected_key_id)
    token = uuid.uuid4().hex
    result: dict | None = None
    previous: dict | None = None
    with Lock(state_dir):
        recovery = recover_journal(state_dir, destination, expected_uid)
        record, active = read_active(state_dir)
        pending_receipt, completed_receipt = rollback_receipt_paths(state_dir, authorization_nonce)
        if (
            recovery is not None
            and recovery.get("recovered") == "new"
            and record is not None
            and active is not None
            and record.get("state") == "rolled_back"
            and record.get("rollback_authorization_sha256") == authorization_sha256
        ):
            transaction_sha256 = sha256_file(active / "transaction.json", "committed transaction state")
            completed_value = {
                "authorization_sha256": authorization_sha256,
                "current": record.get("rolled_back_from_release_state"),
                "nonce": authorization_nonce,
                "schema_version": ROLLBACK_RECEIPT_SCHEMA,
                "status": "completed",
                "target": record.get("installed_release_state"),
                "transaction_id": record.get("transaction_id"),
                "transaction_sha256": transaction_sha256,
                "trust": trust_context,
            }
            validate_receipt(completed_receipt, completed_value, "completed rollback authorization receipt")
            print(json.dumps({
                "rollback_authorization_sha256": authorization_sha256,
                "rolled_back_to": record.get("installed"),
                "transaction_sha256": transaction_sha256,
            }, sort_keys=True))
            return
        if completed_receipt.exists():
            fail("authorization: nonce was already consumed by a committed rollback")
        if pending_receipt.exists():
            fail("rollback authorization has an orphaned pending receipt")
        if record is None or active is None or record.get("state") != "installed":
            fail("no exact installed transaction is available for rollback")
        if record.get("destination_app") != str(destination):
            fail("active transaction evidence is bound to another destination")
        validate_active_release(record, active)
        current = tree_evidence(destination, expected_uid)
        if current != record.get("installed"):
            fail("installed app no longer matches exact rollback evidence")
        backup = safe_old_backup(record, destination, expected_uid)
        previous = record.get("previous")
        current_release_state = record.get("installed_release_state")
        target_release_state = record.get("previous_release_state")
        if backup is None or previous is None or not isinstance(target_release_state, dict):
            fail("operator rollback is disabled because no previously validated signed release is available")
        target_envelope = active / "previous-release-envelope.json"
        target_index = active / "previous-release-index.json"
        target_envelope_sha256 = sha256_file(target_envelope, "previous release envelope")
        target_index_sha256 = sha256_file(target_index, "previous release index")
        check_expected(target_envelope_sha256, target_release_state.get("envelope_sha256"), "previous release envelope")
        check_expected(target_index_sha256, record.get("previous_release_index_sha256"), "previous release index")
        target_release = validate_sidecars(target_envelope, target_index)
        if target_release != record.get("previous_release"):
            fail("previous release sidecars differ from exact transaction evidence")
        if release_state(target_release, target_envelope_sha256) != target_release_state:
            fail("previous release state differs from exact sidecar evidence")
        if (
            previous.get("build") != target_release.get("app_build")
            or previous.get("entry_count") != target_release.get("app_entry_count")
            or previous.get("root_mode") != target_release.get("app_root_mode")
            or previous.get("tree_sha256") != target_release.get("app_tree_sha256")
        ):
            fail("previous app tree differs from signed target release evidence")
        failed_new = destination.parent / f".{destination.name}.rolled-back-{token}"
        completion = dict(record)
        completion.update({
            "installed": previous,
            "installed_release_state": target_release_state,
            "legacy_source_app_version": None,
            "previous_release": None,
            "previous_release_index_sha256": None,
            "previous_release_state": None,
            "release": target_release,
            "release_envelope_sha256": target_envelope_sha256,
            "release_index_sha256": target_index_sha256,
            "rollback_backup": None,
            "rollback_authorization_sha256": authorization_sha256,
            "rolled_back_from": current,
            "rolled_back_from_release_state": current_release_state,
            "state": "rolled_back",
            "transaction_id": token,
            "unix_time": int(time.time()),
        })
        staged_state = make_state_stage(state_dir, completion, target_envelope, target_index, token)
        validator_receipts = state_dir / f".rollback-validator-{token}"
        failed_new = destination.parent / f".{destination.name}.rolled-back-{token}"
        try:
            if sha256_file(staged_state / "release-envelope.json", "staged rollback envelope") != target_envelope_sha256:
                fail("staged rollback envelope differs from exact transaction evidence")
            if sha256_file(staged_state / "release-index.json", "staged rollback index") != target_index_sha256:
                fail("staged rollback index differs from exact transaction evidence")
            journal = {
                "authorization_nonce": authorization_nonce,
                "authorization_sha256": authorization_sha256,
                "backup_app": str(backup),
                "completed_receipt": str(completed_receipt),
                "current_release_state": current_release_state,
                "destination_app": str(destination),
                "expected_owner_uid": expected_uid,
                "failed_app": str(failed_new),
                "had_active_state": True,
                "new_app": previous,
                "obsolete_backup": None,
                "old_app": current,
                "operation": "rollback",
                "pending_receipt": str(pending_receipt),
                "phase": "prepared",
                "schema_version": JOURNAL_SCHEMA,
                "stage_app": str(destination.parent / f".{destination.name}.stage-{token}"),
                "staged_state": str(staged_state),
                "target_release_state": target_release_state,
                "transaction_id": token,
                "trust_context": trust_context,
                "unix_time": int(time.time()),
                "validator_receipts": str(validator_receipts),
            }
            write_journal(state_dir, journal)
            maybe_crash("after_journal_prepared")
            authorize_operator_rollback(
                authorization=authorization,
                current_state=current_release_state,
                target_state=target_release_state,
                state_dir=state_dir,
                keyring=keyring,
                revocations=revocations,
                expected_key_id=args.expected_key_id,
                minimum_keyring_generation=args.minimum_keyring_generation,
                expected_uid=expected_uid,
                token=token,
                validator_receipts=validator_receipts,
            )
            ensure_private_directory(pending_receipt.parent)
            write_file(pending_receipt, canonical_json(rollback_receipt_value(journal, "pending", None)))
            maybe_crash("after_pending_receipt")
            rename_swap(destination, backup)
            durable_rename(backup, failed_new)
            if tree_evidence(destination, expected_uid) != previous:
                fail("rolled-back app differs from exact previous evidence")
            maybe_crash("after_app_swap_before_phase")
            maybe_fail("after_rollback_replace")
            journal["phase"] = "app-swapped"
            write_journal(state_dir, journal)
            maybe_crash("after_app_swapped")
            journal = commit_journal_state(state_dir, destination, expected_uid, journal)
            result = finalize_journal(state_dir, destination, expected_uid, journal)
        except BaseException:
            if journal_path(state_dir).exists():
                recover_journal(state_dir, destination, expected_uid)
            raise
        finally:
            if not journal_path(state_dir).exists() and staged_state.exists():
                remove_path(staged_state)
    if result is None or previous is None:
        fail("rollback transaction completed without commit evidence")
    print(json.dumps({
        "rollback_authorization_sha256": authorization_sha256,
        "rolled_back_to": previous,
        "transaction_sha256": result["transaction_sha256"],
    }, sort_keys=True))


def inspect(args: argparse.Namespace) -> None:
    app = require_absolute_clean(pathlib.Path(args.app), "app")
    print(json.dumps(tree_evidence(app, args.expected_owner_uid), sort_keys=True))


def recover(args: argparse.Namespace) -> None:
    destination, state_dir, expected_uid = common_paths(args)
    with Lock(state_dir):
        recovery = recover_journal(state_dir, destination, expected_uid)
        record, active = read_active(state_dir)
        if record is not None and active is not None:
            validate_active_release(record, active)
            if record.get("destination_app") != str(destination):
                fail("active transaction evidence is bound to another destination")
            if evidence_if_present(destination, expected_uid) != record.get("installed"):
                fail("recovered app does not match active transaction evidence")
            transaction_sha256 = sha256_file(active / "transaction.json", "committed transaction state")
            state = record.get("state")
            authorization_sha256 = record.get("rollback_authorization_sha256")
        else:
            transaction_sha256 = None
            state = None
            authorization_sha256 = None
    print(json.dumps({
        "recovered": recovery["recovered"] if recovery is not None else "none",
        "rollback_authorization_sha256": authorization_sha256,
        "state": state,
        "transaction_sha256": transaction_sha256,
    }, sort_keys=True))


def verify_bundle(args: argparse.Namespace) -> None:
    expected_uid = args.expected_owner_uid
    envelope = require_absolute_clean(pathlib.Path(args.envelope), "release envelope")
    index = require_absolute_clean(pathlib.Path(args.index), "release index")
    keyring = require_absolute_clean(pathlib.Path(args.keyring), "release keyring")
    revocations = require_absolute_clean(pathlib.Path(args.revocations), "release revocations")
    cryptographically_validate_release(
        envelope=envelope,
        index=index,
        keyring=keyring,
        revocations=revocations,
        expected_key_id=args.expected_key_id,
        minimum_keyring_generation=args.minimum_keyring_generation,
        minimum_index_generation=args.minimum_index_generation,
        minimum_envelope_generation=args.minimum_envelope_generation,
        minimum_build=args.minimum_build,
        expected_uid=expected_uid,
    )
    document = strict_json(envelope, "release envelope")
    try:
        app = document["signed"]["app"]
        dmg = document["signed"]["artifacts"]["dmg"]
    except (KeyError, TypeError):
        fail("release envelope lacks app/DMG binding")
    if not isinstance(dmg, dict) or set(dmg) != {"name", "sha256"}:
        fail("release envelope DMG binding is invalid")
    name = dmg.get("name")
    digest = dmg.get("sha256")
    if not isinstance(name, str) or pathlib.Path(name).name != name or "/" in name or "\\" in name:
        fail("release envelope DMG name is unsafe")
    if not isinstance(digest, str) or HEX64.fullmatch(digest) is None:
        fail("release envelope DMG digest is invalid")
    print(json.dumps({
        "app_build": app["build"],
        "app_version": app["marketing_version"],
        "dmg_name": name,
        "dmg_sha256": digest,
    }, sort_keys=True))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    inspect_parser = commands.add_parser("inspect", help="emit deterministic app evidence without mutation")
    inspect_parser.add_argument("--app", required=True)
    inspect_parser.add_argument("--expected-owner-uid", type=int, default=os.geteuid())
    inspect_parser.set_defaults(handler=inspect)
    recover_parser = commands.add_parser("recover", help="reconcile an interrupted app/state transaction")
    recover_parser.add_argument("--destination-app", required=True)
    recover_parser.add_argument("--state-dir", required=True)
    recover_parser.add_argument("--expected-owner-uid", type=int, default=os.geteuid())
    recover_parser.set_defaults(handler=recover)
    verify_parser = commands.add_parser("verify-bundle", help="cryptographically validate sidecars and emit exact DMG binding")
    verify_parser.add_argument("--envelope", required=True)
    verify_parser.add_argument("--index", required=True)
    verify_parser.add_argument("--keyring", required=True)
    verify_parser.add_argument("--revocations", required=True)
    verify_parser.add_argument("--expected-key-id", required=True)
    verify_parser.add_argument("--minimum-keyring-generation", required=True, type=int)
    verify_parser.add_argument("--minimum-index-generation", required=True, type=int)
    verify_parser.add_argument("--minimum-envelope-generation", required=True, type=int)
    verify_parser.add_argument("--minimum-build", required=True, type=int)
    verify_parser.add_argument("--expected-owner-uid", type=int, default=os.geteuid())
    verify_parser.set_defaults(handler=verify_bundle)
    for name, handler in (("install", install), ("rollback", rollback)):
        command = commands.add_parser(name)
        command.add_argument("--destination-app", required=True)
        command.add_argument("--state-dir", required=True)
        command.add_argument("--expected-owner-uid", type=int, default=os.geteuid())
        command.set_defaults(handler=handler)
        if name == "install":
            command.add_argument("--source-app", required=True)
            command.add_argument("--envelope", required=True)
            command.add_argument("--index", required=True)
            command.add_argument("--keyring", required=True)
            command.add_argument("--revocations", required=True)
            command.add_argument("--expected-key-id", required=True)
            command.add_argument("--minimum-keyring-generation", required=True, type=int)
            command.add_argument("--minimum-index-generation", required=True, type=int)
            command.add_argument("--minimum-envelope-generation", required=True, type=int)
        else:
            command.add_argument("--authorization", required=True)
            command.add_argument("--expected-authorization-sha256", required=True)
            command.add_argument("--keyring", required=True)
            command.add_argument("--revocations", required=True)
            command.add_argument("--expected-key-id", required=True)
            command.add_argument("--minimum-keyring-generation", required=True, type=int)
    return result


def main() -> int:
    try:
        args = parser().parse_args()
        args.handler(args)
        return 0
    except (OSError, TransactionError) as error:
        print(f"malibu-app-transaction: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
