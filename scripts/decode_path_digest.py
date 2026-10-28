#!/usr/bin/env python3
"""SPEC-048-R013 (0.1.51) decode-path digest.

The digest names the code that decides which tokens a native-MTP or
continuous-batching row emits: the decode-path source files listed in
`phase3-binary/decode-path-manifest.json` plus the pinned mlx-swift and
mlx-swift-lm revisions (the MLX core, the model families' forward passes and
the fork's drafters). A signed admission entry that carries
`decode_path_digest` is valid for every signed CLI release that embeds the same
digest; a CLI cut that leaves the decode path alone needs no admission step.

The digest is SHA-256 over the UTF-8 bytes

    macprovider.decode-path-digest.v1\\n
    file <path> <sha256 of the file bytes>\\n        (manifest order: bytewise sorted)
    dependency <identity> <Package.resolved revision>\\n   (sorted)

and is compiled into the CLI as `DecodePathIdentity.embeddedMarker`
(`phase3-binary/Sources/macprovider-cli/DecodePathIdentity.generated.swift`),
so the signed binary carries it.

Usage:
  python3 scripts/decode_path_digest.py              print the digest
  python3 scripts/decode_path_digest.py --write      regenerate the Swift constant
  python3 scripts/decode_path_digest.py --check      exit 1 if a listed file is
                                                     missing or the constant is stale (CI)
  python3 scripts/decode_path_digest.py --binary PATH
                                                     print the digest embedded in a built
                                                     macprovider-cli (or "none")
  python3 scripts/decode_path_digest.py --admission-status SIDECAR
                                                     compare a native-MTP admission sidecar's
                                                     entries with this tree's source digest:
                                                     match | legacy | mismatch (the provider
                                                     also matches metallib, runtime revision
                                                     and hardware)
  python3 scripts/decode_path_digest.py --publish-gate RELEASE_INPUT SIDECAR [RECOMMENDED_VERSION]
                                                     SPEC-048-R014 item 10: print "ok" or
                                                     "blocked: <reason>" for publishing SIDECAR
  Guarded old-scope candidate pair only: add all four proof paths
    --signed-pair-plan PLAN --signed-byte-verification MARKER
    --signed-pair-run-json GH_RUN_JSON --signed-pair-prior-sidecar PRIOR_SIDECAR
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "phase3-binary"
MANIFEST = PACKAGE / "decode-path-manifest.json"
RESOLVED = PACKAGE / "Package.resolved"
GENERATED = PACKAGE / "Sources" / "macprovider-cli" / "DecodePathIdentity.generated.swift"
MANIFEST_SCHEMA = "macprovider.decode-path-manifest.v1"
DOMAIN = "macprovider.decode-path-digest.v1"
MARKER_PREFIX = DOMAIN + ":"
MARKER = re.compile(rb"macprovider\.decode-path-digest\.v1:([0-9a-f]{64})")
REVISION = re.compile(r"^[0-9a-f]{40}$")
SOURCE_PATH = re.compile(r"^Sources/[A-Za-z0-9_./-]+\.swift$")
MAX_FILES = 256


class DecodePathError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    keys = [key for key, _ in pairs]
    if len(set(keys)) != len(keys):
        raise DecodePathError("duplicate JSON key")
    return dict(pairs)


def load_manifest(package: Path = PACKAGE) -> tuple[list[str], list[str]]:
    path = package / MANIFEST.name
    try:
        value = json.loads(path.read_text("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise DecodePathError(f"{path}: {error}") from error
    if not isinstance(value, dict) or set(value) != {"schema_version", "files", "dependencies"}:
        raise DecodePathError(f"{path}: must be exactly {{schema_version, files, dependencies}}")
    if value["schema_version"] != MANIFEST_SCHEMA:
        raise DecodePathError(f"{path}: schema_version must be {MANIFEST_SCHEMA}")
    files, dependencies = value["files"], value["dependencies"]
    for name, items in (("files", files), ("dependencies", dependencies)):
        if not isinstance(items, list) or not items or not all(isinstance(item, str) and item for item in items):
            raise DecodePathError(f"{path}: {name} must be a non-empty array of strings")
        encoded = [item.encode("utf-8") for item in items]
        if encoded != sorted(encoded) or len(set(items)) != len(items):
            raise DecodePathError(f"{path}: {name} must be bytewise sorted and unique")
    if len(files) > MAX_FILES:
        raise DecodePathError(f"{path}: at most {MAX_FILES} files")
    generated = GENERATED.relative_to(PACKAGE).as_posix()
    for item in files:
        if not SOURCE_PATH.match(item) or ".." in item.split("/"):
            raise DecodePathError(f"{path}: file {item!r} must be a relative Sources/**/*.swift path")
        if item == generated:
            raise DecodePathError(f"{path}: the generated digest file cannot be part of its own digest")
    return files, dependencies


def resolved_revisions(package: Path = PACKAGE) -> dict[str, str]:
    path = package / RESOLVED.name
    try:
        value = json.loads(path.read_text("utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise DecodePathError(f"{path}: {error}") from error
    revisions: dict[str, str] = {}
    for pin in value.get("pins") or []:
        identity = pin.get("identity")
        revision = (pin.get("state") or {}).get("revision")
        if isinstance(identity, str) and isinstance(revision, str):
            revisions[identity] = revision
    return revisions


def compute(package: Path = PACKAGE) -> str:
    files, dependencies = load_manifest(package)
    revisions = resolved_revisions(package)
    lines = [DOMAIN]
    for item in files:
        path = package / item
        if not path.is_file() or path.is_symlink():
            raise DecodePathError(f"decode-path manifest lists {item}, which is not a regular file")
        lines.append(f"file {item} {hashlib.sha256(path.read_bytes()).hexdigest()}")
    for identity in dependencies:
        revision = revisions.get(identity)
        if revision is None or not REVISION.match(revision):
            raise DecodePathError(f"Package.resolved has no 40-hex revision for {identity}")
        lines.append(f"dependency {identity} {revision}")
    return hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()


def render(digest: str) -> str:
    return f"""// GENERATED by scripts/decode_path_digest.py --write. Do not edit.
