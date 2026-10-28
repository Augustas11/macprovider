#!/usr/bin/env python3
"""Verify reviewed LAB-only source deltas without changing admission identity.

This is an evidence-reuse proof, never a replacement decode-path digest. It
reads old source as Git data and runs only the current reviewed digest code.
"""
from __future__ import annotations
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

SCHEMA = "macprovider.native-mtp-lab-source-equivalence.v1"
RECIPE_PATH = "ops/recipes/native-mtp-glm53-binding.v1.json"
CONTRACT_PATH = "ops/recipes/native-mtp-glm53-lab-source-equivalence.v1.json"
MEASURED_SOURCE = "6507121b05b166e94ed473dd9eb981fc9ec5f18e"
W3_SOURCE = "d2c8df79e812c6e02f2aaba1e366b742aa52ef4a"
OLD_FORK = "a9b6c021becbff5d9f0651ae5c2b7bfd497852bb"
NEW_FORK = "b128c37f26d2cbd58700c0ebf3a761f1df7b5415"
PROFILE = "native_mtp_sampled_text_v1"
SELECTOR_PATH = "Sources/macprovider-cli/NativeMTP.swift"
PROFILE_DECODER_PATH = "phase3-binary/Sources/macprovider-cli/NativeMTPAdmissionSidecar.swift"
OLD_SELECTOR = b'''        // implements these shapes; other families retain their existing gate.
        let supportsToolPrompt = nativeCapability.family == "glm5_next_mtp_v1"
'''
NEW_SELECTOR = b'''        // implements these shapes. The existing signed sampled profile also
        // authorizes their expanded scope; an identity-only release rebind of
        // the old greedy profile must preserve its prior text-only scope.
        let supportsToolPrompt = nativeCapability.family == "glm5_next_mtp_v1"
            && nativeCapability.supportsSampling
'''
# This exact reviewed release carries forward measured GLM qualification under
# the operator-approved integration, cache/prefill and runtime-hygiene review.
INTEGRATION_MEASURED_SOURCE = "1d53dd76d6c93e2e2c6d5fc20d403bbdd21093ff"
INTEGRATION_REVIEWED_SOURCE = "11c4107744116ac426b0eab4cd37a20c511526a9"
INTEGRATION_FORK = "36d24585f9373c2661f61f5e5b485c8d66c43a2b"
INTEGRATION_CONTRACT_PATH = "ops/recipes/native-mtp-glm53-integration-reuse.v1.json"
INTEGRATION_SCHEMA = "macprovider.native-mtp-integration-reuse.v1"
INTEGRATION_SCOPE = {
    "model_key": "zai-org/glm-5.3-flash",
    "request_feature_profile": PROFILE,
    "artifact_hash": "7299b6a71a38490e378e9eb6524c426392aa96e3fd561007e0540134bbef48f9",
    "tokenizer_sha256": "19e773648cb4e65de8660ea6365e10acca112d42a854923df93db4a6f333a82d",
    "qualified_slots": 4, "max_native_active_rows": 1,
    "proposal_depth": 1, "max_prompt_tokens": 4096,
    "metallib_sha256": "589e56e0794dcf6fcebf7f7edbda562404653e606d6ac9bb9bdf7025a608a094",
}
BUILD_PATHS = {"phase3-binary/Package.swift", "phase3-binary/dist/package.sh", ".github/workflows/acceptance-candidate.yml"}
LAB_CONDITION = b"DEBUG || MACPROVIDER_LAB_HARNESS"
SHA = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")

class SourceEquivalenceError(ValueError):
    pass


def require(value, message):
    if not value:
        raise SourceEquivalenceError(message)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate source-equivalence key")
        result[key] = value
    return result


def parse(data: bytes):
    try:
        return json.loads(data, object_pairs_hook=_pairs)
    except (ValueError, UnicodeError) as error:
        raise SourceEquivalenceError("invalid source-equivalence JSON") from error


def git_blob(root: Path, commit: str, path: str) -> bytes:
    require(isinstance(commit, str) and COMMIT.fullmatch(commit), "full source commit required")
    require(isinstance(path, str) and not path.startswith("/") and ".." not in path.split("/"), "unsafe source path")
    prefix = ["git", "-C", str(root)]
    mode = subprocess.run(prefix + ["ls-tree", commit, "--", path], capture_output=True)
    require(mode.returncode == 0 and mode.stdout.startswith((b"100644 blob ", b"100755 blob ")), "source blob missing or not regular: " + path)
    result = subprocess.run(prefix + ["show", f"{commit}:{path}"], capture_output=True)
    require(result.returncode == 0, "source blob missing: " + path)
    return result.stdout


