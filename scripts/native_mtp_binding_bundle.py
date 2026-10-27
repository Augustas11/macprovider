#!/usr/bin/env python3
"""Closed, reviewed native-MTP binding recipe; not a general release-dir override.

All authority comes from the recipe at the requested git commit, the existing
signed candidate/release verifiers, and re-executed catalog derivation. A signed
inventory alone is insufficient. Never import catalog-release at module import.
"""
from __future__ import annotations
import argparse
import base64
import hashlib
import functools
import importlib.util
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass

RECIPE_PATH = "ops/recipes/native-mtp-glm53-binding.v1.json"
CATALOG = "phase3-binary/catalog/autotune"
STATIC = "phase3-binary/dist/static"
PHASES = {"identity_only_greedy", "expanded_glm_sampled"}
IDENTITY_KEYS = {"provider_revision", "source_commit", "reproducible_build_sha256", "live_executable_cdhash"}
SIDECAR_FILES = {"native-mtp-admission.json", "native-mtp-admission.json.sig", "native-mtp-artifact-manifest.json", "native-mtp-selftest-bank.json", "native-mtp-selftest-bank.json.sig"}
RELEASE_FILES = {"release.json", "trusted-keys.json", "tier2-catalog.json", "autotune-candidates.json", "autotune-candidates.json.sig", "demand-rank.json", "demand-rank.json.sig", "rate-card.json", "rate-card.json.sig", "continuous-batching-policy.json", "continuous-batching-policy.json.sig", "autotune-artifacts.json", "autotune-artifacts.json.sig"} | SIDECAR_FILES

class BindingBundleError(ValueError):
    pass

@dataclass(frozen=True)
class VerifiedBundle:
    release_dir: Path
    ledger_path: Path
    release_input_path: Path
    source_commit: str
    phase: str
    recipe_sha256: str
    receipt_sha256: str


def _closed_errors(function):
    @functools.wraps(function)
    def wrapped(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except SystemExit as exc:
            raise BindingBundleError("existing catalog validation refused binding derivation") from exc
        except (KeyError, TypeError, AttributeError, ET.ParseError, tarfile.TarError, zipfile.BadZipFile) as exc:
            raise BindingBundleError("malformed binding artifact") from exc
    return wrapped


def require(ok: bool, reason: str) -> None:
    if not ok:
        raise BindingBundleError(reason)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def read_json(path: Path):
    require(path.is_file() and not path.is_symlink(), "regular JSON file required")
    return json.loads(path.read_bytes(), object_pairs_hook=_pairs,
                      parse_constant=lambda _: (_ for _ in ()).throw(BindingBundleError("nonfinite JSON")))


def validate_release_directory(directory: Path, *, native_mtp_present: bool) -> None:
    """Require the native sidecar family to be complete before verification."""
    found = {name for name in SIDECAR_FILES if (directory / name).is_file()}
    expected = SIDECAR_FILES if native_mtp_present else set()
    require(found == expected, "native release sidecar file set mismatch")


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()


def digest(path: Path) -> str:
    require(path.is_file() and not path.is_symlink(), "regular input file required")
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(handle.read()).hexdigest()


def _run(args, *, cwd=None, env=None) -> bytes:
    result = subprocess.run([str(x) for x in args], cwd=cwd, env=env, capture_output=True, check=False)
    # Tool stderr may include private paths. Do not include it in public receipts.
    require(result.returncode == 0, "binding derivation prerequisite failed: " + Path(str(args[0])).name)
    return result.stdout


def git(repo: Path, *args) -> bytes:
    return _run(["git", "-C", repo, *args])


def _module(repo: Path, filename: str):
    name = "binding_" + filename.replace("-", "_").replace(".", "_")
    spec = importlib.util.spec_from_file_location(name, repo / "scripts" / filename)
    require(spec is not None and spec.loader is not None, "missing reviewed verifier")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    # Existing verifier modules import sibling helpers.
    old = list(sys.path)
    try:
        sys.path.insert(0, str(repo / "scripts"))
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = old
    return module


def _relative(name: str) -> bool:
    return isinstance(name, str) and bool(name) and not PurePosixPath(name).is_absolute() and all(x not in {"", ".", ".."} for x in name.split("/")) and "\\" not in name


def inventory(directory: Path, *, exclude=frozenset()) -> dict[str, str]:
    require(directory.is_dir() and not directory.is_symlink(), "regular bundle directory required")
    result = {}
    for path in sorted(directory.rglob("*")):
        require(not path.is_symlink(), "symlinks are forbidden in binding artifacts")
        if path.is_dir():
            continue
        require(path.is_file(), "nonregular binding artifact")
        name = path.relative_to(directory).as_posix()
        require(_relative(name), "unsafe bundle member")
        if name not in exclude:
            result[name] = digest(path)
    return result


def _copy_tree(source: Path, target: Path) -> None:
    files = inventory(source)
    target.mkdir(parents=True, exist_ok=False)
    for name in files:
        out = target / name
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, out)


def _archive(repo: Path, commit: str, target: Path) -> None:
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "archive requires full source commit")
    target.mkdir(parents=True, exist_ok=True)
    data = git(repo, "archive", "--format=tar", commit)
    archive = target / ".binding-source.tar"
    archive.write_bytes(data)
    with tarfile.open(archive) as handle:
        for member in handle.getmembers():
            require(_relative(member.name) and (member.isfile() or member.isdir()), "unsafe reviewed source archive")
            handle.extract(member, target)
    archive.unlink()


def _recipe(repo: Path, commit: str, recipe_path: str):
    require(recipe_path == RECIPE_PATH, "only the reviewed native binding recipe is supported")
    require(re.fullmatch(r"[0-9a-f]{40}", commit) is not None, "full source commit required")
    require(git(repo, "rev-parse", f"{commit}^{{commit}}").decode().strip() == commit, "source commit mismatch")
    _run(["git", "-C", repo, "merge-base", "--is-ancestor", commit, "origin/main"])
    raw = git(repo, "show", f"{commit}:{recipe_path}")
    recipe = json.loads(raw, object_pairs_hook=_pairs)
    require(set(recipe) == {"schema_version", "model_key", "source_inputs", "phases", "reused_evidence_keys", "security_required_cases", "security_artifact_name"}, "recipe fields")
    require(recipe["reused_evidence_keys"] == ["fit_evidence_sha256", "quality_evidence_sha256", "state_rollback_evidence_sha256"], "recipe reused evidence scope")
    require(recipe["schema_version"] == "macprovider.native-mtp-binding-recipe.v1" and recipe["model_key"] == "zai-org/glm-5.3-flash", "recipe identity")
    require(set(recipe["phases"]) == PHASES, "recipe phases")
    for phase, profile in (("identity_only_greedy", "native_mtp_greedy_text_v1"), ("expanded_glm_sampled", "native_mtp_sampled_text_v1")):
        require(recipe["phases"][phase] == {"request_feature_profile": profile, "proposal_depth": 1, "max_native_active_rows": 1, "max_prompt_tokens": 4096, "qualified_slots": 4}, "unsupported recipe scope")
    return recipe, hashlib.sha256(raw).hexdigest()


