#!/usr/bin/env python3
"""Crash-recoverable, secret-free config transaction for Qwen live E2E.

This helper intentionally understands only top-level YAML fields.  It never
copies the complete provider config into its journal: only the allowlisted
fields owned by this transaction are recorded.  Every write is performed
under the provider CLI's config lock, validated by the installed CLI, fsynced,
and atomically renamed.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator


LEGACY_SCHEMA = "macprovider.qwen_provider_transaction.v1"
PROFILE_SCHEMA = "macprovider.qwen_provider_transaction.v2"
SCHEMA = LEGACY_SCHEMA
TOP_LEVEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(?:[ \t].*)?(?:\r?\n)?$")
SAFE_VALUE = re.compile(r"^[A-Za-z0-9._/@+-]+$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
HEX_CODE = re.compile(r"^[0-9a-f]{40,64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PROVIDER_LABEL = "live.malibu.provider"

RECOMMENDATION_OWNED = (
    "model",
    "model_artifact_path",
    "model_artifact_sha256",
    "model_catalog_key",
    "model_catalog_model_id",
    "model_catalog_revision",
    "model_catalog_sha256",
    "model_catalog_version",
    "model_catalog_hash",
    "kv_bits",
    "max_context_override",
    "max_concurrency_override",
    "max_concurrency_depth_override",
    "max_concurrency_source",
    "donor_mode",
    "max_context_override_provenance",
)
TRANSACTION_OWNED = RECOMMENDATION_OWNED + (
    "supported_models",
    "publishes_supported_models",
    "enable_warm_swap",
)

TARGETS: dict[str, dict[str, str]] = {
    "qwen3-8b": {
        "gateway_id": "qwen3-8b",
        "catalog_key": "qwen3-8b",
        "model_id": "mlx-community/Qwen3-8B-4bit",
        "revision": "545dc4251c05440727734bcd94334791f6ab0192",
        "sha256": "1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877",
    },
    "qwen3-coder-30b-a3b-instruct": {
        "gateway_id": "qwen3-coder-30b-a3b-instruct",
        "catalog_key": "qwen3-coder-30b-a3b-instruct",
        "model_id": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
        "revision": "6e302ea604ad9ab206367e2c501d1571023e7b6d",
        "sha256": "10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0",
    },
    "qwen3-30b-a3b-instruct-2507": {
        "gateway_id": "qwen3-30b-a3b-instruct-2507",
        "catalog_key": "qwen/qwen3-30b-a3b-instruct-2507",
        "model_id": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
        "revision": "e9675aa3ca5f900ccef55267914466d55ab325fa",
        "sha256": "a0ca3d59f301f08ae4c4c2010b07f80b890d35f4e8562c213b1d01aed8328e42",
    },
    "qwen3.6-35b-a3b": {
        "gateway_id": "qwen/qwen3.6-35b-a3b",
        "catalog_key": "qwen/qwen3.6-35b-a3b",
        "model_id": "mlx-community/Qwen3.6-35B-A3B-4bit",
        "revision": "38740b847e4cb78f352aba30aa41c76e08e6eb46",
        "sha256": "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1",
    },
}

LEGACY_PROFILE = "opencode-dual-30b"
NATIVE_MTP_PROFILE = "qwen36-native-mtp"
AIR_PROFILE = "air-qwen8-adoption"
PROFILES: dict[str, dict[str, Any]] = {
    AIR_PROFILE: {
        "schema": PROFILE_SCHEMA,
        "targets": ("qwen3-8b",),
        "adopting": ("adopting_target",),
        "serving": ("serving_target",),
        "complete": "proof_complete",
        "context_floor": 4_000,
    },
    LEGACY_PROFILE: {
        "schema": LEGACY_SCHEMA,
        "targets": ("qwen3-coder-30b-a3b-instruct", "qwen3-30b-a3b-instruct-2507"),
        "adopting": ("adopting_first", "adopting_second"),
        "serving": ("serving_first", "serving_second"),
        "complete": "acceptance_complete",
        "context_floor": 16_384,
    },
    NATIVE_MTP_PROFILE: {
        "schema": PROFILE_SCHEMA,
        "targets": ("qwen3.6-35b-a3b",),
        "adopting": ("adopting_target",),
        "serving": ("serving_target",),
        "complete": "proof_complete",
        "context_floor": 4_096,
    },
}

GLM_INCUMBENT = {
    "model": "zai-org/glm-5.3-flash",
    "model_artifact_sha256": "7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9",
}


class Refusal(Exception):
    pass


def absolute_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise Refusal("path must be absolute")
    return path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def strict_json(path: Path) -> dict[str, Any]:
    def pairs(values: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in values:
            if key in result:
                raise Refusal(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise Refusal(f"cannot read valid JSON: {path}") from exc
    if not isinstance(value, dict):
        raise Refusal("JSON root must be an object")
    return value


def safe_regular(path: Path, *, may_absent: bool = False) -> os.stat_result | None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        if may_absent:
            return None
        raise Refusal(f"missing file: {path}")
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise Refusal(f"not a single-link regular file: {path}")
    if info.st_uid != os.getuid():
        raise Refusal(f"file is not owned by the current uid: {path}")
    return info


def config_lock_path(config: Path) -> Path:
    return config.with_name(f".{config.name}.lock")


@contextlib.contextmanager
def config_lock(config: Path) -> Iterator[None]:
    lock = config_lock_path(config)
    descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise Refusal("unsafe config lock file")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def owned_keys(profile: str | None = None) -> tuple[str, ...]:
    return TRANSACTION_OWNED + (("mlx_cache_limit_mb",) if profile == AIR_PROFILE else ())


def split_blocks(data: bytes, profile: str | None = None) -> tuple[list[tuple[str | None, bytes]], dict[str, bytes]]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Refusal("config is not UTF-8") from exc
    lines = text.splitlines(keepends=True)
    blocks: list[tuple[str | None, bytes]] = []
    seen: set[str] = set()
    current_key: str | None = None
    current: list[str] = []

    def flush() -> None:
        nonlocal current
        if current:
            blocks.append((current_key, "".join(current).encode("utf-8")))
            current = []

    for line in lines:
        if line.startswith("\t"):
            raise Refusal("tabs are not accepted in provider config")
        match = TOP_LEVEL.match(line) if line and not line[0].isspace() else None
        if match:
            flush()
            current_key = match.group(1)
            if current_key in seen:
                raise Refusal(f"duplicate top-level config key: {current_key}")
            seen.add(current_key)
        elif line and not line[0].isspace() and line.lstrip().startswith("#"):
            flush()
            current_key = None
        elif line and not line[0].isspace() and not line.lstrip().startswith("#") and line.strip():
            raise Refusal("unsupported top-level YAML syntax")
        current.append(line)
    flush()
    owned = {key: raw for key, raw in blocks if key in owned_keys(profile)}
    return blocks, owned


def without_owned(blocks: list[tuple[str | None, bytes]], profile: str | None = None) -> bytes:
    return b"".join(raw for key, raw in blocks if key not in owned_keys(profile))


def render(blocks: list[tuple[str | None, bytes]], replacements: dict[str, bytes], profile: str | None = None) -> bytes:
    output = bytearray()
    inserted = False
    for key, raw in blocks:
        if key in owned_keys(profile):
            if not inserted:
                for owned_key in owned_keys(profile):
                    if owned_key in replacements:
                        output.extend(replacements[owned_key])
                inserted = True
            continue
        output.extend(raw)
    if not inserted:
        if output and not output.endswith(b"\n"):
            output.extend(b"\n")
        for owned_key in owned_keys(profile):
            if owned_key in replacements:
                output.extend(replacements[owned_key])
    return bytes(output)


def scalar(owned: dict[str, bytes], key: str) -> str:
    raw = owned.get(key)
    if raw is None:
        raise Refusal(f"config is missing required key: {key}")
    first = raw.decode("utf-8").splitlines()[0]
    value = first.split(":", 1)[1].strip()
    if not value or not SAFE_VALUE.fullmatch(value):
        raise Refusal(f"config key {key} is not a safe plain scalar")
    return value


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def write_journal(path: Path, journal: dict[str, Any], *, exclusive: bool = False) -> None:
    if exclusive and path.exists():
        raise Refusal("transaction journal already exists")
    payload = json.dumps(journal, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    atomic_write(path, payload)


def profile_name(args: argparse.Namespace) -> str:
    value = getattr(args, "profile", LEGACY_PROFILE)
    if value not in PROFILES:
        raise Refusal("unsupported transaction profile")
    return value


def journal_profile(journal: dict[str, Any]) -> str:
    schema = journal.get("schema_version")
    if schema == LEGACY_SCHEMA:
        if "profile" in journal:
            raise Refusal("legacy journal cannot carry a profile")
        return LEGACY_PROFILE
    if schema == PROFILE_SCHEMA and journal.get("profile") in {NATIVE_MTP_PROFILE, AIR_PROFILE}:
        return journal["profile"]
    raise Refusal("unsupported transaction journal schema")


def load_journal(path: Path) -> dict[str, Any]:
    safe_regular(path)
    journal = strict_json(path)
    profile = journal_profile(journal)
    profile_spec = PROFILES[profile]
    if journal.get("config_path") is None or journal.get("phase") is None:
        raise Refusal("incomplete transaction journal")
    if (not isinstance(journal["config_path"], str)
            or not Path(journal["config_path"]).is_absolute()):
        raise Refusal("invalid journal config path")
    phases = ({"armed", "prepared", "restoring", "config_restored", "restored"}
              | set(profile_spec["adopting"]) | set(profile_spec["serving"])
              | {profile_spec["complete"]})
    if profile == AIR_PROFILE:
        phases.add("committed")
    if journal["phase"] not in phases:
        raise Refusal("invalid transaction phase")
    allowed = {"schema_version", "transaction_id", "config_path", "phase", "baseline_owned",
               "unowned_sha256", "prepared_config_sha256", "prepared_supported_models_sha256",
               "last_config_sha256",
               "intended_owned", "intended_target", "release_binding", "baseline_status",
               "market_binding", "intended_after_unix", "remote_scratch"}
    if profile != LEGACY_PROFILE:
        allowed.add("profile")
    if profile == AIR_PROFILE:
        allowed.add("paid_proof_sha256")
        if journal["phase"] == "committed" and not HEX64.fullmatch(str(journal.get("paid_proof_sha256", ""))):
            raise Refusal("committed adoption lacks paid proof binding")
    if set(journal) - allowed:
        raise Refusal("transaction journal contains unsupported fields")
    baseline = journal.get("baseline_owned")
    if not isinstance(baseline, dict) or set(baseline) - set(owned_keys(profile)):
        raise Refusal("invalid owned-field snapshot")
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in baseline.items()):
        raise Refusal("invalid owned-field snapshot values")
    release = journal.get("release_binding")
    if not isinstance(release, dict) or set(release) != {
        "binary_version", "provider_id", "cli_sha256", "code_cdhash", "team_id",
        "signing_identifier", "written_handoff_sha256",
    }:
        raise Refusal("invalid release binding")
    if not SEMVER.fullmatch(str(release.get("binary_version", ""))):
        raise Refusal("invalid bound binary version")
    if not HEX64.fullmatch(str(release.get("cli_sha256", ""))):
        raise Refusal("invalid bound CLI digest")
    if not HEX_CODE.fullmatch(str(release.get("code_cdhash", ""))):
        raise Refusal("invalid bound code digest")
    for key in ("provider_id", "team_id", "signing_identifier"):
        value = release.get(key)
        if not isinstance(value, str) or not SAFE_VALUE.fullmatch(value):
            raise Refusal(f"invalid release binding field: {key}")
    if not HEX64.fullmatch(str(release.get("written_handoff_sha256", ""))):
        raise Refusal("invalid written handoff digest")
    baseline_status = journal.get("baseline_status")
    if not isinstance(baseline_status, dict) or set(baseline_status) != {
        "catalog_version", "catalog_hash", "pid",
    }:
        raise Refusal("invalid baseline status binding")
    if (not isinstance(baseline_status.get("catalog_version"), str)
            or not SAFE_VALUE.fullmatch(baseline_status["catalog_version"])
            or not HEX64.fullmatch(str(baseline_status.get("catalog_hash", "")))
            or type(baseline_status.get("pid")) is not int
            or baseline_status["pid"] < 1):
        raise Refusal("invalid baseline status values")
    market = journal.get("market_binding")
    if (not isinstance(market, dict) or set(market) != {"rate_card_version"}
            or not isinstance(market.get("rate_card_version"), str)
            or not SAFE_VALUE.fullmatch(market["rate_card_version"])):
        raise Refusal("invalid market binding")
    remote_scratch = journal.get("remote_scratch")
    if (not isinstance(remote_scratch, str) or not remote_scratch.startswith("/")
            or not Path(remote_scratch).name.startswith("macprovider-qwen-e2e.")):
        raise Refusal("invalid remote scratch binding")
    for key in ("unowned_sha256", "prepared_config_sha256", "prepared_supported_models_sha256",
                "last_config_sha256"):
        if not HEX64.fullmatch(str(journal.get(key, ""))):
            raise Refusal(f"invalid journal digest: {key}")
    intended = journal.get("intended_owned")
    if intended is not None and (not isinstance(intended, dict)
                                 or set(intended) - set(RECOMMENDATION_OWNED)
                                 or not all(isinstance(key, str) and isinstance(value, str)
                                            for key, value in intended.items())):
        raise Refusal("invalid intended owned fields")
    intended_after = journal.get("intended_after_unix")
    if intended_after is not None and (type(intended_after) is not int or intended_after < 1):
        raise Refusal("invalid intended transition timestamp")
    if (intended is None) != (journal.get("intended_target") is None):
        raise Refusal("incomplete intended transition")
    if intended is None and intended_after is not None:
        raise Refusal("orphan intended transition timestamp")
    if intended is not None and (journal["phase"] not in set(profile_spec["adopting"]) | {"restoring"}
                                 or journal.get("intended_target") not in profile_spec["targets"]
                                 or intended_after is None):
        raise Refusal("invalid intended transition state")
    return journal


def run_validator(validator: Path, candidate: Path) -> None:
    safe_regular(validator)
    if not os.access(validator, os.X_OK) or not validator.is_absolute():
        raise Refusal("validator must be an absolute executable regular file")
    result = subprocess.run(
        [str(validator), "models", "list", "--json", "--config", str(candidate)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise Refusal("installed CLI rejected candidate config")


def restart_service(args: argparse.Namespace) -> dict[str, Any]:
    """Restart an identity-checked loaded job even when it has no current PID.

    The ops caller must first verify the published signed release and hold the
    live-ops lock. This is not a release-verification or readiness shortcut.
    """
    config = absolute_path(args.config)
    binary = absolute_path(args.validator)
    for path in (config, binary):
        info = safe_regular(path)
        if info.st_mode & 0o022:
            raise Refusal("provider executable/config is group or world writable")
    expected_binary = str(binary.resolve(strict=True))
    expected_config = str(config.resolve(strict=True))
    home = Path.home().resolve(strict=True)
    directory = home / "Library" / "LaunchAgents"
    for parent in (home, home / "Library", directory):
        info = parent.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o022):
            raise Refusal("unsafe provider LaunchAgent directory")
    plist = directory / f"{PROVIDER_LABEL}.plist"
    safe_regular(plist)
    descriptor = os.open(plist, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.getuid() or info.st_mode & 0o022
                or info.st_size > 64 * 1024):
            raise Refusal("unsafe provider LaunchAgent plist")
        try:
            document = plistlib.loads(stream.read(64 * 1024 + 1))
        except Exception as exc:
            raise Refusal("invalid provider LaunchAgent plist") from exc

    def bound_path(value: Any, expected: str) -> bool:
        return (isinstance(value, str) and os.path.isabs(value)
                and os.path.realpath(value) == expected)

    def bound_arguments(arguments: Any) -> bool:
        return (isinstance(arguments, list) and len(arguments) == 4
                and bound_path(arguments[0], expected_binary)
                and arguments[1:3] == ["serve", "--config"]
                and bound_path(arguments[3], expected_config))

    if (not isinstance(document, dict) or document.get("Label") != PROVIDER_LABEL
            or not bound_arguments(document.get("ProgramArguments"))
            or ("Program" in document
                and not bound_path(document["Program"], expected_binary))):
        raise Refusal("provider LaunchAgent executable/config mismatch")
    target = f"gui/{os.getuid()}/{PROVIDER_LABEL}"
    launch = subprocess.run(
        ["/bin/launchctl", "print", target], stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=15, check=False,
    )
    if launch.returncode != 0:
        raise Refusal("provider LaunchAgent is not loaded or cannot be inspected")
    # launchctl print uses one tab for job fields and two for arguments.
    # Match only these top-level fields: environment values are not identity.
    programs = re.findall(r"(?m)^\tprogram = ([^\n]+)$", launch.stdout)
    paths = re.findall(r"(?m)^\tpath = ([^\n]+)$", launch.stdout)
    argument_blocks = re.findall(
        r"(?m)^\targuments = \{\n((?:\t\t[^\n]*\n)*)\t\}$", launch.stdout,
    )
    arguments = ([line[2:] for line in argument_blocks[0].splitlines()]
                 if len(argument_blocks) == 1 else None)
    if (len(programs) != 1 or not bound_path(programs[0], expected_binary)
            or len(paths) != 1 or not bound_path(paths[0], str(plist))
            or not bound_arguments(arguments)):
        raise Refusal("loaded provider LaunchAgent executable/config mismatch")
    run_validator(binary, config)
    restarted = subprocess.run(
        ["/bin/launchctl", "kickstart", "-k", target], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30, check=False,
    )
    if restarted.returncode != 0:
        raise Refusal("provider LaunchAgent kickstart failed")
    return {"status": "restart_requested", "service": target}


def validate_then_replace(config: Path, validator: Path, candidate: bytes) -> str:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{config.name}.validate.", dir=config.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(candidate)
            stream.flush()
            os.fsync(stream.fileno())
        run_validator(validator, temporary)
        os.replace(temporary, config)
        directory = os.open(config.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return sha256(candidate)


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    config = absolute_path(args.config)
    journal_path = absolute_path(args.journal)
    validator = absolute_path(args.validator)
    profile = profile_name(args)
    profile_spec = PROFILES[profile]
    safe_regular(config)
    if safe_regular(journal_path, may_absent=True) is not None:
        existing = load_journal(journal_path)
        if existing["phase"] != "restored":
            raise Refusal("unfinished transaction must be restored first")
        journal_path.unlink()
    with config_lock(config):
        original = config.read_bytes()
        blocks, owned = split_blocks(original, profile)
        present_keys = {key for key, _ in blocks if key is not None}
        unsupported_draft = present_keys.intersection({
            "draft_model", "draft_model_artifact_path", "draft_model_artifact_sha256",
        })
        if unsupported_draft:
            raise Refusal("draft model config is unsupported by this transaction: "
                          + ", ".join(sorted(unsupported_draft)))
        incumbent = scalar(owned, "model")
        if profile == NATIVE_MTP_PROFILE:
            for key, expected in GLM_INCUMBENT.items():
                if scalar(owned, key) != expected:
                    raise Refusal(f"native-MTP profile requires exact signed GLM incumbent {key}")
        supported = [incumbent] + [TARGETS[name]["catalog_key"]
                                   for name in profile_spec["targets"]]
        deduplicated = list(dict.fromkeys(supported))
        replacements = dict(owned)
        replacements["supported_models"] = (
            "supported_models:\n" + "".join(f"  - {model}\n" for model in deduplicated)
        ).encode()
        # Supported models are needed for local operator adoption.  Publication
        # is not: retaining the default false avoids exposing cold targets.
        replacements["publishes_supported_models"] = b"publishes_supported_models: false\n"
        replacements["enable_warm_swap"] = b"enable_warm_swap: true\n"
        if profile == AIR_PROFILE:
            # Replay the qualified Air memory profile, never a concurrency pin.
            replacements["mlx_cache_limit_mb"] = b"mlx_cache_limit_mb: 512\n"
        candidate = render(blocks, replacements, profile)
        base_unowned = sha256(without_owned(blocks, profile))
        baseline = {key: value.decode("utf-8") for key, value in owned.items()}
        transaction = {
            "schema_version": profile_spec["schema"],
            "transaction_id": args.transaction_id,
            "config_path": str(config),
            "phase": "armed",
            "baseline_owned": baseline,
            "unowned_sha256": base_unowned,
            "prepared_config_sha256": sha256(candidate),
            "prepared_supported_models_sha256": sha256(replacements["supported_models"]),
            "last_config_sha256": sha256(original),
            "release_binding": {
                "binary_version": args.binary_version,
                "provider_id": args.provider_id,
                "cli_sha256": args.cli_sha256,
                "code_cdhash": args.code_cdhash,
                "team_id": args.team_id,
                "signing_identifier": args.signing_identifier,
                "written_handoff_sha256": args.written_handoff_sha256,
            },
            "baseline_status": {
                "catalog_version": args.baseline_catalog_version,
                "catalog_hash": args.baseline_catalog_hash,
                "pid": args.baseline_pid,
            },
            "market_binding": {"rate_card_version": args.rate_card_version},
            "remote_scratch": args.remote_scratch,
        }
        if profile != LEGACY_PROFILE:
            transaction["profile"] = profile
        # Validate the complete journal schema before arming it on disk.
        for value, pattern, label in (
            (args.binary_version, SEMVER, "binary version"),
            (args.cli_sha256, HEX64, "CLI digest"),
            (args.code_cdhash, HEX_CODE, "code digest"),
            (args.written_handoff_sha256, HEX64, "written handoff digest"),
            (args.baseline_catalog_hash, HEX64, "catalog digest"),
        ):
            if not pattern.fullmatch(value):
                raise Refusal(f"invalid {label}")
        for value, label in (
            (args.provider_id, "provider id"), (args.team_id, "team id"),
            (args.signing_identifier, "signing identifier"),
            (args.baseline_catalog_version, "catalog version"),
            (args.rate_card_version, "rate card version"),
        ):
            if not SAFE_VALUE.fullmatch(value):
                raise Refusal(f"invalid {label}")
        if args.baseline_pid < 1:
            raise Refusal("invalid baseline pid")
        if (not args.remote_scratch.startswith("/")
                or not Path(args.remote_scratch).name.startswith("macprovider-qwen-e2e.")):
            raise Refusal("invalid remote scratch path")
        write_journal(journal_path, transaction, exclusive=True)
        current = config.read_bytes()
        if sha256(current) != transaction["last_config_sha256"]:
            raise Refusal("config changed after snapshot")
        # The armed journal deliberately survives every failure from here on.
        # In particular, rename may succeed and directory fsync may fail.
        applied = validate_then_replace(config, validator, candidate)
        transaction["phase"] = "prepared"
        transaction["last_config_sha256"] = applied
        write_journal(journal_path, transaction)
    return {"status": "prepared", "transaction_id": args.transaction_id,
            "config_sha256": transaction["last_config_sha256"]}


def expected_owned(args: argparse.Namespace) -> dict[str, str]:
    verify_recommendation(args)
    serve = strict_json(Path(args.recommendation))["serve_config"]
    expected: dict[str, str] = {}
    for key in RECOMMENDATION_OWNED:
        if key in ("max_context_override_provenance", "max_concurrency_source",
                   "max_concurrency_override", "max_concurrency_depth_override", "donor_mode"):
            continue
        value = serve.get(key)
        if value is None:
            continue
        if isinstance(value, bool):
            expected[key] = "true" if value else "false"
        elif isinstance(value, (str, int)) and not isinstance(value, float):
            expected[key] = str(value)
        else:
            raise Refusal(f"unsupported recommendation value for {key}")
    batch = serve.get("max_concurrency_override")
    if type(batch) is not int or batch < 1:
        raise Refusal("recommendation max concurrency is invalid")
    if serve.get("donor_mode") is not False:
        raise Refusal("Qwen acceptance requires donor_mode false")
    expected["max_concurrency_override"] = str(min(batch, 8))
    if batch > 8:
        expected["max_concurrency_depth_override"] = str(batch)
    expected["max_context_override_provenance"] = (
        f"recommendation_apply:{serve['max_context_override']}:{serve['model']}"
    )
    return expected


def generated_provenance_matches(raw: bytes | None, marker: str, intended_after: int | None) -> bool:
    if raw is None or intended_after is None:
        return False
    try:
        source, value, model = marker.split(":", 2)
        line = raw.decode("utf-8").strip()
    except (UnicodeError, ValueError):
        return False
    pattern = re.compile(
        r'^max_context_override_provenance: \{source: "recommendation_apply", value: ([0-9]+), '
        r'model: "([^"\\]+)", generated_at: "([0-9T:.+-]+Z)"\}$'
    )
    match = pattern.fullmatch(line)
    if not match or source != "recommendation_apply" or match.group(1) != value or match.group(2) != model:
        return False
    try:
        generated = int(datetime.fromisoformat(match.group(3).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return False
    return intended_after <= generated <= int(time.time()) + 60


def owned_matches_intent(
    owned: dict[str, bytes], expected: dict[str, str], intended_after: int | None,
    supported_models_sha256: str,
) -> bool:
    if expected.get("model") == "qwen3-8b" and scalar(owned, "mlx_cache_limit_mb") != "512":
        return False
    if sha256(owned.get("supported_models", b"")) != supported_models_sha256:
        return False
    for key in RECOMMENDATION_OWNED:
        if key == "max_context_override_provenance":
            if key not in expected:
                if key in owned:
                    return False
                continue
            if not generated_provenance_matches(owned.get(key), expected[key], intended_after):
                return False
            continue
        if key in expected:
            try:
                if scalar(owned, key) != expected[key]:
                    return False
            except Refusal:
                return False
        elif key in owned:
            return False
    try:
        return (scalar(owned, "enable_warm_swap") == "true"
                and scalar(owned, "publishes_supported_models") == "false")
    except Refusal:
        return False


def begin_adoption(args: argparse.Namespace) -> dict[str, Any]:
    config = absolute_path(args.config)
    journal_path = absolute_path(args.journal)
    intended = expected_owned(args)
    with config_lock(config):
        journal = load_journal(journal_path)
        profile = journal_profile(journal)
        if profile_name(args) != profile or args.phase not in PROFILES[profile]["adopting"]:
            raise Refusal("adoption phase does not belong to the active profile")
        if Path(journal["config_path"]) != config or journal["phase"] == "restored":
            raise Refusal("journal is not active for this config")
        current = config.read_bytes()
        blocks, _ = split_blocks(current, profile)
        if sha256(without_owned(blocks, profile)) != journal["unowned_sha256"]:
            raise Refusal("non-owned config fields changed during transaction")
        if sha256(current) != journal["last_config_sha256"]:
            raise Refusal("config changed before adoption intent was armed")
        journal["phase"] = args.phase
        journal["intended_target"] = args.target
        journal["intended_owned"] = intended
        journal["intended_after_unix"] = int(time.time()) - 1
        write_journal(journal_path, journal)
    return {"status": "adoption_armed", "phase": args.phase, "target": args.target}


def checkpoint(args: argparse.Namespace) -> dict[str, Any]:
    config = absolute_path(args.config)
    journal_path = absolute_path(args.journal)
    intended = expected_owned(args)
    with config_lock(config):
        journal = load_journal(journal_path)
        profile = journal_profile(journal)
        spec = PROFILES[profile]
        if profile_name(args) != profile:
            raise Refusal("checkpoint profile does not match the active journal")
        if Path(journal["config_path"]) != config or journal["phase"] == "restored":
            raise Refusal("journal is not active for this config")
        current = config.read_bytes()
        blocks, owned = split_blocks(current, profile)
        if sha256(without_owned(blocks, profile)) != journal["unowned_sha256"]:
            raise Refusal("non-owned config fields changed during transaction")
        if args.phase == spec["complete"]:
            if (journal["phase"] != spec["serving"][-1]
                    or journal.get("intended_owned") is not None
                    or sha256(current) != journal["last_config_sha256"]):
                raise Refusal("profile completion does not match its final served target")
            journal["phase"] = spec["complete"]
            write_journal(journal_path, journal)
            return {"status": "checkpointed", "phase": args.phase,
                    "config_sha256": journal["last_config_sha256"]}
        if not owned_matches_intent(
            owned, intended, journal.get("intended_after_unix"),
            journal["prepared_supported_models_sha256"],
        ):
            raise Refusal("adopted config does not match armed recommendation intent")
        armed = journal.get("intended_owned")
        if args.phase not in set(spec["serving"]) | {"prepared"}:
            raise Refusal("checkpoint phase does not belong to the active profile")
        if args.phase in spec["serving"] and armed is None:
            raise Refusal("adoption checkpoint has no armed intent")
        if armed is not None and (armed != intended or journal.get("intended_target") != args.target):
            raise Refusal("checkpoint does not match armed adoption intent")
        journal["phase"] = args.phase
        journal["last_config_sha256"] = sha256(current)
        journal.pop("intended_owned", None)
        journal.pop("intended_target", None)
        journal.pop("intended_after_unix", None)
        write_journal(journal_path, journal)
    return {"status": "checkpointed", "phase": args.phase,
            "config_sha256": journal["last_config_sha256"]}


def air_context(args: argparse.Namespace) -> dict[str, Any]:
    """Journal the released context setter's exact operator-owned transition."""
    config = absolute_path(args.config)
    journal_path = absolute_path(args.journal)
    with config_lock(config):
        journal = load_journal(journal_path)
        if journal_profile(journal) != AIR_PROFILE or Path(journal["config_path"]) != config:
            raise Refusal("context transition requires the Air journal")
        current = config.read_bytes()
        blocks, owned = split_blocks(current, AIR_PROFILE)
        if sha256(without_owned(blocks, AIR_PROFILE)) != journal["unowned_sha256"]:
            raise Refusal("non-owned fields changed before context transition")
        if args.action == "begin":
            if journal["phase"] != "serving_target" or sha256(current) != journal["last_config_sha256"]:
                raise Refusal("context transition requires the adopted checkpoint")
            intended = {key: scalar(owned, key) for key in RECOMMENDATION_OWNED
                        if key in owned and key != "max_context_override_provenance"}
            intended["max_context_override"] = "8192"
            journal.update(phase="adopting_target", intended_owned=intended,
                           intended_target="qwen3-8b", intended_after_unix=int(time.time()) - 1)
        else:
            intended = journal.get("intended_owned")
            if (journal["phase"] != "adopting_target" or not isinstance(intended, dict)
                    or intended.get("max_context_override") != "8192"
                    or "max_context_override_provenance" in intended
                    or not owned_matches_intent(owned, intended, journal.get("intended_after_unix"),
                                                journal["prepared_supported_models_sha256"])):
                raise Refusal("context setter did not match its armed transition")
            journal.update(phase="serving_target", last_config_sha256=sha256(current))
            for key in ("intended_owned", "intended_target", "intended_after_unix"):
                journal.pop(key, None)
        write_journal(journal_path, journal)
    return {"status": "context_" + args.action}


