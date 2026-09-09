#!/usr/bin/env python3
"""Hermetic JOURNEY-PROVIDER-BYOM-DISCOVERY driver (#1453 slice 1).

Runs all ten normative steps of `journeys/JOURNEY-PROVIDER-BYOM-DISCOVERY.md`
against loopback stubs and an on-disk MLX-cache fixture, saves every CLI JSON
document it produced, and -- in `--evidence` mode only -- emits the
`macprovider.byom-journey-run.v1` run manifest that
`scripts/capture-byom-journey-evidence.py` consumes. A run without `--evidence`
may execute an arbitrary MACPROVIDER_CLI_BINARY against a dirty tree, so it
writes `run-summary.json` instead: local debugging output that no capture step
reads, which makes an unbound run non-promotable by construction.

Every observation in the manifest is set from this driver's own assertions, not
declared: the two negative observations are read off harness-owned ledgers (a
recording coordinator sink configured as the CLI's coordinator, and the adapter
stubs' own request logs). A failed assertion aborts the run, and the manifest is
published atomically only after every step and observation check has passed, so
a manifest only ever exists for a run where all ten steps passed.

Captured CLI documents are archived whole and validated against their complete
closed schemas -- a missing or unknown field fails the step. Nothing is stripped
before hashing, so the digest the signed evidence binds to covers the CLI's
complete closed envelope; the evidence contract's fail-closed scanner is
imported and run over every one of them, and over every command's real stdout
and stderr. The closed-schema validation itself lives in the shared capture
contract, so it covers hand-authored runs too, not only this driver's captures.

Nothing here signs or promotes anything, and nothing is written into the
repository: the captures and the manifest go to `--out`, which the operator
keeps locally. Only their digests reach the evidence artifact.
"""

import argparse
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


JOURNEY_ID = "JOURNEY-PROVIDER-BYOM-DISCOVERY"
RUN_MANIFEST_SCHEMA = "macprovider.byom-journey-run.v1"
HARNESS_NAME = "test/e2e/byom/run-discovery-journey.py"
ENVIRONMENT_CLASS = "hermetic-loopback"

MLX_MODEL_ID = "mlx-community/Tiny-1B-4bit"
MLX_SNAPSHOT_REVISION = "0123456789abcdef0123456789abcdef01234567"
OLLAMA_MODEL_NAME = "tiny-ollama-1b-q4"
OPAQUE_MODEL_ID = "opaque-mini-1b"
OPAQUE_SERVED_MODEL_REF = "openai_compatible:" + OPAQUE_MODEL_ID
# Local provider identity for the step-10 status readback. `models admission
# status` needs a provider id even when it never reaches a coordinator, because
# `model_admission_status.v1` carries one; it is local config, not a credential.
LADDER_PROVIDER_ID = "provider-byom-discovery-journey"
# SPEC-046-R003 `provider_guidance.next_action` enum, closed.
NEXT_ACTIONS = (
    "fix_local_blocker", "evaluate", "offer_dry_run", "submit_offer",
    "revise_and_reoffer", "check_status", "withdraw", "wait_for_coordinator",
    "maintain_runtime", "none",
)
# Distinctive so the step-08 scan can prove no completion text was ever echoed.
COMPLETION_MARKER = "byomprobecompletionmarker"

# Per-step SPEC-046 requirement subjects. These are the mapped requirement ids
# from scripts/check_spec_governance.py (PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS);
# capture re-validates them, so this table must not invent one.
STEP_REQUIREMENT_IDS = {
    "step-01-discover-mlx-cache": ["SPEC-046-R001", "SPEC-046-R002", "SPEC-046-R003"],
    "step-02-discover-loopback-runtime": ["SPEC-046-R001", "SPEC-046-R002", "SPEC-046-R003"],
    "step-03-discover-opaque-endpoint": ["SPEC-046-R002", "SPEC-046-R003", "SPEC-046-R004"],
    "step-04-reject-non-loopback": ["SPEC-046-R002", "SPEC-046-R007"],
    "step-05-handle-adapter-failure": ["SPEC-046-R002", "SPEC-046-R004"],
    "step-06-evaluate-candidate": ["SPEC-046-R001", "SPEC-046-R005"],
    "step-07-no-production-mutation": ["SPEC-046-R006"],
    "step-08-redaction-review": ["SPEC-046-R007"],
    "step-09-state-boundary": ["SPEC-046-R003"],
    "step-10-local-state-ladder": ["SPEC-046-R003", "SPEC-046-R008"],
}

TRUE_OBSERVATIONS = (
    "adapter_failure_warned",
    "candidate_evaluated",
    "local_state_ladder_verified",
    "loopback_runtime_discovered",
    "mlx_cache_discovered",
    "non_loopback_rejected",
    "opaque_endpoint_candidate_discovered",
    "redacted_artifacts_reviewed",
    "state_boundary_preserved",
)
FALSE_OBSERVATIONS = (
    "buyer_traffic_sent",
    "provider_credit_created",
    "raw_completion_logged",
    "raw_prompt_logged",
    "runtime_installed",
    "weights_downloaded",
)


class HarnessFailure(Exception):
    pass


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "scripts"))
import byom_journey_evidence as evidence_contract  # noqa: E402


# --- Closed capture schemas (R2 MEDIUM, moved to the contract in R3) --------
#
# Capture checks that a document is JSON, names the expected schema id, and is
# redaction-clean. None of that proves the document is COMPLETE: a CLI that
# stopped emitting `capabilities`, or emitted a mutation summary with one field
# in it, would still pass. The signed evidence binds a digest of these
# documents, so an incomplete one is a false conformance claim.
#
# The closed key sets and the validator now live in `byom_journey_evidence.py`
# and run inside `_digest_document`, so they cover every capture that reaches
# evidence -- this driver's and the hand-authored physical/admission runs' alike
# (R3 MEDIUM). This driver keeps calling them at capture time so a bad document
# fails the step that produced it instead of the pipeline three commands later.


def assert_exact_object(value, expected_keys, where):
    """Contract's exact-key check, reported as a step failure.

    Steps 03 and 07 assert over one closed object each (the SPEC-046-R004
    capability object, the SPEC-046-R005 mutation summary), so they use the same
    key sets the capture contract enforces rather than a second copy.
    """
    try:
        evidence_contract.assert_exact_object(value, expected_keys, where)
    except evidence_contract.BYOMEvidenceError as exc:
        raise HarnessFailure(str(exc))


def validate_captured_document(name, document):
    """Validate one captured CLI document against its complete closed schema."""
    try:
        evidence_contract.validate_captured_cli_document(document.get("schema"), document, name)
    except evidence_contract.BYOMEvidenceError as exc:
        raise HarnessFailure(str(exc))


# Paths whose contents decide what an evidence run actually executed. In
# `--evidence` mode every one of them must be clean -- tracked AND untracked --
# both before and after the CLI is built, before `source_sha` may be recorded
# against the run (R1 F5, R2 HIGH). SwiftPM's executable target selects the
# whole `Sources/macprovider-cli` directory with no closed source list, so an
# untracked `.swift` file there is a build input; ignoring untracked files would
# let the manifest name a commit that did not produce the binary.
EVIDENCE_SOURCE_PATHS = (
    "phase3-binary/Sources",
    "phase3-binary/Tests",
    "phase3-binary/Package.swift",
    "phase3-binary/Package.resolved",
    "scripts",
    "test/e2e/byom",
)