def _environment(repo: Path, commit: str, previous: Path) -> dict[str, str]:
    env = dict(os.environ)
    # No environmental source/ref/artifact activation override can widen recipe.
    env.pop("OPENSSL_BIN", None)
    env.pop("AUTOTUNE_ACTIVATE_ARTIFACT_FEED", None)
    env["CATALOG_RELEASE_BASE_REF"] = commit
    env["GIT_DIR"] = git(repo, "rev-parse", "--absolute-git-dir").decode().strip()
    env["AUTOTUNE_PREVIOUS_RELEASE_DIR"] = str(previous)
    return env


def validate_acceptance(result: dict, policy: dict, corpus: dict, tuple_entry: dict, *, policy_sha: str, corpus_sha: str) -> None:
    """Validate actual R005 numeric records, not a passed:true attestation."""
    require(result.get("schema") == "macprovider.native-mtp-acceptance-result.v1" and result.get("status") == "pass", "R005 schema/status")
    require(policy.get("schema") == "macprovider.native-mtp-acceptance-policy.v1", "R005 policy schema")
    require(result.get("policy_sha256") == policy_sha and result.get("corpus_sha256") == policy.get("corpus_sha256") == corpus_sha, "R005 frozen inputs mismatch")
    require(result.get("evidence_class") == "lab_isolated_no_join", "R005 evidence class")
    for key in ("model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256", "provider_commit"):
        require(result.get(key) == policy.get(key), "R005 policy binding mismatch")
    require(policy.get("model_id") == tuple_entry["model_key"] and policy.get("target_sha256") == tuple_entry["ordinary_baseline"]["artifact_hash"] and policy.get("mtp_sha256") == tuple_entry["artifact_hash"] and policy.get("tokenizer_sha256") == tuple_entry["tokenizer_sha256"], "R005 artifact binding mismatch")
    for key in ("proposal_depth", "qualified_slots", "max_native_active_rows", "max_prompt_tokens"):
        require(result.get(key) == tuple_entry[key], "R005 tuple bounds mismatch")
    checks = result.get("checks")
    required = {"all_cases_passed", "native_positions", "all_and_none_acceptance", "partial_acceptance_inapplicable", "eos_terminal", "stop_sequence_terminal", "max_tokens_terminal", "generated_tool_boundary", "generated_reasoning_close", "near_tied_positions"}
    require(isinstance(checks, dict) and set(checks) == required and all(value is True for value in checks.values()), "R005 required checks")
    cases = result.get("cases")
    corpus_cases = corpus.get("cases")
    require(isinstance(cases, list) and isinstance(corpus_cases, list) and len(cases) == len(corpus_cases) and len(cases) >= 200, "R005 corpus incomplete")
    require([case.get("id") for case in cases] == [case.get("id") for case in corpus_cases] and len({case.get("id") for case in cases}) == len(cases), "R005 case identity/order")
    visible = validate_acceptance_rows(cases, corpus_cases)
    require(visible >= 6400 and result.get("native_compared_positions") == visible, "R005 compared position floor")


def validate_measurement_identity(record: dict, identity: dict, *, label: str) -> None:
    """Bind runtime-measured bytes to the independently authenticated candidate.

    Source-equivalent LAB bytes are deliberately insufficient: qualification
    must have run inside the signed executable intended for promotion.
    """
    expected = {"binary_sha256": identity["reproducible_build_sha256"],
                "binary_cdhash": identity["live_executable_cdhash"]}
    require(isinstance(record, dict) and record.get("measurement_identity") == expected,
            label + " signed measurement executable identity mismatch")


def validate_formal_bench(q: Path, *, stage: Path, entry: dict, identity: dict) -> None:
    """Reopen the formal R015 matrix and sustained window, never a summary."""
    analyzer = _module(stage, "native_mtp_r015_analyze.py")
    policy = read_json(q / "bench-policy.json")
    require(policy.get("schema") == "macprovider.native-mtp-r015-policy.v1",
            "formal R015 policy required")
    require(policy.get("provider_commit") == identity["source_commit"],
            "formal R015 signed candidate source mismatch")
    for field, expected in {
        "model_id": entry["model_key"],
        "target_sha256": entry["ordinary_baseline"]["artifact_hash"],
        "mtp_sha256": entry["artifact_hash"],
        "tokenizer_sha256": entry["tokenizer_sha256"],
        "mlx_fork_revision": entry["runtime_revision"],
        "qualified_slots": entry["qualified_slots"],
        "max_native_active_rows": entry["max_native_active_rows"],
        "proposal_depth": entry["proposal_depth"],
        "maximum_prompt_tokens": entry["max_prompt_tokens"],
    }.items():
        require(policy.get(field) == expected, "formal R015 tuple/artifact binding mismatch")
    header, runs = analyzer._load_jsonl(q / "bench.jsonl")
    require(header.get("provider_commit") == identity["source_commit"],
            "formal R015 signed candidate source mismatch")
    validate_measurement_identity(header, identity, label="R015 header")
    require(bool(runs) and any(run.get("sustained") is True for run in runs),
            "formal R015 sustained records required")
    for run in runs:
        validate_measurement_identity(run, identity, label="R015 run")
    result = analyzer.analyze(q / "bench.jsonl", q / "bench-policy.json")
    require(result.get("overall_status") == "PASS", "formal R015 analyzer gate failed")
    require(read_json(q / "bench-analysis.json") == result,
            "formal R015 supplied analysis is not the rederived result")