def _decoder():
    path = Path(__file__).resolve().with_name("decode_path_digest.py")
    if not path.is_file():
        # Copy-only tests run beside the frozen production tree.
        path = next(p / "scripts/decode_path_digest.py" for p in Path(__file__).resolve().parents
                    if (p / "scripts/decode_path_digest.py").is_file())
    spec = importlib.util.spec_from_file_location("reviewed_source_equivalence_decoder", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def source_inputs(root: Path, commit: str):
    decoder = _decoder()
    manifest = git_blob(root, commit, "phase3-binary/decode-path-manifest.json")
    resolved = git_blob(root, commit, "phase3-binary/Package.resolved")
    with tempfile.TemporaryDirectory(prefix="native-mtp-source-identity.") as directory:
        package = Path(directory)
        (package / "decode-path-manifest.json").write_bytes(manifest)
        (package / "Package.resolved").write_bytes(resolved)
        files, _ = decoder.load_manifest(package)
        blobs = {}
        for relative in files:
            value = git_blob(root, commit, "phase3-binary/" + relative)
            blobs[relative] = value
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value)
        digest = decoder.compute(package)
    return manifest, resolved, blobs, digest


def source_decode_digest(root: Path, commit: str) -> str:
    return source_inputs(root, commit)[3]


def release_projection(data: bytes) -> bytes:
    """Remove only false DEBUG || LAB branches; preserve all other bytes.

    All directives must occupy their own lines. Unknown conditions are kept
    verbatim, including their branches; no Swift expression evaluation occurs.
    A recognized LAB group may have one #else, but never #elseif. Its release
    branch is copied byte-for-byte, which is checked against measured source.
    """
    lines = data.splitlines(keepends=True)
    directive = re.compile(rb"^[ \t]*#(if|elseif|else|endif)(?:[ \t]+([^\r\n]*))?[ \t]*(?:\r?\n)?$")
    def group(start, closing=False):
        out = []
        index = start
        while index < len(lines):
            line = lines[index]
            match = directive.fullmatch(line)
            if not match:
                out.append(line); index += 1; continue
            kind, condition = match.group(1), (match.group(2) or b"").strip()
            if kind in (b"else", b"elseif", b"endif"):
                require(closing, "unbalanced conditional source")
                return b"".join(out), index, kind
            require(condition, "empty conditional source")
            body, end, terminal = group(index + 1, True)
            if condition == LAB_CONDITION:
                if terminal == b"elseif":
                    raise SourceEquivalenceError("LAB conditional cannot have elseif")
                if terminal == b"else":
                    release, end, terminal = group(end + 1, True)
                    require(terminal == b"endif", "LAB release branch cannot have elseif or extra else")
                    out.append(release)
                require(terminal == b"endif", "unclosed LAB conditional")
            else:
                # Keep unknown conditional text/branches exactly, while any
                # nested explicitly recognized LAB groups are still projected.
                out.extend((line, body))
                while terminal in (b"else", b"elseif"):
                    out.append(lines[end])
                    branch, end, terminal = group(end + 1, True)
                    out.append(branch)
                require(terminal == b"endif", "unclosed conditional source")
                out.append(lines[end])
            index = end + 1
        require(not closing, "unclosed conditional source")
        return b"".join(out), index, None
    return group(0)[0]


