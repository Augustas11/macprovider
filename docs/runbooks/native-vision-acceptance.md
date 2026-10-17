# Native image-input acceptance

Issue #2016 implements `qwen2vl-inline-v1` for
`mlx-community/Qwen2-VL-2B-Instruct-4bit` at revision
`01af461cdb9574acc09084a0ef94e216e142b085`, using MLXVLM from pinned
`mlx-swift-lm` revision `dbe8bcb39a00e31b8ba9a0602c60d9388fca247d`.
Source compatibility is not hardware qualification. No prior native image
qualification was found; existing VLM-origin evidence exercises text serving.
The new decode path is `NativeVisionProfile.userInput` →
`Qwen2VLProcessor.prepare` → the serial `ModelRuntime` iterator, and the loader
changes from `LLMModelFactory` to `VLMModelFactory` for this exact artifact. Keep this checklist open
until its observations exist; a merged PR or passing parser test does not
establish image inference or live buyer acceptance.

## Contract

Chat Completions supports ordered text and inline PNG/JPEG images on this
exact native profile, including image-only user messages. The limits are two
images per request, 1 MiB of decoded file bytes per image, 2 MiB aggregate,
2048 pixels per axis, and 4,194,304 aggregate decoded pixels. Base64 must be
canonical and padded. Axes below 28 pixels are expanded to 28 before the
processor. The processor budget is 401,408 pixels per image. Image generation
uses unquantized KV and a fixed 512-token prefill step.
Remote URLs, animated images, audio and video are unsupported. Responses and
Messages retain explicit media rejection. Media requests do not use text-only
caches, continuous batching or speculative decoding.

SPEC-015 canonicalization binds the original ordered image data URLs and
detail fields. No remote image is fetched. Qualification must bind the exact
artifact, processor, template, tokenizer, runtime and provider configuration.
Receipt verification must use the original request, including image parts.

## Isolated hardware checks

Run hardware acceptance only on the designated Mac Studio after verifying its
identity. Follow [the lab campaign loop](lab-campaign-loop.md). Do not run this
campaign on an operator laptop. Do not replace a live provider, use its port,
or join an unreleased candidate to the live coordinator.

1. Check existing evidence and record the changed decode/processor lines that
   require new image inference observations. Reuse valid text-serving evidence.
2. Build the campaign candidate on the designated Studio. Start it on a free
   loopback port other than 8080 with `--no-join --autotune-candidate`, the exact
   artifact, and existing scheduler/resource controls. Confirm its running
   executable and identity. Run the native processor tests from this PR.
3. Run the HTTP harness below from that Studio. It verifies the host family,
   exact expected hostname, binary digest, process arguments and listening PID
   before sending inference requests. Supply the expected hostname from
   established operator records, not by accepting an arbitrary current host.
   Keep credentials in environment variables; never put them on the command
   line or in evidence. `VISION_PROVIDER_TOKEN` and `VISION_BUYER_TOKEN` are
   optional authenticated-path tokens.

   ```bash
   python3 scripts/vision-acceptance.py \
     --provider-url http://127.0.0.1:18016 \
     --expected-host-name "$DESIGNATED_STUDIO_HOSTNAME" \
     --candidate-pid "$CANDIDATE_PID" \
     --candidate-binary "$CANDIDATE_BINARY" \
     --candidate-sha256 "$CANDIDATE_SHA256" \
     --source-commit "$CANDIDATE_SOURCE_COMMIT" \
     --unsupported-model "$LOADED_TEXT_ONLY_MODEL" \
     --output "$PRIVATE_EVIDENCE_DIRECTORY/native-vision-http.json"
   ```

   The harness generates tiny red/blue PNGs in memory, uses the same question
   for both, and checks color-dependent answers in streaming and non-streaming
   modes. It also checks image-only input, reversed multiple-image ordering,
   mixed content, malformed/excessive media, endpoint/model rejection,
   disconnect and repeated-request recovery. Results contain no images,
   prompts, answers, tokens or host identifiers. Source commit is explicitly
   an operator assertion; the binary digest and process checks are measured.
   A failure returns nonzero and never becomes a qualification.
4. Run the same checks through an isolated local coordinator/gateway stack.
   For this run, start the candidate with `--isolate-lifecycle
   --credential-store protected_file --coordinator ws://127.0.0.1:<port>/<path>`
   instead of `--no-join --autotune-candidate`. Supply the harness's
   `--gateway-url http://127.0.0.1:<gateway-port> --local-stack-isolated
   --coordinator-url ws://127.0.0.1:<port>/<path>` arguments. The harness checks
   that the candidate's explicit coordinator argument exactly matches this
   numeric loopback target, which overrides config/environment selection.
   Ensure that stack routes to isolated test providers only, with no
   production credentials or coordinator target. The harness deliberately
   supports no public endpoint or live mode.
5. Independently verify that removing qualified image capacity produces an
   explicit refusal and never selects text-only capacity. Verify that the
   exact image content reaches the provider and receipt hash verification
   succeeds against the original request. Check actual processor prompt-token
   accounting, billing/refunds and privacy behavior for supported requests;
   unsupported combinations must fail explicitly.