// SPEC-048-R013 (0.1.51): the decode-path digest over
// phase3-binary/decode-path-manifest.json. CI (`decode_path_digest.py --check`
// and DecodePathIdentityTests) fails when a listed file changes without
// regenerating this constant.

enum DecodePathIdentity {{
    static let domain = "{DOMAIN}"
    /// Kept as one literal so the signed binary carries a findable marker.
    static let embeddedMarker = "{MARKER_PREFIX}{digest}"
    static var digest: String {{ String(embeddedMarker.dropFirst(domain.count + 1)) }}
}}
"""


def embedded_in_binary(path: Path) -> str | None:
    found = set(MARKER.findall(path.read_bytes()))
    if len(found) > 1:
        raise DecodePathError(f"{path}: more than one embedded decode-path digest")
    return found.pop().decode("ascii") if found else None


def _entry_digests(sidecar: Path) -> list[str | None]:
    value = json.loads(sidecar.read_text("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    entries = value.get("entries") if isinstance(value, dict) else None
    if not isinstance(entries, list) or not entries or not all(isinstance(e, dict) for e in entries):
        raise DecodePathError(f"{sidecar}: no entries")
    return [entry.get("decode_path_digest") for entry in entries]


def admission_status(sidecar: Path, digest: str) -> str:
    """A bound entry whose digest differs wins over `legacy`: the provider
    refuses it, so the tuple needs requalification whatever else is listed."""
    digests = _entry_digests(sidecar)
    if any(item is not None and item != digest for item in digests):
        return "mismatch"
    return "legacy" if any(item is None for item in digests) else "match"


_VERSION = re.compile(r'^\s*static let binaryVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', re.M)


def _git_show(commit: str, path: str) -> str | None:
    if not REVISION.match(commit):
        raise DecodePathError(f"source commit {commit!r} is not a 40-hex commit")
    result = subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{commit}:{path}"],
        capture_output=True, text=True, check=False,
    )
    return result.stdout if result.returncode == 0 else None


def release_commit_identity(commit: str) -> tuple[str | None, str | None]:
    """The decode-path digest and binaryVersion compiled from `commit` (the
    signed release's source commit). No digest means that CLI predates the
    decode-path reader and rejects decode-path entries."""
    generated = _git_show(commit, GENERATED.relative_to(ROOT).as_posix())
    found = MARKER.findall(generated.encode("utf-8")) if generated else []
    client = _git_show(commit, "phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift") or ""
    version = _VERSION.search(client)
    return (found[0].decode("ascii") if len(found) == 1 else None, version.group(1) if version else None)


def verify_release_input(release_input: dict) -> str | None:
    """SPEC-048-R014 item 10: a declared `provider_decode_path_digest` must be
    the digest compiled from the bound release's source commit. Returns that
    release's binaryVersion, or None when no digest is declared."""
    declared = release_input.get("provider_decode_path_digest")
    if declared is None:
        return None
    commit = (release_input.get("entry") or {}).get("source_commit")
    if not isinstance(commit, str):
        raise DecodePathError("release input entry.source_commit is missing")
    digest, version = release_commit_identity(commit)
    if digest is None:
        raise DecodePathError(
            f"the release at {commit} embeds no decode-path digest, so it rejects decode-path entries; "
            "bind a release that carries the reader")
    if digest != declared:
        raise DecodePathError(
            f"provider_decode_path_digest {declared} is not the digest compiled at {commit} ({digest})")
    if version is None:
        raise DecodePathError(f"cannot read binaryVersion at {commit}")
    return version


def _tag_commit(version: str) -> str | None:
    """The commit the release tag v<version> names in this clone (the release
    train pushes the tag only after the signed candidate is verified)."""
    result = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--verify", "-q", f"refs/tags/v{version}^{{commit}}"],
        capture_output=True, text=True, check=False,
    )
    commit = result.stdout.strip()
    return commit if result.returncode == 0 and REVISION.match(commit) else None