def validate_release_build_inputs(blobs: dict[str, bytes]) -> None:
    require(set(blobs) == BUILD_PATHS, "release build input set differs")
    package = blobs["phase3-binary/Package.swift"]
    require(b'MACPROVIDER_LAB_HARNESS' not in package and not re.search(rb'\.define\s*\(\s*"DEBUG"', package), "release package defines LAB or DEBUG")
    command = blobs["phase3-binary/dist/package.sh"]
    # Command-line build settings apply to every target, packages included, so
    # the release command must not set compilation conditions or Swift flags at
    # all; LAB/DEBUG stay excluded because neither the package nor the command
    # defines them. The complete reviewed script is also hash pinned.
    require(b"-configuration Release" in command, "release build must use the Release configuration")
    require(not re.search(rb'(?:SWIFT_ACTIVE_COMPILATION_CONDITIONS|OTHER_SWIFT_FLAGS)\s*=', command),
            "release command must not override compilation conditions or Swift flags")
    require(not re.search(rb'(?:-D[ \t]*|SWIFT_ACTIVE_COMPILATION_CONDITIONS[^\n]*)(?:DEBUG|MACPROVIDER_LAB_HARNESS)', command), "release command enables LAB or DEBUG")
    workflow = blobs[".github/workflows/acceptance-candidate.yml"]
    require(b'./package.sh "$TAG"' in workflow, "candidate workflow does not use reviewed package recipe")
    require(not re.search(rb'(?:-D[ \t]*|SWIFT_ACTIVE_COMPILATION_CONDITIONS[^\n]*)(?:DEBUG|MACPROVIDER_LAB_HARNESS)', workflow), "candidate workflow enables LAB or DEBUG")


def verify_test_only_fork_bridge(expected_inventory_sha256: str) -> None:
    """Verify actual pinned Git objects; never trust a caller's revision label."""
    with tempfile.TemporaryDirectory(prefix="native-mtp-fork-equivalence.") as directory:
        def git(*arguments):
            result = subprocess.run(["git", "-C", directory, *arguments], capture_output=True, timeout=120)
            require(result.returncode == 0, "pinned fork source verification failed")
            return result.stdout
        git("init", "--bare", "-q")
        git("fetch", "--no-tags", "--depth=1", "https://github.com/Augustas11/mlx-swift-lm.git", OLD_FORK, NEW_FORK)
        inventories = [git("ls-tree", "-r", source, "--", "Libraries", "Sources", "Package.swift", "Package.resolved")
                       for source in (OLD_FORK, NEW_FORK)]
        require(inventories[0] and inventories[0] == inventories[1]
                and sha(inventories[0]) == expected_inventory_sha256, "fork production source/package/dependency bytes differ")
        require(git("diff", "--name-only", OLD_FORK, NEW_FORK) == b"Tests/MLXLMTests/GLM5NextTests.swift\n",
                "pinned fork delta is not the exact reviewed test-only change")


def validate_historical_sampled_bridge(root, measured, before, anchor, proof, profile, recipe, *, current_source):
    require(measured == W3_SOURCE and profile == PROFILE, "measured source differs from frozen equivalence anchor")
    require(recipe.get("phases", {}).get("expanded_glm_sampled", {}).get("request_feature_profile") == PROFILE,
            "historical source bridge requires reviewed sampled recipe")
    fields = {"measured_source_commit", "files", "package_resolved_sha256", "package_swift_sha256",
              "profile_decoder_sha256", "fork_inventory_sha256"}
    require(isinstance(proof, dict) and set(proof) == fields and proof["measured_source_commit"] == W3_SOURCE,
            "historical sampled bridge fields differ")
    require(before[0] == anchor[0] and set(before[2]) == set(anchor[2]), "historical decode manifest changed")
    require(proof["files"] == {path: sha(value) for path, value in before[2].items()}, "historical source blobs differ")
    require(sha(before[1]) == proof["package_resolved_sha256"], "historical resolution blob differs")
    old_resolved, new_resolved = parse(before[1]), parse(anchor[1])
    import copy
    normalized = copy.deepcopy(old_resolved)
    selected = [pin for pin in normalized["pins"] if pin.get("identity") == "mlx-swift-lm"]
    require(len(selected) == 1 and selected[0]["state"].get("revision") == OLD_FORK, "historical fork identity differs")
    selected[0]["state"]["revision"] = NEW_FORK
    require(normalized == new_resolved, "historical dependency delta exceeds exact fork pair")
    old_package = git_blob(root, measured, "phase3-binary/Package.swift")
    new_package = git_blob(root, MEASURED_SOURCE, "phase3-binary/Package.swift")
    require(sha(old_package) == proof["package_swift_sha256"], "historical package blob differs")
    require(old_package.count(OLD_FORK.encode()) == 1 and old_package.count(b"3.32.3-macprovider.10.12") == 1,
            "historical package revision binding ambiguous")
    require(old_package.replace(OLD_FORK.encode(), NEW_FORK.encode()).replace(b"3.32.3-macprovider.10.12", b"3.32.3-macprovider.10.13") == new_package,
            "historical package delta exceeds exact fork revision/comment")
    old_decoder = git_blob(root, measured, PROFILE_DECODER_PATH)
    decoder = git_blob(root, MEASURED_SOURCE, PROFILE_DECODER_PATH)
    require(old_decoder == decoder == git_blob(root, current_source, PROFILE_DECODER_PATH)
            and sha(decoder) == proof["profile_decoder_sha256"], "production sampled profile decoder changed")
    require(b'static let sampledRequestFeatureProfile = "native_mtp_sampled_text_v1"' in decoder
            and b'sampling: selected.entry.requestFeatureProfile == Self.sampledRequestFeatureProfile' in decoder
            and b'supportsSampling: parsed.requestProfile.sampling' in decoder,
            "production profile decoder does not derive sampled support")
    for path, old in before[2].items():
        current = anchor[2][path]
        if path == SELECTOR_PATH:
            require(old.count(OLD_SELECTOR) == current.count(NEW_SELECTOR) == 1, "historical selector span differs")
            current = current.replace(NEW_SELECTOR, OLD_SELECTOR)
        require(release_projection(old) == release_projection(current), "historical production decode changed: " + path)
    require(isinstance(proof["fork_inventory_sha256"], str) and SHA.fullmatch(proof["fork_inventory_sha256"]), "fork inventory identity malformed")
    verify_test_only_fork_bridge(proof["fork_inventory_sha256"])