def restore(args: argparse.Namespace) -> dict[str, Any]:
    config = absolute_path(args.config)
    journal_path = absolute_path(args.journal)
    validator = absolute_path(args.validator)
    with config_lock(config):
        journal = load_journal(journal_path)
        if journal["phase"] == "committed":
            raise Refusal("committed adoption cannot restore the incumbent")
        if Path(journal["config_path"]) != config:
            raise Refusal("journal belongs to another config")
        if journal["phase"] in {"config_restored", "restored"}:
            return {"status": journal["phase"], "idempotent": True,
                    "config_sha256": journal["last_config_sha256"]}
        current = config.read_bytes()
        profile = journal_profile(journal)
        blocks, owned = split_blocks(current, profile)
        if sha256(without_owned(blocks, profile)) != journal["unowned_sha256"]:
            raise Refusal("non-owned config fields changed; refusing unsafe restore")
        baseline = {key: value.encode("utf-8") for key, value in journal["baseline_owned"].items()}
        candidate = render(blocks, baseline, profile)
        baseline_sha = sha256(candidate)
        current_sha = sha256(current)
        if current_sha != journal["last_config_sha256"]:
            intended = journal.get("intended_owned")
            prepared_transition = (journal["phase"] == "armed"
                                   and current_sha == journal["prepared_config_sha256"])
            intended_transition = (isinstance(intended, dict)
                                   and owned_matches_intent(
                                       owned, intended, journal.get("intended_after_unix"),
                                       journal["prepared_supported_models_sha256"],
                                   ))
            restoration_transition = (journal["phase"] == "restoring"
                                      and current_sha == baseline_sha)
            if not prepared_transition and not intended_transition and not restoration_transition:
                raise Refusal("owned config fields do not match the last checkpoint or armed adoption intent")
        if journal["phase"] != "restoring":
            journal["phase"] = "restoring"
            write_journal(journal_path, journal)
        restored_sha = (baseline_sha if current_sha == baseline_sha
                        else validate_then_replace(config, validator, candidate))
        journal["phase"] = "config_restored"
        journal["last_config_sha256"] = restored_sha
        journal.pop("intended_owned", None)
        journal.pop("intended_target", None)
        journal.pop("intended_after_unix", None)
        write_journal(journal_path, journal)
    return {"status": "config_restored", "idempotent": False, "config_sha256": restored_sha}