# The one tracked file an earlier CI step is expected to have rewritten. The
# `swift test` step that runs before this gate resolves the package graph under
# the runner's default toolchain, which writes a different (still valid)
# `Package.resolved` than the committed one. That drift says nothing about what
# this run executes, and HEAD's lockfile is already proven consistent by the
# separate `phase3-binary (locked SwiftPM resolve)` CI job. Everything else in
# EVIDENCE_SOURCE_PATHS still fails closed, and the build below is locked to
# this lockfile so it cannot rewrite it again.
#
# Restoring it is NOT unconditional (R3 MEDIUM): outside an ephemeral CI
# checkout, a differing lockfile is the operator's own uncommitted work, and
# `git checkout HEAD --` would destroy it with nothing to restore from. The rule
# is in `restore_locked_package_resolved`.
EVIDENCE_RESTORED_LOCKFILE = "phase3-binary/Package.resolved"

# An ephemeral CI checkout is the only place a differing lockfile may be thrown
# away: the checkout is created for the job and discarded with it, so nothing
# uncommitted there can be work anyone wanted to keep. GitHub Actions sets both;
# either alone is enough for other CI systems.
CI_ENVIRONMENT_FLAGS = ("GITHUB_ACTIONS", "CI")
CI_ENVIRONMENT_TRUE_VALUES = frozenset({"true", "1"})

# Same lock the `phase3-binary (locked SwiftPM resolve)` CI job applies through
# xcodebuild's `-onlyUsePackageVersionsFromResolvedFile`
# (scripts/verify-swift-package-lock.sh): resolution may only use the versions
# in Package.resolved and fails if that file is out of date. Without it the
# build itself can rewrite the lockfile after the pre-build cleanliness check
# and publish evidence against a tree it has already changed.
SWIFT_LOCKED_RESOLUTION_FLAG = "--only-use-versions-from-resolved-file"


def assert_true(condition, message):
    if not condition:
        raise HarnessFailure(message)


def repo_root():
    return pathlib.Path(__file__).resolve().parents[3]


def in_ephemeral_ci_checkout(environ=None):
    """True when this process runs in a throwaway CI checkout."""
    environ = os.environ if environ is None else environ
    return any(
        environ.get(name, "").strip().lower() in CI_ENVIRONMENT_TRUE_VALUES
        for name in CI_ENVIRONMENT_FLAGS
    )


def restore_locked_package_resolved(root, environ=None):
    """Reconcile `Package.resolved` with HEAD before the cleanliness check.

    Three cases, and only one of them writes:

    * The working-tree lockfile already equals HEAD -- nothing to do.
    * It differs, this is an ephemeral CI checkout, and nothing is staged for
      it: the difference is the earlier `swift test` step's resolution under the
      runner's default toolchain, so HEAD's bytes are restored with a notice.
      HEAD's lockfile is separately proven by the `phase3-binary (locked SwiftPM
      resolve)` job, and the build below is locked to it.
    * Anything else -- a local run, or a CI run with the lockfile staged -- is
      someone's uncommitted work. `git checkout HEAD --` would destroy it with
      no copy anywhere, so the run REFUSES and says what to do instead (R3
      MEDIUM).
    """
    lockfile = root / EVIDENCE_RESTORED_LOCKFILE
    if not lockfile.exists():
        return
    committed = subprocess.run(
        ["git", "show", "HEAD:" + EVIDENCE_RESTORED_LOCKFILE],
        cwd=str(root),
        capture_output=True,
        check=True,
    ).stdout
    if lockfile.read_bytes() == committed:
        return
    staged = subprocess.run(
        ["git", "diff", "--cached", "--quiet", "--", EVIDENCE_RESTORED_LOCKFILE],
        cwd=str(root),
        capture_output=True,
    ).returncode != 0
    assert_true(
        in_ephemeral_ci_checkout(environ) and not staged,
        "evidence mode will not discard your uncommitted %s. Commit it, or "
        "restore it with `git checkout HEAD -- %s`, then re-run. (This run is "
        "not an ephemeral CI checkout%s.)"
        % (
            EVIDENCE_RESTORED_LOCKFILE,
            EVIDENCE_RESTORED_LOCKFILE,
            " and the lockfile is staged" if staged else "",
        ),
    )
    print(
        "evidence mode: restoring HEAD's %s in this ephemeral CI checkout; the "
        "difference is an earlier step's package resolution, and HEAD's "
        "lockfile is proven by the locked SwiftPM resolve job"
        % EVIDENCE_RESTORED_LOCKFILE
    )
    subprocess.run(
        ["git", "checkout", "HEAD", "--", EVIDENCE_RESTORED_LOCKFILE],
        cwd=str(root),
        check=True,
    )


def require_clean_evidence_source(root, phase):
    """Refuse to record `source_sha` for a tree that is not what ran (F5, R2).

    Tracked AND untracked files count: SwiftPM builds every `.swift` file under
    the executable's source directory, so an untracked one is as much a build
    input as a modified tracked one. Anything reported fails closed.

    `phase` names when the check ran ("before the build" / "after the build");
    the post-build call is what catches a build that mutated its own inputs.
    """
    completed = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all", "--"]
        + list(EVIDENCE_SOURCE_PATHS),
        cwd=str(root),
        capture_output=True,
        text=True,
        check=True,
    )
    dirty = sorted(line[3:] for line in completed.stdout.splitlines() if line.strip())
    assert_true(
        not dirty,
        "evidence mode needs a clean source tree %s; dirty: %s"
        % (phase, ", ".join(dirty)),
    )


def build_cli(root, explicit_binary, evidence_mode):
    # An evidence run is attributed to a commit, so it must execute that commit:
    # an arbitrary prebuilt binary would let the manifest claim a source it never
    # ran. Local non-evidence runs keep the override for iteration speed.
    if evidence_mode:
        assert_true(
            not explicit_binary,
            "MACPROVIDER_CLI_BINARY is refused in --evidence mode: evidence must "
            "execute the binary built from the recorded source",
        )
        restore_locked_package_resolved(root)
        require_clean_evidence_source(root, "before the build")
        explicit_binary = None
    if explicit_binary:
        path = pathlib.Path(explicit_binary).expanduser().resolve()
        assert_true(path.exists(), "MACPROVIDER_CLI_BINARY does not exist: " + str(path))
        return path
    command = ["swift", "build", "--product", "macprovider-cli"]
    if evidence_mode:
        command.append(SWIFT_LOCKED_RESOLUTION_FLAG)
    subprocess.run(command, cwd=str(root / "phase3-binary"), check=True)
    path = root / "phase3-binary" / ".build" / "debug" / "macprovider-cli"
    assert_true(path.exists(), "swift build did not produce " + str(path))
    if evidence_mode:
        # The build is an input mutation risk of its own: a resolution or a
        # generated file landing under the executable's source directory would
        # make the binary something other than what the pre-build check saw.
        require_clean_evidence_source(root, "after the build")
    return path