def validate_acceptance_rows(cases: list, corpus_cases: list) -> int:
    """Shared full numeric validation; prefix resumption never trusts pass flags."""
    visible = 0
    for case, frozen_case in zip(cases, corpus_cases):
        require(case.get("stratum") == frozen_case.get("stratum") and case.get("expected_native") is frozen_case.get("expected_native"), "R005 frozen stratum/admission mismatch")
        require(case.get("passed") is True and case.get("admission_passed") is True and case.get("output_parity") is True and case.get("oracle_failure") is None, "R005 case failure")
        require(case.get("ordinary_terminal") == case.get("native_terminal") and case.get("native_terminal") in {"eos", "stopSequence", "maxTokens", "toolBoundary", "other"}, "R005 terminal mismatch")
        positions, selected = case.get("positions"), case.get("selected_positions")
        require(isinstance(positions, list) and isinstance(selected, list) and bool(selected), "R005 selected positions absent")
        require(case.get("ordinary_selected_count") == case.get("native_selected_count") == len(selected), "R005 selected count mismatch")
        require(len(positions) == case.get("completion_tokens") and len(positions) <= 256, "R005 visible count mismatch")
        for values in (positions, selected):
            require([p.get("position") for p in values] == list(range(len(values))), "R005 position order")
            for pos in values:
                require(pos.get("token_exact") is True and pos.get("top1_exact") is True and pos.get("finite") is True and pos.get("ordinary_token") == pos.get("native_token") and type(pos.get("ordinary_token")) is int, "R005 token/top1 parity")
                require(pos.get("ordinary_top1") == pos.get("native_top1") and type(pos.get("ordinary_top1")) is int, "R005 actual top1 mismatch")
                for key in ("max_abs_difference", "ordinary_gap", "native_gap"):
                    value = pos.get(key)
                    require(type(value) in (int, float) and math.isfinite(value) and value >= 0, "R005 nonfinite numeric record")
                require(pos["max_abs_difference"] <= 0.05, "R005 numeric tolerance")
        require(selected[:len(positions)] == positions, "R005 visible prefix mismatch")
        if case.get("expected_native") is True:
            visible += len(positions)
    return visible


def validate_acceptance_checkpoint(value: dict, policy: dict, corpus: dict, *, policy_sha: str, corpus_sha: str) -> dict:
    """A private complete-case prefix, never a partial acceptance verdict."""
    require(set(value) == {"schema", "provider_commit", "policy_sha256", "corpus_sha256", "cases"}, "checkpoint fields")
    require(value["schema"] == "macprovider.native-mtp-acceptance-checkpoint.v1", "checkpoint schema")
    require(value["provider_commit"] == policy["provider_commit"] and value["policy_sha256"] == policy_sha and value["corpus_sha256"] == policy["corpus_sha256"] == corpus_sha, "checkpoint frozen identity")
    rows = value["cases"]
    require(isinstance(rows, list) and 0 <= len(rows) <= len(corpus["cases"]), "checkpoint prefix bounds")
    frozen = corpus["cases"][:len(rows)]
    require([r.get("id") for r in rows] == [r["id"] for r in frozen] and len({r.get("id") for r in rows}) == len(rows), "checkpoint prefix/order/duplicates")
    visible = validate_acceptance_rows(rows, frozen)
    accepted = rejected = near = 0
    terminals = set(); tool = reasoning = False
    for row, case in zip(rows, frozen):
        limits = {"short": (1, 512), "1.5k": (1505, 1566), "4k": (4015, 4096), "8k": (8029, 8355), "near_boundary": (4032, 4096)}
        lo, hi = limits[case["stratum"]]
        require(row.get("prompt_stratum_passed") is True and type(row.get("prompt_tokens")) is int and lo <= row["prompt_tokens"] <= hi, "checkpoint actual prompt stratum")
        observed = row.get("checkpoint_observations")
        require(isinstance(observed, dict) and set(observed) == {"accepted", "rejected", "proposed", "decode_path", "tool_call_count", "reasoning_nonempty", "content_nonempty", "conversation_cache_key_absent"}, "checkpoint actual observations")
        for key in ("accepted", "rejected", "proposed", "tool_call_count"):
            require(type(observed[key]) is int and 0 <= observed[key] <= 2**63-1, "checkpoint observed counter")
        require(observed["accepted"] + observed["rejected"] == observed["proposed"], "checkpoint proposal accounting")
        require(all(type(observed[k]) is bool for k in ("reasoning_nonempty", "content_nonempty", "conversation_cache_key_absent")) and observed["conversation_cache_key_absent"], "checkpoint request-local no-cache contract")
        require(observed["decode_path"] == ("native_mtp" if case["expected_native"] else "ordinary") and (observed["proposed"] > 0 if case["expected_native"] else observed["proposed"] == 0), "checkpoint actual admission")
        if case["expected_native"]:
            accepted += observed["accepted"]; rejected += observed["rejected"]
            require(accepted <= 2**64-1 and rejected <= 2**64-1 and accepted + rejected <= 2**64-1, "checkpoint aggregate counter overflow")
            terminals.add(row["native_terminal"])
            tool |= observed["tool_call_count"] > 0
            reasoning |= observed["reasoning_nonempty"] and (observed["content_nonempty"] or observed["tool_call_count"] > 0)
            near += sum(p["ordinary_gap"] <= .05 for p in row["positions"])
    return dict(native_positions=visible, accepted=accepted, rejected=rejected, terminals=sorted(terminals), tool_boundary=tool, reasoning_close=reasoning, near_tied_positions=near)