def finish_restore(args: argparse.Namespace) -> dict[str, Any]:
    config = absolute_path(args.config)
    journal_path = absolute_path(args.journal)
    with config_lock(config):
        journal = load_journal(journal_path)
        if Path(journal["config_path"]) != config:
            raise Refusal("journal belongs to another config")
        if journal["phase"] == "restored":
            return {"status": "restored", "idempotent": True}
        if journal["phase"] != "config_restored":
            raise Refusal("config restoration has not completed")
        current = config.read_bytes()
        profile = journal_profile(journal)
        blocks, _ = split_blocks(current, profile)
        if (sha256(current) != journal["last_config_sha256"]
                or sha256(without_owned(blocks, profile)) != journal["unowned_sha256"]):
            raise Refusal("config changed before restored service was confirmed")
        journal["phase"] = "restored"
        write_journal(journal_path, journal)
    return {"status": "restored", "idempotent": False}


def inspect(args: argparse.Namespace) -> dict[str, Any]:
    journal_path = absolute_path(args.journal)
    if safe_regular(journal_path, may_absent=True) is None:
        return {"status": "absent", "restore_required": False}
    journal = load_journal(journal_path)
    baseline_model = ""
    raw_model = journal["baseline_owned"].get("model")
    if raw_model:
        parsed = split_blocks(raw_model.encode("utf-8"))[1]
        baseline_model = scalar(parsed, "model")
    scratch_exists = Path(journal["remote_scratch"]).exists()
    result = {"status": journal["phase"], "transaction_id": journal.get("transaction_id"),
              "restore_required": (journal["phase"] != "committed"
                                   and (journal["phase"] != "restored" or scratch_exists)),
              "scratch_cleanup_required": scratch_exists,
              "remote_scratch": journal["remote_scratch"], "baseline_model": baseline_model,
              "release_binding": journal["release_binding"],
              "baseline_status": journal["baseline_status"],
              "market_binding": journal["market_binding"]}
    profile = journal_profile(journal)
    if profile != LEGACY_PROFILE:
        result["profile"] = profile
    return result


