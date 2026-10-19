#!/usr/bin/env bash
# Real app-core acceptance on the designated Studio's isolated provider only.
# The caller owns the provider and must obtain the exclusive acceptance window.
set -euo pipefail
umask 077

fail() { printf '{"result":"fail","reason":"%s"}\n' "$1" >&2; exit 1; }
[[ -n "${MACPROVIDER_TEST_STUDIO_HOST:-}" ]] || fail required_studio_host_missing
[[ "${MACPROVIDER_CHAT_ACCEPTANCE_READY:-}" == "1" ]] || fail exclusive_window_not_confirmed
[[ "$(uname -s)" == "Darwin" ]] || fail wrong_os
[[ "$(/bin/hostname)" == "$MACPROVIDER_TEST_STUDIO_HOST" ]] || fail wrong_host
[[ "$(sysctl -n hw.model)" == "Mac15,14" ]] || fail wrong_hardware
[[ "${MACPROVIDER_CHAT_ACCEPTANCE_PROVIDER_PID:-}" =~ ^[1-9][0-9]*$ ]] || fail provider_pid_missing
provider_args="$(ps -p "$MACPROVIDER_CHAT_ACCEPTANCE_PROVIDER_PID" -o command=)"
[[ "$provider_args" == *" serve "* && "$provider_args" == *" --no-join "* && "$provider_args" == *" --port 18055 "* ]] || fail provider_not_isolated
listener_pid="$(lsof -nP -t -iTCP:18055 -sTCP:LISTEN | sort -u)"
[[ "$listener_pid" == "$MACPROVIDER_CHAT_ACCEPTANCE_PROVIDER_PID" ]] || fail provider_listener_mismatch

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
acceptance_dir="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-chat-core.XXXXXX")"
trap 'rm -rf "$acceptance_dir"' EXIT

# The scanner's error type lives in the UI model-management source. Compile its
# exact declaration, not a hand-authored stub or a modified scanner. Anchors are
# intentionally strict so a source move/change requires reviewing this harness.
python3 - "$repo_root" "$acceptance_dir" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

root, work = map(pathlib.Path, sys.argv[1:])
relative_sources = [
    "phase3-binary/app/Sources/Malibu/Chat/ChatTransport.swift",
    "phase3-binary/app/Sources/Malibu/Chat/ChatStore.swift",
    "phase3-binary/app/Sources/Malibu/Chat/AgentTools.swift",
    "phase3-binary/app/Sources/Malibu/ModelManagement/MalibuJSONDuplicateKeyScanner.swift",
    "scripts/tests/LocalChatAppCoreAcceptance.swift",
]
model_path = "phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift"
model_source = (root / model_path).read_text()
start_anchor = "enum ModelManagementError: LocalizedError {\n"
end_anchor = "\n}\n\nenum MalibuAccessibility {"
if model_source.count(start_anchor) != 1 or model_source.count(end_anchor) != 1:
    print(json.dumps({"result": "fail", "reason": "error_declaration_boundaries_changed"}))
    sys.exit(1)
start = model_source.index(start_anchor)
end = model_source.index(end_anchor, start) + len("\n}")
declaration = model_source[start:end]
if declaration.count("\n    case ") != 2:
    print(json.dumps({"result": "fail", "reason": "error_declaration_contract_changed"}))
    sys.exit(1)
extracted = work / "ModelManagementError.swift"
extracted.write_text("import Foundation\n\n" + declaration + "\n")
provenance = {
    "source_sha256": {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
                      for path in [*relative_sources, model_path]},
    "extraction": {"path": model_path,
                   "first_line": model_source[:start].count("\n") + 1,
                   "last_line": model_source[:end].count("\n") + 1,
                   "sha256": hashlib.sha256(declaration.encode()).hexdigest()},
}
command = ["xcrun", "swiftc", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
           *[str(root / path) for path in relative_sources], str(extracted), "-o", str(work / "chat-core")]
try:
    compiled = subprocess.run(command, capture_output=True, timeout=90)
    if compiled.returncode:
        # Compiler diagnostics are source-controlled text, but keep normal
        # acceptance output to metadata, just like model/file-content output.
        provenance.update(result="fail", reason="compile_failed", returncode=compiled.returncode,
                          diagnostics_sha256=hashlib.sha256(compiled.stderr).hexdigest())
        print(json.dumps(provenance, sort_keys=True))
        sys.exit(1)
    result = subprocess.run([str(work / "chat-core")], capture_output=True, timeout=240)
    try:
        acceptance = json.loads(result.stdout)
    except (UnicodeError, ValueError):
        acceptance = {"result": "fail", "reason": "invalid_harness_report"}
    provenance.update(acceptance=acceptance, returncode=result.returncode)
    print(json.dumps(provenance, sort_keys=True))
    sys.exit(0 if result.returncode == 0 and acceptance.get("result") == "pass" else 1)
except subprocess.TimeoutExpired:
    provenance.update(result="fail", reason="process_timeout")
    print(json.dumps(provenance, sort_keys=True))
    sys.exit(1)
PY