def validate_security_artifact(q: Path, *, repo: Path, source: dict, recipe: dict, prior_evidence: str) -> str:
    """Fresh authenticated Actions metadata, actual ZIP/XML, and audit records.

    Stored API JSON is only a frozen input; fresh authenticated gh responses
    independently pin its run/head/artifact digest. Audit records are authentic
    operator-custody records signed by the final bundle, not GitHub approvals.
    """
    frozen = read_json(q / "security-actions.json")
    require(set(frozen) == {"run_id", "source_commit", "artifacts"}, "security Actions binding fields")
    require(type(frozen["run_id"]) is int and frozen["run_id"] > 0 and frozen["source_commit"] == source["source_commit"], "security Actions source/run identity")
    def fetch(endpoint):
        return json.loads(_run(["gh", "api", endpoint]), object_pairs_hook=_pairs)
    run = fetch(f"repos/Augustas11/macprovider/actions/runs/{frozen['run_id']}")
    require(run.get("id") == frozen["run_id"] and run.get("head_sha") == frozen["source_commit"] and run.get("status") == "completed" and run.get("conclusion") == "success" and run.get("path") == ".github/workflows/ci.yml" and run.get("repository", {}).get("full_name") == "Augustas11/macprovider", "fresh successful security CI run required")
    artifacts = frozen["artifacts"]
    require(isinstance(artifacts, list) and len(artifacts) == 4 and [a.get("shard") for a in artifacts] == [1, 2, 3, 4], "all four security CI shards required")
    actual, seen, report_digests = set(), set(), {}
    for item in artifacts:
        require(set(item) == {"shard", "artifact_id", "artifact_sha256"} and type(item["artifact_id"]) is int and item["artifact_id"] > 0, "security artifact binding fields")
        artifact = fetch(f"repos/Augustas11/macprovider/actions/artifacts/{item['artifact_id']}")
        name = recipe["security_artifact_name"].format(shard=item["shard"], sha=source["source_commit"])
        require(artifact.get("id") == item["artifact_id"] and artifact.get("name") == name and artifact.get("expired") is False and artifact.get("workflow_run", {}).get("id") == frozen["run_id"] and artifact.get("workflow_run", {}).get("head_sha") == frozen["source_commit"], "fresh security artifact identity mismatch")
        archive_path = q / f"security-tests-{item['shard']}.zip"
        archive_sha = digest(archive_path)
        require(artifact.get("digest") == "sha256:" + archive_sha and archive_sha == item["artifact_sha256"], "security ZIP differs from authenticated Actions digest")
        with zipfile.ZipFile(archive_path) as archive:
            require(archive.namelist() == ["shard-xunit.xml"], "security artifact must contain exactly shard-xunit.xml")
            member = archive.getinfo("shard-xunit.xml")
            require(member.file_size <= 16 * 1024 * 1024 and not member.is_dir(), "security report size")
            report = archive.read(member)
        require(b"<!DOCTYPE" not in report and b"<!ENTITY" not in report, "security report XML entities forbidden")
        report_digests[str(item["shard"])] = hashlib.sha256(report).hexdigest()
        xml = ET.fromstring(report)
        for case in xml.iter("testcase"):
            require(not any(case.find(tag) is not None for tag in ("failure", "error")), "security CI has failed cases")
            classname, name = case.get("classname", "").split(".")[-1], case.get("name", "").removesuffix("()")
            identity = classname + "." + name
            require(identity not in seen, "duplicate security CI case")
            seen.add(identity)
            if case.find("skipped") is None:
                actual.add(identity)
    require(set(recipe["security_required_cases"]) <= actual, "required sampled-profile security cases missing or skipped")
    audit = read_json(q / "audit.json")
    require(set(audit) == {"schema_version", "source_commit", "base_commit", "diff_sha256", "lanes"} and audit["schema_version"] == "macprovider.native-mtp-audit-record.v1", "actual audit record schema required")
    require(audit["source_commit"] == source["source_commit"] and re.fullmatch(r"[0-9a-f]{40}", audit["base_commit"]) is not None, "audit source binding")
    diff = git(repo, "diff", "--binary", audit["base_commit"], audit["source_commit"])
    require(audit["diff_sha256"] == hashlib.sha256(diff).hexdigest(), "audit full combined diff mismatch")
    lanes = audit["lanes"]
    require(isinstance(lanes, dict) and set(lanes) == {"code", "security", "architecture"}, "three actual audit lanes required")
    lane_hashes = {}
    for lane, record in lanes.items():
        require(set(record) == {"record_sha256", "findings"} and isinstance(record["findings"], list), "audit lane record fields")
        path = q / ("audit-" + lane + ".md")
        lane_hashes[lane] = digest(path)
        require(record["record_sha256"] == lane_hashes[lane] and path.stat().st_size > 0, "audit raw record missing/mismatch")
        for finding in record["findings"]:
            require(isinstance(finding, dict) and finding.get("severity") in {"LOW", "INFO"} and isinstance(finding.get("id"), str) and bool(finding["id"]), "audit is not zero critical/high/medium")
    aggregate = {"schema_version": "macprovider.native-mtp-security-evidence.v1", "prior_hardware_negative_evidence_sha256": prior_evidence, "actions": frozen, "junit_sha256_by_shard": report_digests, "audit_sha256": digest(q / "audit.json"), "audit_records": lane_hashes}
    require(read_json(q / "security-evidence.json") == aggregate, "security aggregator differs from actual validated inputs")
    return digest(q / "security-evidence.json")


def validate_representative_replay(q: Path, *, stage: Path, repo: Path, current_source: str,
                                   entry: dict, scratch: Path, identity: dict) -> dict:
    """Recompute representative v2 projection, real paired runs and analysis."""
    original_repo = Path(repo)
    equivalence = _module(stage, "native_mtp_source_equivalence.py")
    replay = _module(stage, "native_mtp_request_shape_replay.py")
    capture_header, _ = replay.load_capture(q / "capture.json")
    require(capture_header["schema"] == replay.CAPTURE_SCHEMA_V2, "expanded scope requires mode-independent privacy-safe v2 capture")
    frozen_policy, frozen_plan = read_json(q / "replay-policy.json"), read_json(q / "projection-plan.json")
    privacy = read_json(q / "privacy-review.json")
    require(set(privacy) == {"privacy_review_id", "privacy_reviewed_at"} and all(privacy.get(k) == frozen_policy.get(k) for k in privacy), "privacy review input mismatch")
    require(digest(q / "preregistration.json") == frozen_policy["preregistration_digest_sha256"], "raw preregistration digest mismatch")
    bounds = replay.load_tuple_bounds(q / "tuple-bounds.json", replay.CAPTURE_SCHEMA_V2)
    require(bounds["request_feature_profile"] == entry["request_feature_profile"] and bounds["maximum_prompt_tokens"] == entry["max_prompt_tokens"] and bounds["maximum_proposal_depth"] == entry["proposal_depth"] and bounds["family_adapter"] == entry["mtp_family_adapter"], "projected tuple scope mismatch")
    sample = frozen_plan["sample_report"]
    projected_policy, projected_plan = replay.project_capture(q / "capture.json", q / "tuple-bounds.json", blocks=len(frozen_plan["blocks"]), privacy_review_id=privacy["privacy_review_id"], privacy_reviewed_at=privacy["privacy_reviewed_at"], preregistration_digest=digest(q / "preregistration.json"), seed=frozen_policy["seed"], sampling_plan_id=sample["sampling_plan_id"], sample_period_start=sample["sample_period_start"], sample_period_end=sample["sample_period_end"], bench_policy_path=q / "bench-policy.json")
    require(projected_policy == frozen_policy and projected_plan == frozen_plan, "capture projection does not rederive frozen policy/plan")
    replay_header, _ = replay._load_replay_runs(q / "replay.json", frozen_policy, digest(q / "replay-policy.json"), digest(q / "capture.json"))
    validate_measurement_identity(replay_header, identity, label="representative replay")
    require(replay_header.get("provider_commit") == identity["source_commit"],
            "representative replay signed candidate source mismatch")
    require(replay_header["mixed_rows"] == entry["qualified_slots"] and replay_header["max_native_active_rows"] == entry["max_native_active_rows"] and replay_header["tuple_bounds_sha256"] == digest(q / "tuple-bounds.json") and replay_header["bench_policy_sha256"] == digest(q / "bench-policy.json"), "R015 full-slot/frozen-input binding mismatch")
    expected_artifacts = {"model_id": entry["model_key"], "target_sha256": entry["ordinary_baseline"]["artifact_hash"],
                          "mtp_sha256": entry["artifact_hash"], "tokenizer_sha256": entry["tokenizer_sha256"]}
    for key, expected in expected_artifacts.items():
        require(replay_header[key] == expected, "R015 artifact identity mismatch")
    try:
        measured_replay_digest = equivalence.source_decode_digest(original_repo, replay_header["provider_commit"])
        equivalence.verify_source_equivalence(original_repo, replay_header["provider_commit"],
            current_source,
            measured_replay_digest, entry["decode_path_digest"], request_feature_profile=entry["request_feature_profile"])
    except equivalence.SourceEquivalenceError as error:
        raise BindingBundleError(str(error)) from error
    records = replay.convert_replay_to_analyzer_jsonl(q / "replay.json", q / "replay-policy.json", capture_sha256=digest(q / "capture.json"))
    out = scratch / "replay-analyzer.jsonl"
    replay.write_replay_analyzer_jsonl(records, out)
    analyzer = _module(stage, "native_mtp_post_gateway_replay_analyze.py")
    result = analyzer.analyze(out, q / "replay-policy.json")
    require(result.get("overall_status") == "PASS", "R015 analyzer gate failed")
    require(read_json(q / "analysis.json") == result, "R015 supplied analysis is not the rederived result")
    return {"batch_evidence_sha256": digest(q / "replay.json"),
            "performance_evidence_sha256": digest(q / "analysis.json"),
            "benchmark_policy_sha256": digest(q / "replay-policy.json")}