def commit_adoption(args: argparse.Namespace) -> dict[str, Any]:
    """Keep only the reviewed Air target after the controller's paid proof.

    The controller checks the signed live process before and after its proof;
    this terminal transition binds that proof to the exact checkpointed config.
    It is intentionally unavailable to the temporary acceptance profiles.
    """
    config, journal_path = absolute_path(args.config), absolute_path(args.journal)
    if not HEX64.fullmatch(args.paid_proof_sha256):
        raise Refusal("paid proof digest is invalid")
    with config_lock(config):
        journal = load_journal(journal_path)
        if journal_profile(journal) != AIR_PROFILE or journal["config_path"] != str(config):
            raise Refusal("persistent adoption requires the Air profile and exact config")
        if journal["phase"] == "committed":
            if journal["paid_proof_sha256"] != args.paid_proof_sha256:
                raise Refusal("committed adoption proof differs")
            if sha256(config.read_bytes()) != journal["last_config_sha256"]:
                raise Refusal("config changed after paid proof")
            return {"status": "committed", "idempotent": True}
        if journal["phase"] != PROFILES[AIR_PROFILE]["complete"] or journal.get("intended_owned") is not None:
            raise Refusal("adoption has not reached proof completion")
        current = config.read_bytes()
        if sha256(current) != journal["last_config_sha256"]:
            raise Refusal("config changed after paid proof")
        journal["phase"] = "committed"
        journal["paid_proof_sha256"] = args.paid_proof_sha256
        write_journal(journal_path, journal)
    return {"status": "committed", "idempotent": False}