def integration_scope(root: Path) -> dict:
    rows = parse(git_blob(root, INTEGRATION_REVIEWED_SOURCE,
        "phase3-binary/catalog/autotune/native-mtp-admission-tuple.json"))
    entries = [row["entry"] for row in rows if row["entry"].get("model_key") == INTEGRATION_SCOPE["model_key"]]
    require(len(entries) == 1, "integration reviewed tuple missing or ambiguous")
    fields = {"artifact_id", "cache_state_classes", "complete_window_bytes_by_depth", "decode_path",
        "decrease_threshold_ppm", "hardware_class", "hash_algorithm", "increase_threshold_ppm",
        "max_verification_positions_per_committed_milli", "mtp_family_adapter", "mtp_head_count",
        "mtp_manifest_sha256", "mtp_state_class", "quantization", "ram_bytes"}
    return dict({key: entries[0][key] for key in fields}, **INTEGRATION_SCOPE)


def _historical_file_sha(root: Path, measured: str, path: str) -> str | None:
    # Newly introduced decode files have no measured blob. Represent absence
    # explicitly rather than inventing a measured hash or relabeling evidence.
    result = subprocess.run(["git", "-C", str(root), "ls-tree", measured, "--", path], capture_output=True)
    require(result.returncode == 0, "historical source inventory unavailable")
    return sha(git_blob(root, measured, path)) if result.stdout else None


def _reviewed_contract_blob(root: Path, current: str, path: str) -> bytes:
    # A signed release predates its identity-only rebind. Only that exact frozen
    # release may use the contract shipped beside this reviewed verifier; all
    # other callers keep the existing Git-bound recipe/contract selection.
    if current == INTEGRATION_REVIEWED_SOURCE:
        require(path in {RECIPE_PATH, INTEGRATION_CONTRACT_PATH}, "unexpected reviewed contract path")
        target = Path(__file__).resolve().parent.parent / path
        require(target.is_file() and not target.is_symlink(), "reviewed release contract missing or not regular")
        return target.read_bytes()
    return git_blob(root, current, path)


def _reviewed_integration_contract(root: Path, current: str, recipe: dict) -> tuple[dict, bytes]:
    pins = recipe.get("source_inputs")
    require(isinstance(pins, dict) and isinstance(pins.get(INTEGRATION_CONTRACT_PATH), str)
            and SHA.fullmatch(pins[INTEGRATION_CONTRACT_PATH]),
            "reviewed recipe lacks pinned integration reuse contract")
    raw = _reviewed_contract_blob(root, current, INTEGRATION_CONTRACT_PATH)
    require(sha(raw) == pins[INTEGRATION_CONTRACT_PATH], "integration reuse contract is not recipe pinned")
    contract = parse(raw)
    required = {"schema_version", "measured_source_commit", "reviewed_source_commit", "tuple",
                "measured_runtime_revision", "current_runtime_revision", "manifest_sha256",
                "package_resolved", "files", "build_inputs", "reviewed_behavior"}
    require(isinstance(contract, dict) and set(contract) == required, "integration reuse contract fields differ")
    require(contract["schema_version"] == INTEGRATION_SCHEMA
            and contract["measured_source_commit"] == INTEGRATION_MEASURED_SOURCE
            and contract["reviewed_source_commit"] == INTEGRATION_REVIEWED_SOURCE
            and contract["measured_runtime_revision"] == NEW_FORK
            and contract["current_runtime_revision"] == INTEGRATION_FORK
            and contract["tuple"] == integration_scope(root), "integration reuse reviewed scope differs")
    require(isinstance(contract["reviewed_behavior"], list) and all(
        isinstance(item, str) and item for item in contract["reviewed_behavior"]),
        "integration behavior review missing")
    return contract, raw


