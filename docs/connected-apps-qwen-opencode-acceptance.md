# Qwen automatic tool use in OpenCode

Related: #2054

## Result

The two qualified Qwen artifacts did **not** complete automatic tool use in
OpenCode 1.17.9 with provider CLI 1.8.260. Do not advertise these models as
verified OpenCode file-reading or editing agents. Malibu's Connected apps
setup already includes this limitation.

| Model | Observed response | Automatic read |
| --- | --- | --- |
| Qwen3-Coder-30B-A3B-Instruct-4bit | Repeated fabricated file-error text | Failed |
| Qwen3-30B-A3B-Instruct-2507-4bit | Fabricated marker-file contents | Failed |

These are observed failures, not a claim that every possible prompt fails.
Required or named tool-call qualification remains valid, but does not prove
that a model will select a tool in automatic mode.

## Reproduction and evidence boundary

On 2026-10-21, the real OpenCode executable ran its stock agent against the
gateway router fixture and an isolated, non-joining signed provider. Each run
used the exact catalog artifact, a 16,384-token context, a 1,024-token output
budget, ten offered tools, and unchanged `tool_choice: auto` requests. The task
was to read a fresh random marker file and return its exact contents. A guessed
answer cannot pass that check.

The tools-enabled response finished with `stop`, no wire `tool_calls`, and no
executed read or matching tool-result continuation in either run. Coder emitted
673 completion tokens; Instruct emitted 14. Both acceptance tests failed.
The isolated provider processes were removed and the incumbent service was
unchanged. This is real-client/model evidence through the local gateway router,
**not** production routing, billing, receipt, or settlement acceptance.

The bounded private trace contains the request and post-parser response, not
the rendered token prompt or raw generation. Source inspection and existing
required/named qualification support a model-choice limitation; they do not
absolutely exclude every possible internal rendering discrepancy. No malformed
tool-call envelope or parser rejection was observed. Converting invented file
errors into tool calls, forcing a named tool, or adding a mandatory-call prefix
would not establish automatic tool support.

## Reusable acceptance tooling

The acceptance fixture and `scripts/ops/qwen-opencode-e2e.sh` preserve a strict
positive gate: completed read, matching continuation, exact random answer,
and, for the live command, verified settlement and incumbent restoration.
Negative model evidence must never be marked as a successful gate.
The live command remains useful for explicitly requested future confirmation;
its presence does not activate automatic-tool support or claim a live pass.

Users should check actual tool activity before relying on file access or edits.
An ordinary answer, even one formatted like a tool result, is not evidence that
the client read a file.