def _qualification(stage: Path, bundle: Path, entry: dict, recipe: dict, *, repo: Path) -> dict:
    q = bundle / "qualification"
    identity = read_json(bundle / "inputs.json")["identity"]
    acceptance = read_json(q / "acceptance.json")
    policy = read_json(q / "acceptance-policy.json")
    corpus = read_json(q / "acceptance-corpus.json")
    validate_measurement_identity(acceptance, identity, label="R005")
    require(policy.get("provider_commit") == identity["source_commit"],
            "R005 signed candidate source mismatch")
    validate_acceptance(acceptance, policy, corpus, entry, policy_sha=digest(q / "acceptance-policy.json"), corpus_sha=digest(q / "acceptance-corpus.json"))
    source = read_json(q / "source.json")
    require(set(source) == {"source_commit", "decode_path_digest"} and source["source_commit"] == policy["provider_commit"], "qualification source binding")
    # Caller source digest assertions are insufficient: recompute at lab commit.
    original_repo = Path(repo)
    equivalence = _module(stage, "native_mtp_source_equivalence.py")
    try:
        equivalence.verify_source_equivalence(original_repo, source["source_commit"],
            read_json(bundle / "inputs.json")["identity"]["source_commit"],
            source["decode_path_digest"], entry["decode_path_digest"], request_feature_profile=entry["request_feature_profile"])
    except equivalence.SourceEquivalenceError as error:
        raise BindingBundleError(str(error)) from error
    require(policy["mlx_fork_revision"] == entry["runtime_revision"], "qualification runtime mismatch")
    validate_formal_bench(q, stage=stage, entry=entry, identity=identity)
    representative = validate_representative_replay(q, stage=stage, repo=original_repo,
        current_source=identity["source_commit"], entry=entry, scratch=stage.parent, identity=identity)
    security_source = read_json(q / "security-actions.json").get("source_commit")
    require(isinstance(security_source, str) and re.fullmatch(r"[0-9a-f]{40}", security_source) is not None, "security CI full source commit required")
    final_source = read_json(bundle / "inputs.json")["identity"]["source_commit"]
    require(git(original_repo, "rev-parse", f"{security_source}^{{tree}}") == git(original_repo, "rev-parse", f"{final_source}^{{tree}}"), "security CI/audit tree differs from merged reviewed source")
    security_sha = validate_security_artifact(q, repo=original_repo, source={"source_commit": security_source}, recipe=recipe, prior_evidence=entry["security_negative_evidence_sha256"])
    return {"security_negative_evidence_sha256": security_sha, "correctness_evidence_sha256": digest(q / "acceptance.json"), **representative}


@_closed_errors
def validate_serving_qualification(bundle: Path, *, repo: Path, source_commit: str,
                                   sidecar_path: Path, entry_index: int) -> dict:
    """Reopen real qualification before sealing, without serving-proof recursion.

    The caller compares these five digests to its sidecar and step-14 inputs.
    This is not a signed serving result or an activation receipt. All source
    code is staged from reviewed main; subprocess environment is passed locally.
    """
    bundle, repo = Path(bundle).resolve(), Path(repo).resolve()
    recipe, _ = _recipe(repo, source_commit, RECIPE_PATH)
    inputs = read_json(bundle / "inputs.json")
    require(inputs.get("phase") == "expanded_glm_sampled" and inputs.get("identity", {}).get("source_commit") == source_commit,
            "qualification bundle source/phase mismatch")
    require((bundle / "release/native-mtp-admission.json").read_bytes() == Path(sidecar_path).read_bytes(),
            "qualification sidecar differs from derived signed release")
    with tempfile.TemporaryDirectory(prefix="native-serving-qualification-") as directory:
        stage = Path(directory) / "source"
        _archive(repo, source_commit, stage)
        for name, expected in recipe["source_inputs"].items():
            require(_relative(name) and digest(stage / name) == expected, "reviewed recipe source input changed")
        generator = _module(stage, "native_mtp_admission_sidecar.py")
        sidecar = generator.validate_sidecar(generator.strict_json_loads(Path(sidecar_path).read_text()))
        require(type(entry_index) is int and 0 <= entry_index < len(sidecar["entries"]), "qualification entry index invalid")
        entry = sidecar["entries"][entry_index]
        require(entry["model_key"] == recipe["model_key"], "qualification model differs from reviewed recipe")
        for key, expected in recipe["phases"]["expanded_glm_sampled"].items():
            require(entry[key] == expected, "qualification profile/bounds differ from recipe")
        require(all(entry[key] == inputs["identity"][key] for key in IDENTITY_KEYS | {"metallib_sha256"}),
                "qualification sidecar code identity differs")
        # The aggregator always begins with the reviewed original hardware
        # negatives, not its own already-aggregated output from the new sidecar.
        originals = [row["entry"] for row in read_json(stage / CATALOG / "native-mtp-admission-tuple.json")
                     if row["entry"]["model_key"] == recipe["model_key"]]
        require(len(originals) == 1, "ambiguous original qualification tuple")
        original = originals[0]
        require(all(entry[key] == original[key] for key in recipe["reused_evidence_keys"]), "reused hardware evidence changed")
        env = _environment(repo, source_commit, bundle / "previous")
        env["GIT_WORK_TREE"] = str(stage)
        _run([sys.executable, stage / "scripts/catalog-release.py", "verify-directory",
              "--directory", bundle / "release", "--tier2-coordinator-config", stage / "phase4-coordinator/dist/coordinator.yaml"],
             cwd=stage, env=env)
        import copy
        qualifying = copy.deepcopy(entry)
        qualifying["security_negative_evidence_sha256"] = original["security_negative_evidence_sha256"]
        result = _qualification(stage, bundle, qualifying, recipe, repo=repo)
        require(all(entry[key] == value for key, value in result.items()), "sidecar qualification digests differ from actual evidence")
        return result