6. Measure resource use during repeated requests, cancellation and disconnect.
   Verify scheduler slots, GPU allocations and retained image buffers recover.
   Run model replacement with in-flight work through existing replacement
   infrastructure, then prove that old capability/processor identities cannot
   remain attached to the new model. The HTTP harness does not prove memory
   bounds, replacement safety or cancellation propagation timing.

## Post-merge release and live checklist

Hardware acceptance may remain pending when the Studio is unreachable. Record
the pending items without claiming qualification or live acceptance.

- [ ] Native processor paired-image tests pass on the designated Studio.
- [ ] Provider-local and isolated buyer streaming/non-streaming HTTP checks pass.
- [ ] Resource, replacement, negative capacity-routing and receipt gates pass.
- [ ] A separately loaded text-only model rejects mixed/image-only requests
  before inference; the harness model-name mismatch check alone is insufficient.
- [ ] Existing tool-selection and text-only regressions remain green in CI.
- [ ] Independent code, security and architecture audits satisfy repository gates.
- [ ] Reviewed candidate release and any catalog/runtime changes use only
  `scripts/ops/` entry points: `status`, then `next`, then the documented step.
  Read the [Pearl rollout runbook](pearl-coordinator-rollout.md) and state
  expected downtime before any live coordinator change.
- [ ] Explicitly authorized reviewed/released candidate serves both paired
  images through the actual buyer gateway, with image-dependent answers.
- [ ] Live receipt, accounting, routing and settlement observations pass.

Local loopback observations do not establish Malibu live buyer routing,
receipt settlement, release acceptance or qualification. Do not close #2016
because unsupported media rejects or because this harness passes in isolation.

## Qualification deployment record

After Studio acceptance, install one operator-reviewed
`routing.vision_qualifications` entry on Pearl. It contains exact `provider_id`, `binary_version`, `hardware_chip`, `ram_gb`, `max_context_tokens`,
`max_concurrency`, `model_id`, `model_hash`, `model_hash_algorithm`,
`weights_manifest_sha256`, `processor_digest`, `runtime`, `runtime_revision`,
`media_profile`, and `qualification_digest` (SHA-256 of the reviewed acceptance
record). Use the captured values, not placeholders or hashes synthesized from
a model label. Preserve ordinary catalog admission and pricing requirements;
this entry grants no model, trust-tier or settlement admission on its own.
An absent/mismatched entry leaves buyer media explicitly unavailable. A new
binary or provider configuration needs a matching reviewed record; reuse
unchanged qualification observations and rebind release identity under the
existing release rules rather than rerunning unchanged text benchmarks.

The record names a provider, and this repository is public: keep it in a
private file outside the repository, mode 0600, as a JSON (or YAML) mapping
with exactly those 15 fields. Install it only through the ops entry point:

```bash
export VISION_QUALIFICATION_FILE=<private file>
PEARL_RUNTIME_TASK=vision-qualification scripts/ops/pearl-runtime.sh status
PEARL_RUNTIME_TASK=vision-qualification scripts/ops/pearl-runtime.sh next
MACPROVIDER_OPS_OWNER=<session-label> PEARL_RUNTIME_TASK=vision-qualification \
  VISION_QUALIFICATION_FILE=<private file> scripts/ops/pearl-runtime.sh next --run
```

Expected downtime: one coordinator restart, about 5–40 seconds. The
coordinator reads the qualification list at boot only; SIGHUP validates it
but does not apply it. If the post-restart check fails, the tooling restores
the overlay and restarts the coordinator once more.

`status` checks the record locally with the coordinator's rules (exact fields,
positive integers, lowercase SHA-256 hex for `model_hash`,
`weights_manifest_sha256`, `processor_digest` and `qualification_digest`, the
`mlx-community/Qwen2-VL-2B-Instruct-4bit` / `mlx_cache` / `qwen2vl-inline-v1`
tuple and the `macprovider.snapshot-manifest.v1` hash algorithm). It prints
field names and the entry's SHA-256 only, never the values. `next --run`
prints the downtime, takes the live-ops lock, stages the canonical record
root-only next to the overlay and runs
`scripts/ops/lib/pearl-cli-config.py apply-vision-qualification` under both
Pearl locks. That helper sets `routing.vision_qualifications` to exactly
`[record]` in `/etc/macprovider/coordinator.pearl-overlays.yaml` (never the
base `coordinator.yaml`), after a backup under `/root/macprovider-backups`. An
existing `routing:` mapping in the overlay keeps its keys; the entry is
inserted into it. The helper refuses a different existing list, a flow-style
or non-mapping `routing`, and any edit that changes more than that key. It
validates with the running coordinator binary (`--validate-config`),
replaces the overlay atomically, restarts once and requires the new process
to log the on-disk files as its boot config.

The task is done when the overlay holds exactly this entry and the running
coordinator booted with it. Run again with the same record, it does nothing.
If the overlay already holds the entry but the coordinator has not booted with
it, it validates and restarts once. To replace a recorded entry, reconcile the
overlay first; the task never overwrites a different list.

Provider-local support is enabled when the exact artifact loads. The wire
capability asserts implementation identity only. No source catalog or public
model list in this PR claims measured vision qualification. The post-merge
catalog/runtime activation and live buyer checks must be completed before
claiming the feature serves released production traffic.