def verify_integration_reuse(root: Path, measured: str, current: str, before, after,
                             recipe: dict, request_feature_profile: str | None) -> str:
    """Verify an exact reviewed behavior bridge, never claim byte equality.

    The target production/build bytes must match the immutable reviewed merge.
    Re-pinning a contract cannot admit arbitrary later production changes.
    """
    require(measured == INTEGRATION_MEASURED_SOURCE and request_feature_profile == PROFILE,
            "integration reuse measured source/profile differs")
    contract, raw = _reviewed_integration_contract(root, current, recipe)
    reviewed = source_inputs(root, INTEGRATION_REVIEWED_SOURCE)
    require(after == reviewed, "integration target production/dependency identity differs from reviewed merge")
    require(sha(before[0]) == contract["manifest_sha256"],
            "integration decode manifest differs")
    require(contract["package_resolved"] == {
        "measured_sha256": sha(before[1]), "current_sha256": sha(reviewed[1])},
        "integration dependency inventory differs")
    for resolved, expected in ((before[1], NEW_FORK), (reviewed[1], INTEGRATION_FORK)):
        pins = parse(resolved).get("pins", [])
        require([pin.get("state", {}).get("revision") for pin in pins
                 if pin.get("identity") == "mlx-swift-lm"] == [expected],
                "integration fork identity differs")
    require(set(before[2]).issubset(reviewed[2]), "integration source inventory differs")
    expected_files = {path: {
        "measured_sha256": (sha(before[2][path]) if path in before[2]
            else _historical_file_sha(root, measured, "phase3-binary/" + path)),
        "current_sha256": sha(value)} for path, value in reviewed[2].items()}
    if before[0] != reviewed[0]:
        expected_files["decode-path-manifest.json"] = {
            "measured_sha256": sha(before[0]), "current_sha256": sha(reviewed[0])}
    require(contract["files"] == expected_files, "integration source blob inventory differs")
    expected_build = {}
    current_build = {}
    for path in BUILD_PATHS:
        old = git_blob(root, measured, path)
        target = git_blob(root, INTEGRATION_REVIEWED_SOURCE, path)
        actual = git_blob(root, current, path)
        require(actual == target, "integration release build differs from reviewed merge: " + path)
        expected_build[path] = {"measured_sha256": sha(old), "current_sha256": sha(target)}
        current_build[path] = actual
    require(contract["build_inputs"] == expected_build, "integration release build inventory differs")
    validate_release_build_inputs(current_build)
    return sha(raw)


def measurement_tuple(root: Path, measured: str, current: str, measured_digest: str,
                      entry: dict, measured_runtime: str) -> dict:
    """Bind raw evidence to its real runtime after validating current admission.

    Only the exact reviewed integration may bridge a runtime mismatch. Artifact,
    profile and bounds remain those of the admitted tuple in both identities.
    """
    proof = verify_source_equivalence(root, measured, current, measured_digest,
        entry["decode_path_digest"], request_feature_profile=entry["request_feature_profile"])
    if measured == INTEGRATION_MEASURED_SOURCE and measured_digest != entry["decode_path_digest"]:
        recipe = parse(_reviewed_contract_blob(root, current, RECIPE_PATH))
        contract, raw = _reviewed_integration_contract(root, current, recipe)
        require(proof == sha(raw), "integration measurement proof differs")
        require(all(entry.get(key) == value for key, value in contract["tuple"].items()),
                "integration admitted tuple scope differs")
        require(all(entry.get("ordinary_baseline", {}).get(key) == value for key, value in {
                    "artifact_hash": contract["tuple"]["artifact_hash"], "qualified_slots": 4, "decode_path": "ordinary"}.items())
                and entry["runtime_revision"] == INTEGRATION_FORK and measured_runtime == NEW_FORK,
                "integration measurement runtime/artifact differs")
        return dict(entry, runtime_revision=measured_runtime,
                    decode_path_digest=measured_digest, source_commit=measured)
    require(measured_runtime == entry["runtime_revision"], "qualification runtime mismatch")
    return entry