def _flat(stage: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for name in RELEASE_FILES:
        source = stage / (CATALOG if name in {"release.json", "trusted-keys.json", "tier2-catalog.json"} else STATIC) / name
        require(source.is_file(), "reviewed native pair release asset missing")
        shutil.copyfile(source, target / name)


def _derive(bundle: Path, *, repo: Path, commit: str, recipe: dict, stage: Path, sign: bool = False) -> None:
    if not stage.exists():
        _archive(repo, commit, stage)
    for name, expected in recipe["source_inputs"].items():
        require(_relative(name) and digest(stage / name) == expected, "reviewed recipe source input changed")
    inputs = read_json(bundle / "inputs.json")
    require(set(inputs) == {"schema_version", "phase", "release_id", "generated_at", "candidate_version", "identity", "parent_receipt_sha256"}, "binding input fields")
    require(inputs["schema_version"] == "macprovider.native-mtp-binding-input.v1" and inputs["phase"] in PHASES, "binding input identity")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,119}", inputs["release_id"]) is not None, "unsafe release identity")
    identity = inputs["identity"]
    require(set(identity) == IDENTITY_KEYS | {"metallib_sha256"}, "identity input fields")
    require(identity["source_commit"] == identity["provider_revision"] == commit, "candidate merged source mismatch")
    require(re.fullmatch(r"[0-9a-f]{64}", identity["reproducible_build_sha256"]) is not None and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", identity["live_executable_cdhash"]) is not None and re.fullmatch(r"[0-9a-f]{64}", identity["metallib_sha256"]) is not None, "candidate identity malformed")
    cat = stage / CATALOG
    previous = bundle / "previous"
    require((previous / "trusted-keys.json").read_bytes() == (cat / "trusted-keys.json").read_bytes(), "recipe cannot replace predecessor trust roots")
    if inputs["phase"] == "expanded_glm_sampled":
        parent = verify_bundle(bundle / "parent", repo=repo, commit=commit, recipe_path=RECIPE_PATH)
        require(parent.phase == "identity_only_greedy" and inputs["parent_receipt_sha256"] == parent.receipt_sha256, "expanded phase requires exact greedy binding predecessor")
        require(inventory(previous) == inventory(parent.release_dir), "expanded predecessor differs from verified parent")
        parent_inputs = read_json(bundle / "parent/inputs.json")
        require(inputs["identity"] == parent_inputs["identity"] and inputs["candidate_version"] == parent_inputs["candidate_version"], "expanded phase must retain exact signed CLI identity")
        shutil.copyfile(parent.ledger_path, cat / "release-ledger.json")
    else:
        require(inputs["parent_receipt_sha256"] is None and not (bundle / "parent").exists(), "identity phase cannot replace ledger predecessor")
    env = _environment(repo, commit, previous)
    env["GIT_WORK_TREE"] = str(stage)
    _run([sys.executable, stage / "scripts/catalog-release.py", "restamp", "--release-id", inputs["release_id"], "--generated-at", inputs["generated_at"]], cwd=stage, env=env)
    dp = _module(stage, "decode_path_digest.py")
    path_digest = dp.compute(stage / "phase3-binary")
    revisions = dp.resolved_revisions(stage / "phase3-binary")
    runtime = revisions["mlx-swift-lm"]
    release_path = cat / "native-mtp-admission-release.json"
    release = read_json(release_path)
    release["provider_decode_path_digest"] = path_digest
    release["entry"].update({k: identity[k] for k in IDENTITY_KEYS})
    release_path.write_bytes(canonical(release))
    tuple_path = cat / "native-mtp-admission-tuple.json"
    tuples = read_json(tuple_path)
    require(isinstance(tuples, list), "reviewed tuple inventory must be an array")
    selected = []
    for row in tuples:
        entry = row["entry"]
        entry.update(decode_path_digest=path_digest, runtime_revision=runtime, metallib_sha256=identity["metallib_sha256"])
        if entry["model_key"] == recipe["model_key"]:
            selected.append(entry)
    require(len(selected) == 1, "ambiguous GLM recipe tuple")
    target = selected[0]
    bounds = recipe["phases"][inputs["phase"]]
    require(set(bounds) == {"request_feature_profile", "proposal_depth", "max_native_active_rows", "max_prompt_tokens", "qualified_slots"}, "recipe bounds fields")
    for key in ("proposal_depth", "max_native_active_rows", "max_prompt_tokens", "qualified_slots"):
        require(target[key] == bounds[key], "recipe cannot widen row/depth/context/CB bounds")
    target["request_feature_profile"] = bounds["request_feature_profile"]
    if inputs["phase"] == "expanded_glm_sampled":
        target.update(_qualification(stage, bundle, target, recipe, repo=repo))
    tuple_path.write_bytes(canonical(tuples))
    tool = [sys.executable, stage / "scripts/catalog-release.py"]
    # Existing signatures are reused during verification, then rechecked against
    # deterministic regenerated feed bytes. No signing key is needed to verify.
    if not sign:
        for name in RELEASE_FILES:
            if name.endswith(".sig"):
                shutil.copyfile(bundle / "release" / name, stage / STATIC / name)
    _run(tool + ["generate", "--signer-key-id", release["signer_key_id"], "--previous-release-dir", previous], cwd=stage, env=env)
    if sign:
        _run(["bash", stage / "scripts/resign-autotune-static.sh"], cwd=stage, env=env)
    _run(tool + ["verify", "--previous-release-dir", previous], cwd=stage, env=env)
    require((cat / "tier2-catalog.json").read_bytes() == git(repo, "show", f"{commit}:{CATALOG}/tier2-catalog.json"), "recipe cannot change Tier2 payload")
    _run(tool + ["verify-directory", "--directory", previous, "--tier2-coordinator-config", stage / "phase4-coordinator/dist/coordinator.yaml"], cwd=stage, env=env)


def _candidate_gate(stage: Path, bundle: Path, inputs: dict) -> None:
    dp = _module(stage, "decode_path_digest.py")
    release = stage / CATALOG / "native-mtp-admission-release.json"
    sidecar = stage / STATIC / "native-mtp-admission.json"
    if inputs["phase"] == "identity_only_greedy":
        # Relocatable bundle paths are materialized only for the existing strict
        # proof verifier. Cryptographically signed candidate bytes are unchanged.
        directory = bundle / "proof/candidate"
        plan = read_json(bundle / "proof/plan.json")
        marker = read_json(bundle / "proof/signed-byte-verification.json")
        plan["target"]["local_tarball_path"] = str(directory / f"macprovider-cli-v{inputs['candidate_version']}-darwin-arm64.tar.gz")
        marker["bytes_dir"] = str(directory)
        p, m = stage.parent / "plan.json", stage.parent / "marker.json"
        p.write_bytes(canonical(plan)); m.write_bytes(canonical(marker))
        require(plan.get("target", {}).get("source_commit") == inputs["identity"]["source_commit"], "candidate source mismatch")
        archive_path = Path(plan["target"]["local_tarball_path"])
        proof = dp.SignedPairPublishProof(p, m, bundle / "proof/run.json", bundle / "previous/native-mtp-admission.json")
        dp.publish_gate(release, sidecar, None, signed_pair=proof)
        # Only inspect archive content after the existing signed candidate
        # verifier authenticated its exact bytes. Bind actual bytes, not labels.
        with tarfile.open(archive_path) as archive:
            binaries = [x for x in archive.getmembers() if x.isfile() and PurePosixPath(x.name).name == "macprovider-cli"]
            libraries = [x for x in archive.getmembers() if x.isfile() and PurePosixPath(x.name).name == "mlx.metallib"]
            require(len(binaries) == 1 and len(libraries) == 1, "candidate archive binary/metallib ambiguous")
            binary = archive.extractfile(binaries[0]).read()
            library = archive.extractfile(libraries[0]).read()
        require(hashlib.sha256(binary).hexdigest() == inputs["identity"]["reproducible_build_sha256"] and hashlib.sha256(library).hexdigest() == inputs["identity"]["metallib_sha256"], "actual candidate binary/metallib mismatch")
        require(dp.MARKER.findall(binary) and set(dp.MARKER.findall(binary)) == {read_json(release)["provider_decode_path_digest"].encode()}, "candidate embedded decode-path mismatch")
    else:
        # The actual live recommendation is checked by the existing ops
        # publish gate using these verified paths. A bundle cannot attest it.
        version = dp.verify_release_input(read_json(release))
        require(version == inputs["candidate_version"] and dp._tag_commit(version) == inputs["identity"]["source_commit"], "expanded phase requires normal published source tag")
        serving = _module(stage, "native_mtp_signed_serving_proof.py")
        serving.verify_serving_proof(bundle / "proof/serving-journey",
            Path(os.environ["BINDING_REPO_INTERNAL"]), inputs["identity"]["source_commit"], sidecar)


@_closed_errors
def verify_bundle(bundle_dir: Path, *, repo: Path, commit: str, recipe_path: str) -> VerifiedBundle:
    bundle, repo = Path(bundle_dir).resolve(), Path(repo).resolve()
    require(not Path(bundle_dir).is_symlink(), "bundle symlink forbidden")
    recipe, recipe_sha = _recipe(repo, commit, recipe_path)
    manifest = read_json(bundle / "manifest.json")
    require(set(manifest) == {"schema_version", "source_commit", "recipe_path", "recipe_sha256", "phase", "files", "inputs_sha256", "predecessor_receipt_sha256"}, "bundle manifest fields")
    require(manifest["schema_version"] == "macprovider.native-mtp-binding-bundle.v1" and manifest["source_commit"] == commit and manifest["recipe_path"] == recipe_path and manifest["recipe_sha256"] == recipe_sha and manifest["phase"] in PHASES, "bundle recipe/source binding mismatch")
    files = inventory(bundle, exclude={"manifest.json", "manifest.json.sig"})
    require(manifest["files"] == files, "bundle inventory mismatch")
    require(set(inventory(bundle / "release")) == RELEASE_FILES and set(inventory(bundle / "previous")) == RELEASE_FILES, "bundle release/predecessor inventory must be the existing native-pair feed set")
    require(set(inventory(bundle / "derived")) == {"native-mtp-admission-release.json", "native-mtp-admission-tuple.json", "release-ledger.json"}, "derived input inventory")
    require(set(path.split("/")[0] for path in files) <= {"inputs.json", "release", "previous", "proof", "derived", "qualification", "parent"}, "unexpected bundle root member")
    inputs = read_json(bundle / "inputs.json")
    require(manifest["inputs_sha256"] == digest(bundle / "inputs.json") and manifest["phase"] == inputs.get("phase") and manifest["predecessor_receipt_sha256"] == inputs.get("parent_receipt_sha256"), "bundle inputs mismatch")
    with tempfile.TemporaryDirectory(prefix="native-binding-verify-") as scratch:
        stage = Path(scratch) / "source"
        _archive(repo, commit, stage)
        cr = _module(stage, "catalog-release.py")
        key_id, signature = cr.parse_sidecar((bundle / "manifest.json.sig").read_bytes(), "binding inventory")
        keys = cr.keyring(stage / CATALOG / "trusted-keys.json")
        require(key_id in keys, "bundle signer is not a reviewed active/bridge key")
        cr.verify_ed25519(keys[key_id], signature, (bundle / "manifest.json").read_bytes(), "binding inventory")
        old_repo = os.environ.get("BINDING_REPO_INTERNAL")
        os.environ["BINDING_REPO_INTERNAL"] = str(repo)
        try:
            _derive(bundle, repo=repo, commit=commit, recipe=recipe, stage=stage)
            derived = Path(scratch) / "release"
            _flat(stage, derived)
            require(inventory(derived) == inventory(bundle / "release"), "bundle release differs from deterministic generation")
            for filename in ("native-mtp-admission-release.json", "native-mtp-admission-tuple.json", "release-ledger.json"):
                require((stage / CATALOG / filename).read_bytes() == (bundle / "derived" / filename).read_bytes(), "bundle derived input/ledger differs from reconstruction")
            saved_env = dict(os.environ)
            try:
                os.environ.update(_environment(repo, commit, bundle / "previous"))
                os.environ["GIT_WORK_TREE"] = str(stage)
                _candidate_gate(stage, bundle, inputs)
            finally:
                os.environ.clear()
                os.environ.update(saved_env)
        finally:
            if old_repo is None: os.environ.pop("BINDING_REPO_INTERNAL", None)
            else: os.environ["BINDING_REPO_INTERNAL"] = old_repo
    receipt = {"schema_version": "macprovider.native-mtp-binding-receipt.v1", "source_commit": commit, "phase": manifest["phase"], "recipe_sha256": recipe_sha, "manifest_sha256": digest(bundle / "manifest.json"), "manifest_signature_sha256": digest(bundle / "manifest.json.sig"), "ledger_sha256": digest(bundle / "derived/release-ledger.json"), "release_input_sha256": digest(bundle / "derived/native-mtp-admission-release.json"), "predecessor_receipt_sha256": manifest["predecessor_receipt_sha256"]}
    receipt_sha = hashlib.sha256(canonical(receipt)).hexdigest()
    return VerifiedBundle(bundle / "release", bundle / "derived/release-ledger.json", bundle / "derived/native-mtp-admission-release.json", commit, manifest["phase"], recipe_sha, receipt_sha)


@_closed_errors
def derive_bundle(*, repo: Path, commit: str, recipe_path: str, inputs: Path, previous_release_dir: Path, proof_dir: Path | None, output: Path, qualification_dir: Path | None = None, parent_bundle: Path | None = None) -> dict:
    """Materialize signed feeds for the existing matched-pair plan to pin.

    DERIVED_UNSEALED is deliberately not an activation receipt. It resolves the
    plan/feed digest dependency without weakening the final proof verifier.
    """
    recipe, _ = _recipe(repo, commit, recipe_path)
    require(not output.exists(), "bundle output already exists")
    output.mkdir(parents=True)
    require(inputs.is_file() and not inputs.is_symlink(), "regular binding inputs required")
    shutil.copyfile(inputs, output / "inputs.json")
    _copy_tree(previous_release_dir, output / "previous")
    if proof_dir is not None: _copy_tree(proof_dir, output / "proof")
    else: (output / "proof").mkdir()
    if qualification_dir is not None: _copy_tree(qualification_dir, output / "qualification")
    if parent_bundle is not None: _copy_tree(parent_bundle, output / "parent")
    with tempfile.TemporaryDirectory(prefix="native-binding-build-") as scratch:
        stage = Path(scratch) / "source"
        old_repo = os.environ.get("BINDING_REPO_INTERNAL")
        os.environ["BINDING_REPO_INTERNAL"] = str(repo.resolve())
        try:
            _derive(output.resolve(), repo=repo.resolve(), commit=commit, recipe=recipe, stage=stage, sign=True)
        finally:
            if old_repo is None: os.environ.pop("BINDING_REPO_INTERNAL", None)
            else: os.environ["BINDING_REPO_INTERNAL"] = old_repo
        _flat(stage, output / "release")
        (output / "derived").mkdir()
        for name in ("native-mtp-admission-release.json", "native-mtp-admission-tuple.json", "release-ledger.json"):
            shutil.copyfile(stage / CATALOG / name, output / "derived" / name)
    return {"status": "DERIVED_UNSEALED", "release_dir": str((output / "release").resolve()), "release_input_path": str((output / "derived/native-mtp-admission-release.json").resolve()), "ledger_path": str((output / "derived/release-ledger.json").resolve()), "files": inventory(output)}


@_closed_errors
def seal_bundle(bundle: Path, *, repo: Path, commit: str, recipe_path: str) -> VerifiedBundle:
    recipe, recipe_sha = _recipe(repo, commit, recipe_path)
    require(not (bundle / "manifest.json").exists() and not (bundle / "manifest.json.sig").exists(), "sealed bundle is immutable; derive a new bundle")
    value = read_json(bundle / "inputs.json")
    manifest = {"schema_version": "macprovider.native-mtp-binding-bundle.v1", "source_commit": commit, "recipe_path": recipe_path, "recipe_sha256": recipe_sha, "phase": value["phase"], "inputs_sha256": digest(bundle / "inputs.json"), "predecessor_receipt_sha256": value["parent_receipt_sha256"], "files": inventory(bundle)}
    (bundle / "manifest.json").write_bytes(canonical(manifest))
    # Same CryptoKit raw Ed25519 and private-key store as the existing
    # resign-autotune-static.sh; keys never enter arguments, output or bundle.
    key = os.environ.get("AUTOTUNE_STATIC_PRIVATE_KEY_PATH", str(Path.home() / ".config/macprovider/keys/autotune-static-v4.private.base64"))
    require(Path(key).is_file() and not Path(key).is_symlink() and (Path(key).stat().st_mode & 0o777) in {0o400, 0o600}, "operator signing key permissions")
    env = dict(os.environ, KEY_FILE=key, INPUT_PATH=str((bundle / "manifest.json").resolve()))
    swift = 'import CryptoKit\nimport Foundation\nlet e=ProcessInfo.processInfo.environment\nlet k=try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: String(contentsOfFile:e["KEY_FILE"]!).trimmingCharacters(in:.whitespacesAndNewlines))!)\nprint(try k.signature(for:Data(contentsOf:URL(fileURLWithPath:e["INPUT_PATH"]!))).base64EncodedString())'
    signature = _run(["swift", "-e", swift], env=env).decode().strip()
    (bundle / "manifest.json.sig").write_bytes(canonical({"key_id": "streamvc-autotune-static-v4", "alg": "ed25519", "signature": signature}))
    return verify_bundle(bundle, repo=repo, commit=commit, recipe_path=recipe_path)


def build_bundle(**kwargs) -> VerifiedBundle:
    derive_bundle(**kwargs)
    return seal_bundle(kwargs["output"], repo=kwargs["repo"], commit=kwargs["commit"], recipe_path=kwargs["recipe_path"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for verb in ("verify", "derive", "seal", "build"):
        cmd = sub.add_parser(verb)
        cmd.add_argument("--repo", type=Path, required=True)
        cmd.add_argument("--commit", required=True)
        cmd.add_argument("--recipe", required=True)
        if verb in {"verify", "seal"}: cmd.add_argument("--bundle", type=Path, required=True)
        else:
            for flag in ("inputs", "previous-release-dir", "out"):
                cmd.add_argument("--" + flag, type=Path, required=True)
            cmd.add_argument("--proof-dir", type=Path, required=verb == "build")
            cmd.add_argument("--qualification-dir", type=Path)
            cmd.add_argument("--parent-bundle", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "verify":
            result = verify_bundle(args.bundle, repo=args.repo, commit=args.commit, recipe_path=args.recipe)
        elif args.command == "seal":
            result = seal_bundle(args.bundle, repo=args.repo, commit=args.commit, recipe_path=args.recipe)
        else:
            function = derive_bundle if args.command == "derive" else build_bundle
            result = function(repo=args.repo, commit=args.commit, recipe_path=args.recipe, inputs=args.inputs, previous_release_dir=args.previous_release_dir, proof_dir=args.proof_dir, output=args.out, qualification_dir=args.qualification_dir, parent_bundle=args.parent_bundle)
        print(json.dumps(asdict(result) if isinstance(result, VerifiedBundle) else result, default=str, sort_keys=True))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}, sort_keys=True))
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