class ConnectionRecordingHTTPServer(ThreadingHTTPServer):
    """Counts accepted connections, not just parsed requests.

    A request that never becomes valid HTTP -- a TLS handshake against a plain
    socket, a half-open probe -- still contacted the port, and for the
    coordinator sink that is exactly what must never happen.
    """

    def verify_request(self, request, client_address):
        self.state["connections"] += 1
        return True


class LocalHTTPServer:
    def __init__(self, handler_class, state, server_class=ThreadingHTTPServer):
        state.setdefault("connections", 0)
        self.state = state
        self.httpd = server_class(("127.0.0.1", 0), handler_class)
        self.httpd.state = state
        self.started = False
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        self.ready.set()
        self.httpd.serve_forever()

    @property
    def port(self):
        return self.httpd.server_address[1]

    @property
    def origin(self):
        host, port = self.httpd.server_address
        return "http://%s:%d" % (host, port)

    def start(self):
        if self.started:
            return
        self.thread.start()
        self.ready.wait(timeout=5)
        self.started = True

    def stop(self):
        if self.started:
            self.httpd.shutdown()
            self.thread.join(timeout=5)
            self.started = False
        self.httpd.server_close()


class JSONHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_json(self, payload, raw=None):
        if raw is None:
            encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        else:
            encoded = raw.encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class OllamaHandler(JSONHandler):
    def do_GET(self):
        self.server.state["paths"].append(self.path)
        if self.path != "/api/tags":
            self.send_error(404)
            return
        self.send_json({
            "models": [{
                "name": OLLAMA_MODEL_NAME,
                "details": {"family": "llama", "quantization_level": "Q4_0"},
            }],
        })


class OpenAICompatibleHandler(JSONHandler):
    def do_GET(self):
        self.server.state["paths"].append(self.path)
        if self.path != "/v1/models":
            self.send_error(404)
            return
        self.send_json({"object": "list", "data": [{"id": OPAQUE_MODEL_ID, "object": "model"}]})

    def do_POST(self):
        self.server.state["paths"].append(self.path)
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        self.server.state["chat_bodies"].append(body.decode("utf-8", errors="replace"))
        self.send_json({
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": COMPLETION_MARKER},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 11, "completion_tokens": 2, "total_tokens": 13},
        })


class MalformedOpenAIHandler(JSONHandler):
    """Answers `/v1/models` with well-formed JSON of the wrong shape.

    Deterministic where a closed-port probe would race the port allocator, and it
    exercises the same closed `adapter_malformed_response` code path.
    """

    def do_GET(self):
        self.server.state["paths"].append(self.path)
        self.send_json(None, raw='{"object":"list","data":"not-an-array"}')


class CoordinatorSinkHandler(BaseHTTPRequestHandler):
    """Records every request it receives and serves nothing.

    This is the harness-owned ledger behind the two negative observations
    (F4). It is configured as the CLI's coordinator for the whole run, so
    `buyer_traffic_sent` and `provider_credit_created` are read off an empty
    ledger rather than declared: discovery, evaluation, and the offer dry run
    are local-only commands and must never reach a coordinator. It answers 503
    so that a leaked request is recorded and then fails, never satisfied by a
    fabricated document.
    """

    def log_message(self, *_args):
        pass

    def _record(self):
        self.server.state["requests"].append("%s %s" % (self.command, self.path))
        self.send_error(503)

    do_GET = _record
    do_HEAD = _record
    do_POST = _record
    do_PUT = _record
    do_PATCH = _record
    do_DELETE = _record


def create_mlx_cache_fixture(cache_root):
    """HuggingFace cache layout the MLX adapter recognizes: a `models--<org>--<name>`
    repo directory holding `snapshots/<rev>/` with a config and a weights file."""
    snapshot = (
        cache_root
        / ("models--" + MLX_MODEL_ID.replace("/", "--"))
        / "snapshots"
        / MLX_SNAPSHOT_REVISION
    )
    snapshot.mkdir(parents=True)
    (snapshot / "config.json").write_text(
        json.dumps({"max_position_embeddings": 4096}), encoding="utf-8"
    )
    (snapshot / "model.safetensors").write_bytes(b"\x7a" * 4096)


def directory_digest(root):
    """Content digest over every regular file under `root`, so step-07 can prove
    the cache and the local salt were not mutated."""
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(root)).encode("utf-8"))
        digest.update(b"\x00")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


class Runner:
    def __init__(self, cli, env, cwd):
        self.cli = cli
        self.env = env
        self.cwd = cwd
        self.transcript = []

    def run_text(self, args, env=None, defer_hostname_scan=False):
        """Run one CLI command and return its stdout, scanned.

        EVERY command goes through here, including ones whose output is not JSON
        (`--version`), so the step-08 claim that the scan covers every command's
        real stdout and stderr is true rather than nearly true. Both streams also
        enter `transcript`, which the step-08 review re-scans for this run's
        origins, paths, prompt, and completion marker.

        By default stdout gets the FULL plaintext scan, hostname rule included.
        `defer_hostname_scan` is set only by `run()`, whose stdout is a JSON
        document carrying the SPEC-046-R003 localization keys -- DNS-shaped by
        coincidence -- and which immediately runs the structured document scan
        that decides those keys field by field. Plain-text output such as
        `--version` has no such follow-up, so it may not skip the rule (R3 LOW).
        """
        label = " ".join(args[:3])
        completed = subprocess.run(
            [str(self.cli)] + args,
            cwd=str(self.cwd),
            env=self.env if env is None else env,
            text=True,
            capture_output=True,
        )
        self.transcript.append(completed.stdout)
        self.transcript.append(completed.stderr)
        if completed.returncode != 0:
            raise HarnessFailure(
                "CLI failed (%d): %s" % (completed.returncode, label)
            )
        # Step 08's real scan (F2), run here so it covers every command's actual
        # output rather than only the documents that end up captured, and so an
        # unexpected forbidden-shaped value fails the run even though it is not
        # in the run-specific `forbidden` list. The scanner functions are the
        # evidence contract's own, imported rather than reimplemented.
        stdout_scan = (
            evidence_contract.reject_unredacted_text_except_hostname
            if defer_hostname_scan
            else evidence_contract.reject_unredacted_text
        )
        try:
            stdout_scan(completed.stdout, "cli stdout for " + label)
            evidence_contract.reject_unredacted_text(
                completed.stderr, "cli stderr for " + label
            )
        except evidence_contract.BYOMEvidenceError as exc:
            raise HarnessFailure("CLI output for %s is not redaction-clean: %s" % (label, exc))
        return completed.stdout

    def run(self, args, env=None):
        """Run one CLI command that emits a JSON document. `env` overrides the
        runner's environment for a command that must see a different one -- step
        10 runs `models admission status` with no coordinator configured at
        all."""
        label = " ".join(args[:3])
        stdout = self.run_text(args, env=env, defer_hostname_scan=True)
        try:
            document = json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise HarnessFailure("invalid JSON stdout for %s: %s" % (label, exc))
        try:
            evidence_contract.assert_captured_document_redacted(
                document, "cli stdout for " + label
            )
        except evidence_contract.BYOMEvidenceError as exc:
            raise HarnessFailure("CLI output for %s is not redaction-clean: %s" % (label, exc))
        return document