def authenticate_air_recovery(args: argparse.Namespace) -> dict[str, Any]:
    """Authenticate journal-bound released bytes even if serve cannot answer."""
    config, binary = absolute_path(args.config), absolute_path(args.validator)
    journal = load_journal(absolute_path(args.journal))
    if journal_profile(journal) != AIR_PROFILE or journal["config_path"] != str(config):
        raise Refusal("recovery does not belong to this Air config")
    release = journal["release_binding"]
    if sha256(release["provider_id"].encode()) != args.provider_sha256:
        raise Refusal("recovery provider identity differs")
    if release["binary_version"] != "1.8.260":
        raise Refusal("recovery release is outside the reviewed Air transition")
    safe_regular(binary)
    if sha256(binary.read_bytes()) != release["cli_sha256"]:
        raise Refusal("journal-bound released executable changed")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)],
                   capture_output=True, check=True, timeout=30)
    displayed = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(binary)],
                               capture_output=True, text=True, check=True, timeout=30)
    fields = dict(line.split("=", 1) for line in displayed.stderr.splitlines() if "=" in line)
    if any(fields.get(key) != release[value] for key, value in (
        ("TeamIdentifier", "team_id"), ("Identifier", "signing_identifier"), ("CDHash", "code_cdhash"),
    )):
        raise Refusal("recovery signed identity differs from journal")
    hardware = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"], capture_output=True,
                              text=True, check=True, timeout=10).stdout.strip()
    if hardware != "Mac15,12":
        raise Refusal("recovery is not on the designated Air hardware")
    return {"status": "authenticated", "baseline_model": scalar(
        {key: value.encode() for key, value in journal["baseline_owned"].items()}, "model")}