def _semver(text: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", text or ""):
        raise DecodePathError(f"not a version: {text!r}")
    return tuple(int(part) for part in text.split("."))


@dataclass(frozen=True)
class SignedPairPublishProof:
    plan: Path
    signed_byte_verification: Path
    run: Path
    prior_sidecar: Path


def _read_proof_json(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise DecodePathError("signed-pair proof must be a regular non-symlink file")
    value = json.loads(path.read_text("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    if not isinstance(value, dict):
        raise DecodePathError("signed-pair proof must be an object")
    return value


def _file_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise DecodePathError("signed-pair asset must be a regular non-symlink file")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_candidate_envelope(directory: Path, version: str, source: str, run: dict) -> None:
    result = subprocess.run([
        sys.executable, str(ROOT / "scripts/acceptance-candidate-metadata.py"), "verify",
        "--input", str(directory / "acceptance-candidate.json"),
        "--signature", str(directory / "acceptance-candidate.json.sig"),
        "--public-key", str(ROOT / "security/acceptance-candidate-signing-public.pem"),
        "--checksums", str(directory / "checksums.txt"),
        "--repository", "Augustas11/macprovider", "--tag", f"v{version}",
        "--candidate-ref", "refs/heads/main", "--candidate-commit", source,
        "--control-commit", run["head_sha"], "--run-id", str(run["id"]),
        "--run-attempt", str(run["run_attempt"]),
    ], capture_output=True, text=True, check=False, timeout=30)
    if result.returncode != 0:
        # The verifier can mention private filenames; keep this gate's public
        # failure diagnostic bounded and free of captured subprocess output.
        raise DecodePathError("signed acceptance candidate envelope verification failed")


def _verify_identity_only_decode(old: dict, new: dict) -> None:
    """Reopen the closed source proof; signed bytes alone prove no behavior."""
    for key, pattern in (("source_commit", r"[0-9a-f]{40}"),
                         ("decode_path_digest", r"[0-9a-f]{64}"),
                         ("runtime_revision", r"[0-9a-f]{40}"),
                         ("metallib_sha256", r"[0-9a-f]{64}")):
        if not all(isinstance(row.get(key), str) and re.fullmatch(pattern, row[key])
                   for row in (old, new)):
            raise DecodePathError("signed-pair candidate: complete prior/current decode identities required")
    # The source contract proves release-source equivalence, not arbitrary
    # changed runtime or Metal-library bytes. Such changes need their own
    # qualification before this pre-promotion exception can admit them.
    if any(old[key] != new[key] for key in ("runtime_revision", "metallib_sha256")):
        raise DecodePathError("signed-pair candidate: runtime/Metal changes require independent qualification")
    spec = importlib.util.spec_from_file_location(
        "signed_pair_source_equivalence", ROOT / "scripts/native_mtp_source_equivalence.py")
    if spec is None or spec.loader is None:
        raise DecodePathError("signed-pair candidate: source-equivalence verifier unavailable")
    equivalence = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(equivalence)
    try:
        equivalence.verify_source_equivalence(
            ROOT, old["source_commit"], new["source_commit"],
            old["decode_path_digest"], new["decode_path_digest"],
            request_feature_profile=new.get("request_feature_profile"))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise DecodePathError("signed-pair candidate: unchanged decode behavior is not proven") from error


def _signed_pair_publish_gate(release_input: dict, sidecar: Path, version: str,
                              proof: SignedPairPublishProof) -> None:
    def require(condition: bool, reason: str) -> None:
        if not condition:
            raise DecodePathError("signed-pair candidate: " + reason)

    require(os.environ.get("MACPROVIDER_OPS_ENTRYPOINT") == "1"
            and bool(os.environ.get("MACPROVIDER_OPS_OWNER")), "owning ops entrypoint required")
    plan = _read_proof_json(proof.plan)
    marker = _read_proof_json(proof.signed_byte_verification)
    run = _read_proof_json(proof.run)
    prior, target = plan.get("prior"), plan.get("target")
    require(plan.get("schema_version") == "macprovider.signed_native_pair.v1"
            and isinstance(prior, dict) and isinstance(target, dict), "matched pair plan required")
    require(isinstance(plan.get("transaction_id"), str)
            and re.fullmatch(r"[A-Za-z0-9_-]{1,80}", plan["transaction_id"]) is not None,
            "transaction identity required")
    require(prior.get("provenance") == "reviewed_published_signed_release"
            and target.get("provenance") == "reviewed_signed_acceptance_candidate", "released rollback and signed candidate required")
    require(prior.get("request_feature_profile") == target.get("request_feature_profile") == "native_mtp_greedy_text_v1",
            "only unchanged greedy scope may precede publication")
    for key in ("binary_sha256", "tarball_sha256", "decode_path_digest", "model_hash", "checksums_sha256",
                "acceptance_manifest_sha256", "acceptance_signature_sha256"):
        require(isinstance(target.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", target[key]) is not None,
                "candidate hash identity malformed")
    require(isinstance(target.get("cdhash"), str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", target["cdhash"]) is not None
            and all(isinstance(target.get(key), str) and bool(target[key]) for key in ("team_id", "signing_identifier", "model_key")),
            "candidate signing/model identity malformed")
    require(prior.get("model_key") == target.get("model_key")
            and prior.get("model_hash") == target.get("model_hash"), "served model changed")
    require(type(prior.get("ordinary_context_tokens")) is int
            and prior["ordinary_context_tokens"] >= 4096
            and type(target.get("ordinary_context_tokens")) is int
            and prior["ordinary_context_tokens"] == target["ordinary_context_tokens"], "ordinary context changed")
    require(marker.get("step") == "signed_byte_verification", "signed-byte verification marker required")
    run_id = target.get("candidate_run_id")
    require(isinstance(run_id, (str, int)) and not isinstance(run_id, bool)
            and re.fullmatch(r"[1-9][0-9]*", str(run_id)) is not None, "candidate run id required")
    require(str(marker.get("run_id")) == str(run_id) == str(run.get("id")), "candidate run mismatch")
    repository = run.get("repository")
    require(isinstance(repository, dict), "acceptance repository missing")
    require(run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
            and run.get("conclusion") == "success"
            and run.get("path") == ".github/workflows/acceptance-candidate.yml"
            and run.get("head_branch") == "main"
            and repository.get("full_name") == "Augustas11/macprovider"
            and type(run.get("run_attempt")) is int and run["run_attempt"] > 0
            and isinstance(run.get("head_sha"), str) and REVISION.fullmatch(run["head_sha"]) is not None,
            "successful reviewed acceptance workflow required")
    source = release_input["entry"]["source_commit"]
    require(target.get("version") == version and target.get("source_commit") == marker.get("candidate_sha") == source,
            "candidate source/version mismatch")
    require(marker.get("compatibility_set_id") == f"Augustas11/macprovider:v{version}@{source}",
            "candidate compatibility identity mismatch")
    require(target.get("decode_path_digest") == release_input.get("provider_decode_path_digest"), "candidate digest mismatch")
    identity = release_input["entry"]
    require(identity.get("provider_revision") == source
            and identity.get("reproducible_build_sha256") == marker.get("binary_sha256") == target.get("binary_sha256")
            and identity.get("live_executable_cdhash") == target.get("cdhash"), "candidate code identity mismatch")
    directory_value = marker.get("bytes_dir")
    require(isinstance(directory_value, str) and bool(directory_value), "verified candidate directory missing")
    directory = Path(directory_value)
    require(directory.is_dir() and not directory.is_symlink(), "verified candidate directory unsafe")
    archive = directory / f"macprovider-cli-v{version}-darwin-arm64.tar.gz"
    require(target.get("local_tarball_path") == str(archive), "candidate archive location mismatch")
    for name, key in (("acceptance-candidate.json", "acceptance_manifest_sha256"),
                      ("acceptance-candidate.json.sig", "acceptance_signature_sha256"),
                      ("checksums.txt", "checksums_sha256")):
        require(target.get(key) == _file_digest(directory / name), "candidate signed asset binding mismatch")
    require(marker.get("checksums_sha256") == target["checksums_sha256"], "verified checksums changed")
    require(target.get("tarball_sha256") == _file_digest(archive), "candidate archive bytes changed")
    _verify_candidate_envelope(directory, version, source, run)
    checksums = {}
    for line in (directory / "checksums.txt").read_text("utf-8").splitlines():
        if line.strip():
            fields = line.split(None, 1)
            require(len(fields) == 2 and fields[1].lstrip("*") not in checksums, "ambiguous checksums")
            checksums[fields[1].lstrip("*")] = fields[0]
    require(checksums.get(archive.name) == target["tarball_sha256"], "archive absent from signed checksums")
    metadata_path = directory / "pearl-release.json"
    require(checksums.get(metadata_path.name) == _file_digest(metadata_path), "code identity metadata not signed")
    code = _read_proof_json(metadata_path).get("provider_code_identity")
    require(isinstance(code, dict) and isinstance(code.get("slices"), list), "signed provider code identity missing")
    require(code.get("binary_version") == version and code.get("binary_sha256") == target["binary_sha256"]
            and code.get("team_id") == target.get("team_id")
            and code.get("signing_identifier") == target.get("signing_identifier")
            and any(isinstance(item, dict) and item.get("code_cdhash") == target.get("cdhash")
                    for item in code.get("slices", [])), "signed provider code identity mismatch")
    before, after = _read_proof_json(proof.prior_sidecar), _read_proof_json(sidecar)
    for role, path in ((prior, proof.prior_sidecar), (target, sidecar)):
        feeds = role.get("feed_sha256")
        require(isinstance(feeds, dict), "signed feed recovery bindings missing")
        require(feeds.get("/v1/native-mtp-admission") == _file_digest(path), "plan sidecar bytes mismatch")
        require(all(isinstance(feeds.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", feeds[key])
                    for key in ("/v1/native-mtp-selftest-bank", "/v1/native-mtp-selftest-bank.sig",
                                "/v1/native-mtp-admission.sig", "/v1/continuous-batching-policy",
                                "/v1/continuous-batching-policy.sig")), "signed bank/CB recovery bindings missing")
    old_rows, new_rows = before.get("entries"), after.get("entries")
    require(isinstance(old_rows, list) and isinstance(new_rows, list) and bool(old_rows)
            and len(old_rows) == len(new_rows), "model inventory changed")
    # Only binding/provenance may change, never qualification or shape scope.
    identity_keys = {"source_commit", "provider_revision", "reproducible_build_sha256", "live_executable_cdhash",
                     "decode_path_digest", "metallib_sha256", "runtime_revision", "challenge_bank_sha256", "artifact_manifest_sha256"}
    selected = 0
    for old, new in zip(old_rows, new_rows):
        require(isinstance(old, dict) and isinstance(new, dict) and old.keys() == new.keys(), "entry schema changed")
        def scope(row: dict) -> dict:
            result = {key: value for key, value in row.items() if key not in identity_keys}
            if isinstance(result.get("ordinary_baseline"), dict):
                result["ordinary_baseline"] = {key: value for key, value in result["ordinary_baseline"].items()
                                               if key != "provider_revision"}
            return result
        require(scope(old) == scope(new), "qualification or eligibility scope changed")
        _verify_identity_only_decode(old, new)
        require(old.get("challenge_bank_sha256") == prior["feed_sha256"]["/v1/native-mtp-selftest-bank"]
                and new.get("challenge_bank_sha256") == target["feed_sha256"]["/v1/native-mtp-selftest-bank"], "bank binding mismatch")
        if new.get("model_key") == target.get("model_key"):
            selected += 1
            require(new.get("request_feature_profile") == "native_mtp_greedy_text_v1"
                    and type(new.get("proposal_depth")) is int and type(new.get("max_native_active_rows")) is int
                    and new["proposal_depth"] == new["max_native_active_rows"] == 1,
                    "only existing one-row, depth-one greedy tuple may use candidate order")
            require(new.get("source_commit") == new.get("provider_revision") == source
                    and new.get("reproducible_build_sha256") == target["binary_sha256"]
                    and new.get("live_executable_cdhash") == target["cdhash"]
                    and new.get("decode_path_digest") == target["decode_path_digest"],
                    "selected tuple candidate identity mismatch")
    require(selected == 1, "selected tuple missing or ambiguous")


def publish_gate(release_path: Path, sidecar: Path, recommended: str | None,
                 signed_pair: SignedPairPublishProof | None = None) -> str:
    if all(item is None for item in _entry_digests(sidecar)):
        if signed_pair is not None:
            raise DecodePathError("signed-pair candidate requires decode-path-bound entries")
        return "ok"
    release_input = json.loads(release_path.read_text("utf-8"), object_pairs_hook=_reject_duplicate_keys)
    version = verify_release_input(release_input)
    if version is None:
        raise DecodePathError("decode-path entries need provider_decode_path_digest in the release input")
    commit = release_input["entry"]["source_commit"]
    if signed_pair is not None:
        _signed_pair_publish_gate(release_input, sidecar, version, signed_pair)
        return "ok"
    tagged = _tag_commit(version)
    if tagged != commit:
        raise DecodePathError(
            f"release tag v{version} names {tagged or 'nothing'}, not the bound source commit {commit}: "
            "bind the published release that carries the reader (git fetch --tags first)")
    if recommended is None:
        raise DecodePathError("the live recommended CLI version is unknown")
    if _semver(recommended) < _semver(version):
        raise DecodePathError(
            f"decode-path entries need the reader CLI {version} to be the released CLI; "
            f"the coordinator recommends {recommended} (SPEC-048-R014 item 10)")
    return "ok"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--binary", type=Path)
    mode.add_argument("--admission-status", type=Path)
    mode.add_argument("--publish-gate", nargs="+", metavar="ARG")
    parser.add_argument("--signed-pair-plan", type=Path)
    parser.add_argument("--signed-byte-verification", type=Path)
    parser.add_argument("--signed-pair-run-json", type=Path)
    parser.add_argument("--signed-pair-prior-sidecar", type=Path)
    args = parser.parse_args(argv)
    pair_paths = (args.signed_pair_plan, args.signed_byte_verification, args.signed_pair_run_json, args.signed_pair_prior_sidecar)
    if any(path is not None for path in pair_paths) and (args.publish_gate is None or not all(path is not None for path in pair_paths)):
        parser.error("signed-pair publish proof requires --publish-gate and all four signed-pair proof paths")
    try:
        if args.binary is not None:
            print(embedded_in_binary(args.binary) or "none")
            return 0
        if args.publish_gate is not None:
            if len(args.publish_gate) not in (2, 3):
                parser.error("--publish-gate RELEASE_INPUT SIDECAR [RECOMMENDED_VERSION]")
            release_path, sidecar = Path(args.publish_gate[0]), Path(args.publish_gate[1])
            recommended = args.publish_gate[2] if len(args.publish_gate) == 3 and args.publish_gate[2] else None
            try:
                proof = SignedPairPublishProof(*pair_paths) if all(path is not None for path in pair_paths) else None
                print(publish_gate(release_path, sidecar, recommended, proof))
            except DecodePathError as error:
                print(f"blocked: {error}")
            return 0
        digest = compute()
        if args.admission_status is not None:
            print(admission_status(args.admission_status, digest))
        elif args.write:
            GENERATED.write_text(render(digest), "utf-8")
            print(digest)
        elif args.check:
            current = GENERATED.read_text("utf-8") if GENERATED.exists() else ""
            if current != render(digest):
                print(
                    f"decode_path_digest: {GENERATED.relative_to(ROOT)} is stale (decode path digest {digest}); "
                    "run python3 scripts/decode_path_digest.py --write and review the decode-path change "
                    "(AGENTS.md rule 2: a changed decode path needs requalification evidence)",
                    file=sys.stderr,
                )
                return 1
            print(digest)
        else:
            print(digest)
    except (DecodePathError, OSError, json.JSONDecodeError, subprocess.TimeoutExpired) as error:
        print(f"decode_path_digest: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