def candidate_by_runtime_source(document, runtime_source):
    for candidate in document.get("candidates", []):
        if candidate.get("runtime_source") == runtime_source:
            return candidate
    raise HarnessFailure("no %s candidate in discovery output" % runtime_source)


def adapter_by_runtime_source(document, runtime_source):
    for adapter in document.get("adapters", []):
        if adapter.get("runtime_source") == runtime_source:
            return adapter
    raise HarnessFailure("no %s adapter in discovery output" % runtime_source)


class ManifestBuilder:
    """Collects per-step verdicts and captured documents, then emits the manifest.

    `assertion` strings are short prose and must stay free of URLs, absolute
    paths, hostnames and IP literals: capture's redaction scan runs over them.
    """

    def __init__(self, out_dir, run_id, cli_version, evidence_mode=False):
        self.out_dir = out_dir
        self.captures = out_dir / "captures"
        self.captures.mkdir(parents=True, mode=0o700, exist_ok=True)
        # POSIX ignores `mode` for a directory that already exists, so say it
        # outright: captures are operator-local inventory documents and the
        # directory holding them stays user-private on a shared host (F7).
        self.captures.chmod(0o700)
        self.run_id = run_id
        self.cli_version = cli_version
        self.evidence_mode = evidence_mode
        self.steps = []
        self.observations = {name: None for name in TRUE_OBSERVATIONS + FALSE_OBSERVATIONS}

    def capture(self, name, document):
        """Write one captured CLI document WHOLE, re-scanned fail-closed.

        Nothing is stripped: the digest the signed evidence binds to has to
        cover the CLI's complete closed envelope, including the SPEC-046-R003
        `provider_guidance` localization keys. The document is first validated
        against that complete closed schema -- a missing or unknown field fails
        the step, so redaction-clean but incomplete captures cannot support
        evidence (R2). The scan is the capture tool's
        own, imported rather than reimplemented, so this driver can never emit a
        manifest whose documents capture would reject -- same field-scoped rule,
        same fail-closed outcome.
        """
        payload = json.dumps(document, indent=2, sort_keys=True) + "\n"
        try:
            evidence_contract.assert_captured_document_redacted(
                document, "captured document " + name
            )
            evidence_contract.reject_unredacted_text_except_hostname(
                payload, "captured document " + name
            )
        except evidence_contract.BYOMEvidenceError as exc:
            raise HarnessFailure("captured document %s is not redaction-clean: %s" % (name, exc))
        validate_captured_document("captured document " + name, document)
        path = self.captures / (name + ".json")
        path.write_text(payload, encoding="utf-8")
        # Created 0600 rather than umask-dependent: the document is
        # redaction-clean, but it is still this operator's local model
        # inventory, and a permissive default would publish it to every account
        # on the host (F7).
        path.chmod(0o600)
        return path

    def add_step(self, step_id, assertion, documents):
        assert_true(step_id in STEP_REQUIREMENT_IDS, "unknown step id: " + step_id)
        self.steps.append({
            "id": step_id,
            "status": "pass",
            "assertion": assertion,
            "requirement_ids": list(STEP_REQUIREMENT_IDS[step_id]),
            "documents": documents,
        })

    def document(self, document_id, schema, capture_name):
        return {
            "id": document_id,
            "schema": schema,
            "path": "captures/" + capture_name + ".json",
        }

    def observe(self, name, value):
        assert_true(name in self.observations, "unknown observation: " + name)
        self.observations[name] = value

    def write(self):
        missing = sorted(name for name, value in self.observations.items() if value is None)
        assert_true(not missing, "observations never set by a check: " + ", ".join(missing))
        for name in TRUE_OBSERVATIONS:
            assert_true(self.observations[name] is True, "observation must be true: " + name)
        for name in FALSE_OBSERVATIONS:
            assert_true(self.observations[name] is False, "observation must be false: " + name)
        ordered = sorted(STEP_REQUIREMENT_IDS)
        assert_true(
            [step["id"] for step in self.steps] == ordered,
            "manifest steps must cover every journey step exactly once",
        )
        manifest = {
            "schema_version": RUN_MANIFEST_SCHEMA,
            "journey_id": JOURNEY_ID,
            "run_id": self.run_id,
            "environment_class": ENVIRONMENT_CLASS,
            "cli_version": self.cli_version,
            "harness": {"name": HARNESS_NAME, "status": "pass"},
            "steps": self.steps,
            "observations": {name: self.observations[name] for name in sorted(self.observations)},
        }
        # Published atomically and only here, after every step and observation
        # check has passed: a consumer must never be able to read a half-written
        # manifest, and a failed run must leave none at all (F7).
        #
        # Only an `--evidence` run publishes `run-manifest.json`. A local
        # debugging run -- which may execute an arbitrary MACPROVIDER_CLI_BINARY
        # against a dirty tree -- writes the same content as `run-summary.json`,
        # a name the capture tool does not consume. Non-promotable by
        # construction rather than by operator discipline (R2 HIGH): there is no
        # sequence of local commands that produces a capturable manifest without
        # the source binding.
        name = "run-manifest.json" if self.evidence_mode else "run-summary.json"
        path = self.out_dir / name
        temporary = self.out_dir / ("." + name + ".tmp")
        temporary.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(str(temporary), str(path))
        return path


def prepare_out_dir(out_dir):
    """`--out` must be new or empty, and is created user-private (F7).

    Reusing a directory that already holds a manifest is refused rather than
    cleaned: a failed rerun into last week's passing output would otherwise
    leave that stale pass manifest sitting there, consumable, while the run that
    actually just happened failed. Operator data is never deleted here.
    """
    existed = out_dir.exists()
    if existed:
        assert_true(out_dir.is_dir(), "--out must be a directory: " + str(out_dir))
        assert_true(
            not any(out_dir.iterdir()),
            "--out must be a new or empty directory; refusing to reuse one that may "
            "hold a stale run manifest",
        )
    out_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    if existed:
        # POSIX applies `mode` only when mkdir actually creates the directory, so
        # an operator's pre-existing world-readable `--out` would have stayed
        # world-readable and published every capture written into it. The
        # directory is empty, so narrowing it destroys nothing.
        out_dir.chmod(0o700)
    return out_dir


def redaction_review(transcript, capture_dir, forbidden):
    """Step-08: no origin, port, local path, prompt or completion text anywhere in
    the CLI's stdout, stderr, or the captured JSON documents.

    `forbidden` is a list of `(category, value)` pairs. The failure names the
    category and the pair's index and NOTHING ELSE: the forbidden set is exactly
    the origins, absolute paths, probe prompt, and completion marker this step
    exists to keep out of the operator's terminal, and the top-level handler
    prints the raised exception to stderr. Echoing even a prefix of the leaked
    value would make the detector break the invariant it detects (R4 LOW). The
    category and index are enough to identify which needle matched.
    """
    haystacks = list(transcript)
    for path in sorted(capture_dir.glob("*.json")):
        haystacks.append(path.read_text(encoding="utf-8"))
    for index, (category, needle) in enumerate(forbidden):
        if not needle:
            continue
        for haystack in haystacks:
            if needle in haystack:
                raise HarnessFailure(
                    "redaction review found leaked material of category %s (forbidden "
                    "entry %d); the value is withheld from this diagnostic by design"
                    % (category, index)
                )
    return True