def verify_recommendation(args: argparse.Namespace) -> dict[str, Any]:
    recommendation = strict_json(Path(args.recommendation))
    profile = profile_name(args)
    if args.target not in PROFILES[profile]["targets"]:
        raise Refusal("target does not belong to the selected profile")
    target = TARGETS[args.target]
    if recommendation.get("schema_version") != "autotune_recommend.v1":
        raise Refusal("wrong recommendation schema")
    if recommendation.get("recommended_model") != target["catalog_key"]:
        raise Refusal("recommendation selected the wrong catalog key")
    if recommendation.get("warnings") != []:
        raise Refusal("recommendation contains warnings")
    hardware = recommendation.get("hardware")
    inputs = recommendation.get("inputs")
    serve = recommendation.get("serve_config")
    candidates = recommendation.get("candidates")
    if not all(isinstance(value, dict) for value in (hardware, inputs, serve)) or not isinstance(candidates, list):
        raise Refusal("recommendation is incomplete")
    if hardware.get("binary_version") != args.binary_version:
        raise Refusal("recommendation binary version does not match handback")
    if inputs.get("candidate_catalog_version") != args.catalog_version:
        raise Refusal("recommendation catalog release does not match live signed release")
    if inputs.get("rate_card_version") != args.rate_card_version:
        raise Refusal("recommendation rate card does not match live signed rate card")
    if args.catalog_hash and serve.get("model_catalog_hash") != args.catalog_hash:
        raise Refusal("recommendation catalog hash does not match live signed release")
    exact = {
        "model": target["catalog_key"],
        "model_catalog_key": target["catalog_key"],
        "model_catalog_model_id": target["model_id"],
        "model_catalog_revision": target["revision"],
        "model_catalog_sha256": target["sha256"],
        "model_artifact_sha256": target["sha256"],
    }
    for key, expected in exact.items():
        if serve.get(key) != expected:
            raise Refusal(f"recommendation {key} does not match qualified target")
    artifact_path = serve.get("model_artifact_path")
    if (not isinstance(artifact_path, str) or not artifact_path.startswith("/")
            or not SAFE_VALUE.fullmatch(artifact_path)):
        raise Refusal("recommendation artifact path is not an absolute safe scalar")
    if not any(isinstance(row, dict) and row.get("model") == target["catalog_key"]
               and row.get("eligible") is True for row in candidates):
        raise Refusal("qualified target is not eligible")
    context = serve.get("max_context_override")
    context_floor = PROFILES[profile]["context_floor"]
    if type(context) is not int or context < context_floor:
        raise Refusal(f"recommendation context is below the {context_floor}-token profile floor")
    return {"status": "verified", "target": args.target, "gateway_id": target["gateway_id"],
            "catalog_key": target["catalog_key"], "artifact_sha256": target["sha256"]}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--profile", choices=tuple(PROFILES), default=LEGACY_PROFILE)
    prepare_parser.add_argument("--config", required=True)
    prepare_parser.add_argument("--journal", required=True)
    prepare_parser.add_argument("--validator", required=True)
    prepare_parser.add_argument("--transaction-id", required=True)
    prepare_parser.add_argument("--binary-version", required=True)
    prepare_parser.add_argument("--provider-id", required=True)
    prepare_parser.add_argument("--cli-sha256", required=True)
    prepare_parser.add_argument("--code-cdhash", required=True)
    prepare_parser.add_argument("--team-id", required=True)
    prepare_parser.add_argument("--signing-identifier", required=True)
    prepare_parser.add_argument("--written-handoff-sha256", required=True)
    prepare_parser.add_argument("--baseline-catalog-version", required=True)
    prepare_parser.add_argument("--baseline-catalog-hash", required=True)
    prepare_parser.add_argument("--baseline-pid", required=True, type=int)
    prepare_parser.add_argument("--rate-card-version", required=True)
    prepare_parser.add_argument("--remote-scratch", required=True)
    prepare_parser.set_defaults(run=prepare)
    checkpoint_parser = commands.add_parser("checkpoint")
    checkpoint_parser.add_argument("--profile", choices=tuple(PROFILES), default=LEGACY_PROFILE)
    checkpoint_parser.add_argument("--config", required=True)
    checkpoint_parser.add_argument("--journal", required=True)
    checkpoint_parser.add_argument("--phase", required=True,
                                   choices=("prepared", "serving_first", "serving_second",
                                            "acceptance_complete", "serving_target", "proof_complete"))
    checkpoint_parser.add_argument("--recommendation", required=True)
    checkpoint_parser.add_argument("--target", required=True, choices=tuple(TARGETS))
    checkpoint_parser.add_argument("--binary-version", required=True)
    checkpoint_parser.add_argument("--catalog-version", required=True)
    checkpoint_parser.add_argument("--catalog-hash", default="")
    checkpoint_parser.add_argument("--rate-card-version", required=True)
    checkpoint_parser.set_defaults(run=checkpoint)
    begin_parser = commands.add_parser("begin-adoption")
    begin_parser.add_argument("--profile", choices=tuple(PROFILES), default=LEGACY_PROFILE)
    begin_parser.add_argument("--config", required=True)
    begin_parser.add_argument("--journal", required=True)
    begin_parser.add_argument("--phase", required=True,
                              choices=("adopting_first", "adopting_second", "adopting_target"))
    begin_parser.add_argument("--recommendation", required=True)
    begin_parser.add_argument("--target", required=True, choices=tuple(TARGETS))
    begin_parser.add_argument("--binary-version", required=True)
    begin_parser.add_argument("--catalog-version", required=True)
    begin_parser.add_argument("--catalog-hash", default="")
    begin_parser.add_argument("--rate-card-version", required=True)
    begin_parser.set_defaults(run=begin_adoption)
    restore_parser = commands.add_parser("restore")
    restore_parser.add_argument("--config", required=True)
    restore_parser.add_argument("--journal", required=True)
    restore_parser.add_argument("--validator", required=True)
    restore_parser.set_defaults(run=restore)
    restart_parser = commands.add_parser("restart-service")
    restart_parser.add_argument("--config", required=True)
    restart_parser.add_argument("--validator", required=True)
    restart_parser.set_defaults(run=restart_service)
    finish_parser = commands.add_parser("finish-restore")
    finish_parser.add_argument("--config", required=True)
    finish_parser.add_argument("--journal", required=True)
    finish_parser.set_defaults(run=finish_restore)
    inspect_parser = commands.add_parser("inspect")
    inspect_parser.add_argument("--journal", required=True)
    inspect_parser.set_defaults(run=inspect)
    commit_parser = commands.add_parser("commit-adoption")
    commit_parser.add_argument("--config", required=True)
    commit_parser.add_argument("--journal", required=True)
    commit_parser.add_argument("--paid-proof-sha256", required=True)
    commit_parser.set_defaults(run=commit_adoption)
    context_parser = commands.add_parser("air-context")
    context_parser.add_argument("--config", required=True)
    context_parser.add_argument("--journal", required=True)
    context_parser.add_argument("--action", required=True, choices=("begin", "finish"))
    context_parser.set_defaults(run=air_context)
    auth_parser = commands.add_parser("authenticate-air-recovery")
    auth_parser.add_argument("--config", required=True)
    auth_parser.add_argument("--journal", required=True)
    auth_parser.add_argument("--validator", required=True)
    auth_parser.add_argument("--provider-sha256", required=True)
    auth_parser.set_defaults(run=authenticate_air_recovery)
    verify_parser = commands.add_parser("verify-recommendation")
    verify_parser.add_argument("--profile", choices=tuple(PROFILES), default=LEGACY_PROFILE)
    verify_parser.add_argument("--recommendation", required=True)
    verify_parser.add_argument("--target", required=True, choices=tuple(TARGETS))
    verify_parser.add_argument("--binary-version", required=True)
    verify_parser.add_argument("--catalog-version", required=True)
    verify_parser.add_argument("--catalog-hash", default="")
    verify_parser.add_argument("--rate-card-version", required=True)
    verify_parser.set_defaults(run=verify_recommendation)
    return result


def main(argv: list[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        print(json.dumps(args.run(args), sort_keys=True, separators=(",", ":")))
        return 0
    except Refusal as exc:
        print(json.dumps({"status": "refused", "reason": str(exc)}, sort_keys=True,
                         separators=(",", ":")))
        return 3
    except Exception:
        print(json.dumps({"status": "error", "reason": "internal_error"}, sort_keys=True,
                         separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