def verify_source_equivalence(root: Path, measured: str, current: str,
                              measured_digest: str, current_digest: str, *, request_feature_profile: str | None = None) -> str | None:
    """Return reviewed delta-contract SHA, or None for equal raw identities."""
    before = source_inputs(root, measured)
    after = source_inputs(root, current)
    require(before[3] == measured_digest and after[3] == current_digest, "source raw decode identity differs")
    if measured_digest == current_digest:
        return None
    recipe_blob = (_reviewed_contract_blob(root, current, RECIPE_PATH)
        if measured == INTEGRATION_MEASURED_SOURCE else git_blob(root, current, RECIPE_PATH))
    recipe = parse(recipe_blob)
    require(recipe.get("schema_version") == "macprovider.native-mtp-binding-recipe.v1"
            and recipe.get("model_key") == "zai-org/glm-5.3-flash", "reviewed recipe identity differs")
    if measured == INTEGRATION_MEASURED_SOURCE and INTEGRATION_CONTRACT_PATH in recipe.get("source_inputs", {}):
        return verify_integration_reuse(root, measured, current, before, after, recipe, request_feature_profile)
    pins = recipe.get("source_inputs")
    require(isinstance(pins, dict) and isinstance(pins.get(CONTRACT_PATH), str) and SHA.fullmatch(pins[CONTRACT_PATH]), "reviewed recipe lacks pinned source-equivalence contract")
    raw = git_blob(root, current, CONTRACT_PATH)
    require(sha(raw) == pins[CONTRACT_PATH], "source-equivalence contract is not recipe pinned")
    contract = parse(raw)
    required = {"schema_version", "measured_source_commit", "lab_patch_sha256", "manifest_sha256", "package_resolved_sha256", "files", "build_inputs"}
    require(isinstance(contract, dict) and set(contract) in (required, required | {"historical_sampled_bridge"}), "source-equivalence contract fields differ")
    require(contract["schema_version"] == SCHEMA and contract["measured_source_commit"] == MEASURED_SOURCE, "source-equivalence measured anchor differs")
    if measured != MEASURED_SOURCE:
        # Older measured policies remain truthful. An equal-byte hop into the
        # frozen campaign source is mechanical, not a source relabel or a new
        # exemption for arbitrary changed decode paths.
        anchor = source_inputs(root, MEASURED_SOURCE)
        if before != anchor:
            validate_historical_sampled_bridge(root, measured, before, anchor,
                contract.get("historical_sampled_bridge"), request_feature_profile, recipe, current_source=current)
        before = anchor
    require(isinstance(contract["lab_patch_sha256"], str) and SHA.fullmatch(contract["lab_patch_sha256"]), "source-equivalence patch identity invalid")
    require(before[0] == after[0] and sha(before[0]) == contract["manifest_sha256"], "decode manifest changed")
    require(before[1] == after[1] and sha(before[1]) == contract["package_resolved_sha256"], "decode dependency resolution changed")
    require(isinstance(contract["files"], dict) and set(contract["files"]) == set(before[2]) == set(after[2]), "source-equivalence file inventory differs")
    for path, old in before[2].items():
        new = after[2][path]
        require(contract["files"][path] == {"measured_sha256": sha(old), "current_sha256": sha(new)}, "source-equivalence source blob mismatch: " + path)
        require(release_projection(old) == release_projection(new), "production decode source changed: " + path)
    require(isinstance(contract["build_inputs"], dict) and set(contract["build_inputs"]) == BUILD_PATHS, "source-equivalence build inventory differs")
    build = {path: git_blob(root, current, path) for path in BUILD_PATHS}
    require({path: sha(value) for path, value in build.items()} == contract["build_inputs"], "reviewed release build bytes differ")
    # Package settings cannot acquire any release-relevant source change.
    require(build["phase3-binary/Package.swift"] == git_blob(root, MEASURED_SOURCE, "phase3-binary/Package.swift"), "release package settings changed")
    validate_release_build_inputs(build)
    return sha(raw)