def main():
    parser = argparse.ArgumentParser(description="Run the hermetic BYOM discovery journey.")
    parser.add_argument("--out", required=True, help="Directory for captures/ and run-manifest.json.")
    parser.add_argument("--keep-temp", action="store_true", help="Keep the temporary harness directory.")
    parser.add_argument(
        "--evidence",
        action="store_true",
        help="Evidence mode: refuse MACPROVIDER_CLI_BINARY, require a clean source "
             "tree (tracked and untracked) before and after a lock-resolved build of "
             "the CLI, and publish run-manifest.json. Without it the run writes only "
             "run-summary.json, which the capture tool does not consume.",
    )
    args = parser.parse_args()

    root = repo_root()
    out_dir = pathlib.Path(args.out).expanduser().resolve()
    temp_root = pathlib.Path(tempfile.mkdtemp(prefix="macprovider-byom-discovery-"))
    ollama = LocalHTTPServer(OllamaHandler, {"paths": []})
    openai = LocalHTTPServer(OpenAICompatibleHandler, {"paths": [], "chat_bodies": []})
    broken = LocalHTTPServer(MalformedOpenAIHandler, {"paths": []})
    # Configured as the CLI's coordinator for the whole run and expected to stay
    # untouched; its ledger is what the two negative observations are read from.
    coordinator = LocalHTTPServer(
        CoordinatorSinkHandler, {"requests": []}, server_class=ConnectionRecordingHTTPServer
    )
    # No buyer gateway is started at any point in this journey. The harness owns
    # the complete list of servers it runs, so this is a checkable fact rather
    # than an assumption, and step 06 re-checks that the only chat request in the
    # run is the evaluation's single local probe.
    started_servers = {
        "ollama_adapter_stub": ollama,
        "openai_compatible_adapter_stub": openai,
        "malformed_adapter_stub": broken,
        "coordinator_sink": coordinator,
    }
    try:
        prepare_out_dir(out_dir)
        cli = build_cli(root, os.environ.get("MACPROVIDER_CLI_BINARY"), args.evidence)
        ollama.start()
        openai.start()
        broken.start()
        coordinator.start()

        home = temp_root / "home"
        home.mkdir(mode=0o700)
        # `models discover` is read-only by SPEC-046-R001 and will not provision
        # the salt itself, so seed it: without it every candidate id is
        # byom_unstable_* and the state ladder collapses to local_only.
        namespace = temp_root / "local-discovery.namespace"
        namespace.write_bytes(secrets.token_bytes(32))
        namespace.chmod(0o600)
        hf_cache = temp_root / "hf-cache"
        create_mlx_cache_fixture(hf_cache)

        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            # The MLX fixture would report does_not_fit on a small CI runner and
            # block the ladder this journey exercises; the fit logic still runs.
            "MACPROVIDER_BYOM_E2E_DETECTED_RAM_GB": "64",
            # A coordinator IS configured for every command in this run, and it
            # is the recording sink. `buyer_traffic_sent` and
            # `provider_credit_created` are then read off its ledger: a command
            # that tried to reach a coordinator would land here and be recorded.
            "MACPROVIDER_COORDINATOR_URL": coordinator.origin,
        })
        for stale in ("MACPROVIDER_CONFIG", "HF_HOME", "HF_HUB_CACHE"):
            env.pop(stale, None)

        local_args = [
            "--local-discovery-namespace-path", str(namespace),
            "--mlx-cache-dir", str(hf_cache),
        ]
        runner = Runner(cli, env, root)
        cli_version = runner.run_text(["--version"]).strip()
        run_id = "byom-discovery-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        manifest = ManifestBuilder(out_dir, run_id, cli_version, evidence_mode=args.evidence)

        cache_digest_before = directory_digest(hf_cache)
        namespace_before = namespace.read_bytes()
        home_digest_before = directory_digest(home)

        # Step 01 - MLX-cache discovery.
        mlx_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama"] + local_args
        )
        assert_true(mlx_document.get("schema") == "provider_byom_discovery.v1", "wrong discovery schema")
        mlx_candidate = candidate_by_runtime_source(mlx_document, "mlx_cache")
        assert_true(mlx_candidate.get("served_model_ref") == MLX_MODEL_ID, "mlx served ref changed")
        assert_true(mlx_candidate.get("locality") == "local_artifact", "mlx locality changed")
        assert_true(mlx_candidate.get("readiness_state") == "ready", "mlx fixture not ready")
        assert_true(
            mlx_candidate.get("candidate_id", "").startswith("byom_")
            and not mlx_candidate["candidate_id"].startswith("byom_unstable_"),
            "mlx candidate id is not namespace-stable",
        )
        assert_true(
            mlx_candidate.get("admission_state_source") == "local_default",
            "mlx candidate claimed coordinator authority",
        )
        manifest.capture("discover-mlx-cache", mlx_document)
        manifest.add_step(
            "step-01-discover-mlx-cache",
            "MLX-cache candidate discovered read-only with a stable namespace-scoped candidate id.",
            [manifest.document("discover-mlx-cache", "provider_byom_discovery.v1", "discover-mlx-cache")],
        )
        manifest.observe("mlx_cache_discovered", True)

        # Step 02 - loopback runtime discovery.
        ollama_document = runner.run(
            ["models", "discover", "--json", "--ollama-origin", ollama.origin] + local_args
        )
        ollama_candidate = candidate_by_runtime_source(ollama_document, "ollama_loopback")
        assert_true(
            ollama_candidate.get("served_model_ref") == "ollama:" + OLLAMA_MODEL_NAME,
            "ollama served ref changed",
        )
        assert_true(ollama_candidate.get("locality") == "loopback_runtime", "ollama locality changed")
        assert_true(
            adapter_by_runtime_source(ollama_document, "ollama_loopback").get("status") == "ok",
            "ollama adapter did not report ok",
        )
        assert_true(ollama.state["paths"] == ["/api/tags"], "ollama adapter probed an unexpected path")
        manifest.capture("discover-loopback-runtime", ollama_document)
        manifest.add_step(
            "step-02-discover-loopback-runtime",
            "Loopback Ollama adapter enumerated one candidate without leaving the host.",
            [manifest.document(
                "discover-loopback-runtime", "provider_byom_discovery.v1", "discover-loopback-runtime"
            )],
        )
        manifest.observe("loopback_runtime_discovered", True)

        # Step 03 - opaque OpenAI-compatible endpoint.
        opaque_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--openai-compatible-origin", openai.origin] + local_args
        )
        opaque_candidate = candidate_by_runtime_source(opaque_document, "openai_compatible_loopback")
        opaque_candidate_id = opaque_candidate["candidate_id"]
        assert_true(
            opaque_candidate.get("served_model_ref") == OPAQUE_SERVED_MODEL_REF,
            "opaque served ref changed",
        )
        assert_true(
            opaque_candidate.get("identity_state") == "opaque_endpoint",
            "opaque candidate did not report an opaque identity",
        )
        assert_true(
            opaque_candidate.get("locality") == "opaque_local_endpoint",
            "opaque candidate did not report an opaque locality",
        )
        assert_true(opaque_candidate.get("catalog_model_key") is None, "opaque candidate claimed a catalog key")
        assert_true(
            opaque_candidate.get("admission_state") in ("local_only", "not_offered"),
            "opaque candidate left the non-earning local states",
        )
        assert_true(
            opaque_candidate.get("admission_state_source") == "local_default",
            "opaque candidate claimed coordinator authority",
        )
        # The exact SPEC-046-R004 capability object, every value null. An
        # absent or partial object would otherwise make "no asserted
        # capability" vacuously true (R2).
        capabilities = opaque_candidate.get("capabilities")
        assert_exact_object(
            capabilities, evidence_contract.CAPABILITY_KEYS,
            "opaque candidate capabilities",
        )
        assert_true(
            all(value is None for value in capabilities.values()),
            "opaque candidate asserted an unevaluated capability",
        )
        assert_true(
            (opaque_candidate.get("provider_guidance") or {}).get("earning_path_class")
            == "local_inventory_only",
            "opaque candidate claimed an earning path",
        )
        assert_true(openai.state["paths"] == ["/v1/models"], "opaque adapter probed an unexpected path")
        manifest.capture("discover-opaque-endpoint", opaque_document)
        manifest.add_step(
            "step-03-discover-opaque-endpoint",
            "Opaque OpenAI-compatible candidate reported identity_state opaque_endpoint, "
            "null capabilities, and a non-earning local state.",
            [manifest.document(
                "discover-opaque-endpoint", "provider_byom_discovery.v1", "discover-opaque-endpoint"
            )],
        )
        manifest.observe("opaque_endpoint_candidate_discovered", True)

        # Step 04 - non-loopback origin rejected before dispatch. The wildcard
        # address resolves to this host, so a leaked request would reach the stub
        # and the request-count assertion would fail.
        openai_paths_before = list(openai.state["paths"])
        rejected_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--openai-compatible-origin", "http://0.0.0.0:%d" % openai.port] + local_args
        )
        rejected_adapter = adapter_by_runtime_source(rejected_document, "openai_compatible_loopback")
        assert_true(rejected_adapter.get("status") == "rejected", "non-loopback origin was not rejected")
        assert_true(
            rejected_adapter.get("warning_codes") == ["adapter_rejected_non_loopback"],
            "rejection did not use the closed warning code",
        )
        assert_true(
            not any(c.get("runtime_source") == "openai_compatible_loopback"
                    for c in rejected_document.get("candidates", [])),
            "rejected adapter fabricated a candidate",
        )
        assert_true(
            openai.state["paths"] == openai_paths_before,
            "a request left the host for a non-loopback origin",
        )
        manifest.capture("discover-non-loopback-rejected", rejected_document)
        manifest.add_step(
            "step-04-reject-non-loopback",
            "Non-loopback adapter origin rejected before any request was issued, "
            "and the endpoint never appeared in the projection.",
            [manifest.document(
                "discover-non-loopback-rejected",
                "provider_byom_discovery.v1",
                "discover-non-loopback-rejected",
            )],
        )
        manifest.observe("non_loopback_rejected", True)

        # Step 05 - adapter failure is a warning, not a trust claim.
        failure_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--openai-compatible-origin", broken.origin] + local_args
        )
        failure_adapter = adapter_by_runtime_source(failure_document, "openai_compatible_loopback")
        assert_true(failure_adapter.get("status") == "malformed", "malformed adapter was not reported")
        assert_true(
            failure_adapter.get("warning_codes") == ["adapter_malformed_response"],
            "adapter failure did not use the closed warning code",
        )
        assert_true(
            "adapter_malformed_response" in (failure_document.get("warnings") or []),
            "adapter failure was not surfaced in the top-level warnings",
        )
        assert_true(
            not any(c.get("runtime_source") == "openai_compatible_loopback"
                    for c in failure_document.get("candidates", [])),
            "malformed adapter fabricated a candidate",
        )
        manifest.capture("discover-adapter-failure", failure_document)
        manifest.add_step(
            "step-05-handle-adapter-failure",
            "Malformed adapter response surfaced as a closed warning code, not a trust claim.",
            [manifest.document(
                "discover-adapter-failure", "provider_byom_discovery.v1", "discover-adapter-failure"
            )],
        )
        manifest.observe("adapter_failure_warned", True)

        # Step 06 - bounded local evaluation of the opaque candidate.
        evaluation = runner.run(
            ["models", "evaluate", opaque_candidate_id, "--json", "--skip-ollama",
             "--openai-compatible-origin", openai.origin] + local_args
        )
        assert_true(evaluation.get("schema") == "provider_byom_evaluation.v1", "wrong evaluation schema")
        assert_true(evaluation.get("candidate_id") == opaque_candidate_id, "evaluation resolved another candidate")
        assert_true(
            evaluation.get("runtime_source") == "openai_compatible_loopback",
            "evaluation changed the runtime source",
        )
        assert_true(evaluation.get("health_result") == "passed", "evaluation did not pass")
        assert_true(evaluation.get("request_count") == 1, "evaluation exceeded its request budget")
        assert_true(
            evaluation.get("usage_reporting_source") == "runtime_reported",
            "evaluation lost the usage-reporting source",
        )
        assert_true(
            evaluation.get("offer_preconditions_appear_satisfied") is False,
            "an opaque endpoint claimed satisfied offer preconditions",
        )
        assert_true(len(openai.state["chat_bodies"]) == 1, "evaluation sent more than one probe")
        manifest.capture("evaluate-candidate", evaluation)
        manifest.add_step(
            "step-06-evaluate-candidate",
            "models evaluate ran the bounded local harness against the opaque endpoint "
            "and reported health_result passed with one request.",
            [manifest.document("evaluate-candidate", "provider_byom_evaluation.v1", "evaluate-candidate")],
        )
        manifest.observe("candidate_evaluated", True)

        # Step 07 - no production mutation. The mutation summary is the CLI's own
        # claim; the fixture digests are the independent check on it.
        # The exact SPEC-046-R005 mutation-summary field set, every value
        # false. Any nonempty subset used to satisfy this; a document that had
        # dropped a mutation field would have passed (R2).
        mutations = evaluation.get("mutation_summary")
        assert_exact_object(
            mutations, evidence_contract.EVALUATION_MUTATION_SUMMARY_KEYS,
            "evaluation mutation_summary",
        )
        assert_true(
            all(value is False for value in mutations.values()),
            "evaluation claimed a mutation: %s" % sorted(k for k, v in mutations.items() if v),
        )
        assert_true(directory_digest(hf_cache) == cache_digest_before, "the model cache was mutated")
        assert_true(namespace.read_bytes() == namespace_before, "the discovery namespace was rewritten")
        assert_true(directory_digest(home) == home_digest_before, "provider config under home was mutated")
        manifest.add_step(
            "step-07-no-production-mutation",
            "mutation_summary reported no config, cache, weight, or coordinator mutation, "
            "and the fixture digests were unchanged after the run.",
            [manifest.document(
                "evaluate-mutation-summary", "provider_byom_evaluation.v1", "evaluate-candidate"
            )],
        )
        manifest.observe("weights_downloaded", False)
        manifest.observe("runtime_installed", False)

        # Step 09 runs before 08 so its output is inside the redaction review.
        dry_run = runner.run(
            ["models", "offer", opaque_candidate_id, "--dry-run", "--json", "--skip-ollama",
             "--openai-compatible-origin", openai.origin] + local_args
        )
        assert_true(
            dry_run.get("schema") == "model_admission_offer_dry_run.v1", "wrong dry-run schema"
        )
        assert_true(dry_run.get("candidate_id") == opaque_candidate_id, "dry-run resolved another candidate")
        assert_true(dry_run.get("would_submit") is False, "an opaque endpoint predicted a submittable offer")
        assert_true(dry_run.get("catalog_model_key") is None, "dry-run invented a catalog key")
        assert_true(
            dry_run.get("likely_admission_state") in ("local_only", "not_offered"),
            "dry-run promoted the local admission state",
        )
        assert_true(
            dry_run.get("likely_admission_state_source") == "local_default",
            "dry-run claimed coordinator authority",
        )
        dry_run_guidance = dry_run.get("provider_guidance") or {}
        assert_true(
            dry_run_guidance.get("earning_path_class") == "local_inventory_only",
            "dry-run claimed an earning path",
        )
        assert_true(
            dry_run_guidance.get("state_meaning_key")
            != "byom.offer_dry_run.catalog_path_missing_trusted_binding",
            "dry-run claimed a catalog path for an opaque endpoint",
        )
        manifest.capture("offer-dry-run", dry_run)

        # Step 10 - the local state ladder, before step 08 for the same reason.
        ladder_document = runner.run(
            ["models", "discover", "--json",
             "--ollama-origin", ollama.origin,
             "--openai-compatible-origin", openai.origin] + local_args
        )
        ladder_states = {
            candidate["runtime_source"]: candidate for candidate in ladder_document.get("candidates", [])
        }
        offerable = [c for c in ladder_document.get("candidates", []) if c.get("admission_state") == "offerable"]
        local_only = [c for c in ladder_document.get("candidates", []) if c.get("admission_state") == "local_only"]
        assert_true(offerable, "no offerable candidate in the ladder projection")
        assert_true(local_only, "no local_only candidate in the ladder projection")
        assert_true(
            "openai_compatible_loopback" in ladder_states
            and ladder_states["openai_compatible_loopback"].get("admission_state") == "local_only",
            "the opaque candidate left local_only in the ladder projection",
        )
        for candidate in offerable + local_only:
            guidance = candidate.get("provider_guidance") or {}
            assert_true(
                guidance.get("next_action") in NEXT_ACTIONS,
                "a ladder candidate reported no closed next action",
            )
            assert_true(
                candidate.get("admission_state_source") == "local_default",
                "a ladder candidate claimed coordinator authority",
            )
        for candidate in local_only:
            assert_true(
                (candidate.get("provider_guidance") or {}).get("transition_reason_code"),
                "a local_only candidate reported no local transition reason",
            )
        for candidate in offerable:
            # SPEC-046-R003 makes `transition_reason_code` nullable and the
            # `offerable` ladder row has no reason to carry: nothing has moved the
            # candidate and nothing is blocking it. The field must still be
            # reported rather than omitted, and it must not carry an invented code.
            guidance = candidate.get("provider_guidance") or {}
            assert_true(
                "transition_reason_code" in guidance,
                "an offerable candidate omitted the local transition reason field",
            )
            assert_true(
                guidance.get("transition_reason_code") is None,
                "an offerable candidate reported a transition reason with no blocker",
            )
        manifest.capture("discover-state-ladder", ladder_document)

        # local-default `not_offered` is the third ladder row: the candidate is
        # locally eligible, but no coordinator offer state is known because no
        # coordinator has been queried. Run the status readback with NO
        # coordinator configured, so the CLI must answer from local inventory and
        # the coordinator sink ledger stays empty (F4).
        # A harness-owned config with a provider id and no `coordinator_url`.
        # `models admission status` is the one journey command that reads the
        # config file, and config-path expansion resolves `~` from the account
        # rather than from `HOME`, so an operator's real config would otherwise
        # supply this run's provider id and coordinator.
        harness_config = temp_root / "harness-config.yaml"
        harness_config.write_text("provider_id: %s\n" % LADDER_PROVIDER_ID, encoding="utf-8")
        harness_config.chmod(0o600)
        ladder_status_env = dict(env)
        ladder_status_env.pop("MACPROVIDER_COORDINATOR_URL", None)
        coordinator_requests_before = len(coordinator.state["requests"])
        coordinator_connections_before = coordinator.state["connections"]
        status_document = runner.run(
            ["models", "admission", "status", MLX_MODEL_ID, "--json", "--skip-ollama",
             "--config", str(harness_config),
             "--provider-id", LADDER_PROVIDER_ID] + local_args,
            env=ladder_status_env,
        )
        assert_true(
            status_document.get("schema") == "model_admission_status.v1",
            "wrong admission status schema",
        )
        assert_true(
            status_document.get("admission_state_source") == "local_default",
            "the unqueried-coordinator readback claimed coordinator authority",
        )
        assert_true(
            status_document.get("admission_state") == "not_offered",
            "the unqueried-coordinator readback did not report not_offered",
        )
        assert_true(
            status_document.get("coordinator_event_id") is None
            and status_document.get("state_observed_at") is None,
            "a local-default readback carried coordinator event material",
        )
        assert_true(
            status_document.get("allowed_next_states") == [],
            "a local-default readback offered coordinator next states",
        )
        status_guidance = status_document.get("provider_guidance") or {}
        assert_true(
            status_guidance.get("next_action") in NEXT_ACTIONS,
            "the not_offered row reported no closed next action",
        )
        assert_true(
            status_guidance.get("transition_reason_code") == "coordinator_state_unavailable",
            "the not_offered row reported no local transition reason",
        )
        assert_true(
            status_guidance.get("earning_path_class") == "local_inventory_only",
            "the not_offered row claimed an earning path",
        )
        assert_true(
            "coordinator_state_unavailable" in (status_document.get("warnings") or []),
            "the not_offered row did not disclose why coordinator state is absent",
        )
        assert_true(
            len(coordinator.state["requests"]) == coordinator_requests_before
            and coordinator.state["connections"] == coordinator_connections_before,
            "the unconfigured-coordinator readback reached a coordinator",
        )
        manifest.capture("admission-status-state-ladder", status_document)

        # A missing namespace is the other route into local_only: the candidate id
        # is unstable, so the CLI must refuse to treat the candidate as offerable.
        unstable_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--local-discovery-namespace-path", str(temp_root / "absent.namespace"),
             "--mlx-cache-dir", str(hf_cache)]
        )
        unstable_candidate = candidate_by_runtime_source(unstable_document, "mlx_cache")
        assert_true(
            unstable_candidate.get("admission_state") == "local_only",
            "an unstable candidate was reported offerable",
        )
        assert_true(
            "candidate_id_unstable" in (unstable_candidate.get("warning_codes") or []),
            "an unstable candidate lost its transition reason",
        )
        assert_true(
            not (temp_root / "absent.namespace").exists(),
            "discovery provisioned the namespace it was told to read",
        )
        manifest.capture("discover-state-ladder-unstable", unstable_document)

        # The catalog-economics projection reports the same coordinator-unqueried
        # label for catalog rows that have no local candidate at all, and gates
        # settlement and catalog economics closed on it. Discovery itself still
        # reports only local_only and offerable; the status readback above is the
        # surface that reports `not_offered` with guidance.
        economics = runner.run(
            ["models", "catalog-economics", "--json", "--skip-coordinator-status", "--skip-ollama"]
            + local_args
        )
        assert_true(
            economics.get("schema") == "model_catalog_economics.v1", "wrong catalog economics schema"
        )
        not_offered = [
            row for row in economics.get("rows", [])
            if (row.get("admission") or {}).get("state") == "not_offered"
            and (row.get("admission") or {}).get("source") == "local_default"
        ]
        assert_true(not_offered, "no local-default not_offered row in the economics projection")
        for row in not_offered:
            admission = row.get("admission") or {}
            assert_true(admission.get("settlement_capable") is False, "a not_offered row claimed settlement")
            assert_true(
                admission.get("catalog_economics_permitted") is False,
                "a not_offered row permitted catalog economics",
            )
        manifest.capture("catalog-economics-state-ladder", economics)

        manifest.add_step(
            "step-09-state-boundary",
            "Evaluated candidate stayed non-routable and non-earning with no coordinator state "
            "and no catalog earning path.",
            [manifest.document(
                "offer-dry-run-state-boundary", "model_admission_offer_dry_run.v1", "offer-dry-run"
            )],
        )
        manifest.observe("state_boundary_preserved", True)
        manifest.add_step(
            "step-10-local-state-ladder",
            "local_only, offerable, and local-default not_offered each reported a closed next "
            "action; local_only and not_offered each reported a non-null local transition reason, "
            "and offerable reported the nullable reason field with no blocker to name.",
            [
                manifest.document(
                    "discover-state-ladder", "provider_byom_discovery.v1", "discover-state-ladder"
                ),
                manifest.document(
                    "admission-status-state-ladder",
                    "model_admission_status.v1",
                    "admission-status-state-ladder",
                ),
                manifest.document(
                    "discover-state-ladder-unstable",
                    "provider_byom_discovery.v1",
                    "discover-state-ladder-unstable",
                ),
                manifest.document(
                    "catalog-economics-state-ladder",
                    "model_catalog_economics.v1",
                    "catalog-economics-state-ladder",
                ),
            ],
        )
        manifest.observe("local_state_ladder_verified", True)

        # Step 08 - redaction review over every command's output and every capture.
        probe_prompt = json.loads(openai.state["chat_bodies"][0])["messages"][0]["content"]
        # `(category, value)` pairs: a match reports only the category and the
        # entry's index, never the value itself.
        forbidden = [
            ("adapter_origin", ollama.origin),
            ("adapter_origin", openai.origin),
            ("adapter_origin", broken.origin),
            ("coordinator_origin", coordinator.origin),
            # host:port rather than a bare port: a bare 5-digit number would
            # collide with digests and byte counts and make this scan flaky.
            ("loopback_host_port", "127.0.0.1:%d" % ollama.port),
            ("loopback_host_port", "127.0.0.1:%d" % openai.port),
            ("loopback_host_port", "127.0.0.1:%d" % broken.port),
            ("loopback_host_port", "127.0.0.1:%d" % coordinator.port),
            ("local_path", str(temp_root)),
            ("local_path", str(home)),
            ("local_path", str(namespace)),
            ("local_path", str(hf_cache)),
            ("probe_prompt", probe_prompt),
            ("completion_marker", COMPLETION_MARKER),
        ]
        assert_true(
            redaction_review(runner.transcript, manifest.captures, forbidden),
            "redaction review failed",
        )
        manifest.add_step(
            "step-08-redaction-review",
            "JSON and stderr carried no prompt, completion, credential, endpoint, or local path material.",
            [manifest.document(
                "discover-redaction-review", "provider_byom_discovery.v1", "discover-opaque-endpoint"
            )],
        )
        manifest.observe("redacted_artifacts_reviewed", True)
        manifest.observe("raw_prompt_logged", False)
        manifest.observe("raw_completion_logged", False)

        # The two negative observations, read off harness-owned ledgers at the
        # end of the run rather than declared (F4).
        #
        # No buyer gateway exists in this journey. The harness owns the complete
        # list of servers it started, so that is a checked fact, and the only
        # chat request anywhere in the run is the evaluation's single local probe
        # to the adapter stub.
        assert_true(
            not any("buyer" in name or "gateway" in name for name in started_servers),
            "the harness started a buyer gateway; buyer traffic is out of scope here",
        )
        chat_requests = {
            name: [path for path in server.state.get("paths", []) if "completions" in path]
            for name, server in started_servers.items()
        }
        assert_true(
            chat_requests["openai_compatible_adapter_stub"] == ["/v1/chat/completions"],
            "the evaluation probe was not the only chat request to the adapter stub",
        )
        assert_true(
            not any(paths for name, paths in chat_requests.items()
                    if name != "openai_compatible_adapter_stub"),
            "a chat request reached a stub other than the evaluated endpoint",
        )
        manifest.observe("buyer_traffic_sent", False)

        # Provider credit is coordinator-side state. Every command in this run
        # had the sink configured as its coordinator, and every one of them is a
        # local-only command, so the sink must have been contacted zero times --
        # not one request, not even one accepted connection.
        assert_true(
            coordinator.state["requests"] == [],
            "a request reached the coordinator sink: %s"
            % ", ".join(coordinator.state["requests"][:3]),
        )
        assert_true(
            coordinator.state["connections"] == 0,
            "a connection reached the coordinator sink; local-only commands must not "
            "contact a coordinator",
        )
        manifest.observe("provider_credit_created", False)

        manifest.steps.sort(key=lambda step: step["id"])
        manifest_path = manifest.write()
        print("BYOM discovery journey passed")
        print("run_id=%s cli_version=%s steps=%d" % (run_id, cli_version, len(manifest.steps)))
        if args.evidence:
            print("manifest=%s" % manifest_path)
        else:
            print("summary=%s (not evidence: no run manifest was published)" % manifest_path)
        return 0
    except Exception as exc:
        print("BYOM discovery journey failed: %s" % exc, file=sys.stderr)
        if args.keep_temp:
            print("temp_root=%s" % temp_root, file=sys.stderr)
        return 1
    finally:
        for server in (ollama, openai, broken, coordinator):
            try:
                server.stop()
            except Exception:
                pass
        if args.keep_temp:
            print("kept temp_root=%s" % temp_root)
        else:
            shutil.rmtree(str(temp_root), ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
