# Guarded offline Studio jobs

This entry point reserves one bounded offline window for the four-native-row
GLM campaign or the fixed Qwen3.6 A3B requalification campaign. It does not install a lab binary, connect one to the live
coordinator, or change a catalog policy. Completing a job is not, by itself,
release qualification or buyer-path acceptance.

The operator must have handed back the Studio before the window starts.
Use the existing campaign handoff and evidence; a new build is not a reason
to repeat qualification. The campaign must identify the changed decode or
scheduling code that motivates its diagnostic.

## Preparation

Build the campaign source on the designated Studio, at reduced priority,
without changing the signed provider installation. Prepare:

- A tracked-clean source clone at the exact campaign commit.
- The release-mode CLI with `MACPROVIDER_LAB_HARNESS` enabled, at
  `phase3-binary/.build/release/macprovider-cli`.
- For GLM diagnostic and qualification jobs, the release-mode `GLMBench` with testing enabled, at
  `scripts/lab/cb-studio/glm53-bench/.build/release/GLMBench`.
- The matching `mlx.metallib` beside each binary.
- `.lab-window/fixture/target`, an isolated clone of the previously verified
  model snapshot. The GLM target embeds its MTP layer. Qwen requires its
  separate drafter snapshot in `.lab-window/fixture/mtp`, as described below. Do not download or replace live model files during
  the window.

Keep source, build provenance, diagnostic outputs, and operational journals
private. Record model and source identities in the campaign's acceptance
evidence. Component profiling cannot substitute for scheduler or buyer-path
acceptance.

Configure the existing private Studio connection, install/config/journal,
launch label, control socket and status-port settings used by the owner-pin
controller. Also set:

| Setting | Meaning |
| --- | --- |
| `STUDIO_LAB_SOURCE_DIR` | Absolute path to the campaign clone on the Studio |
| `STUDIO_LAB_GIT_HEAD` | Exact 40-character campaign commit |
| `STUDIO_LAB_WINDOW_DIR` | Dedicated private directory for this window's journal and staged helpers |
| `STUDIO_LAB_JOB_KIND` | Closed job kind: `diagnostic-legacy` (default), `profiler-only`, `qualification`, `qwen-qualification`, `qwen-journey`, or `glm-prefill` |

The command and its arguments are fixed in
`scripts/lab/2080-native-rows/run-window-diagnostic.sh`. There is no shell
command setting. Do not change it to `serve`.

### Fixed jobs and evidence reuse

`diagnostic-legacy` preserves the original full-bound journey followed by one
instrumented profiler repetition. Its maximum offline-child deadline is one
hour. Use existing successful journey evidence for subsequent measurement;
do not repeat the journey merely because the profiler changed.

`profiler-only` runs two separate processes: five wall-only profiler
repetitions, then one instrumented repetition. Wall-only mode never installs
the dispatch census. Each process retains actual-model parity checks. The
maximum offline-child deadline is one hour. These measurements are diagnostics,
not a statistically qualified throughput gain.

For profiler-only reuse, prepare private copies of the prior `manifest.json`,
`completed.json`, and `journey.json` under `.lab-window/reuse/` in the campaign
clone. The runner checks the successful terminal receipt's original manifest
binding, the executed journey checks, unchanged provider source and artifact
identities, and fixture identities. It freezes hashes of all three imported
files. Historical receipts did not hash the journey output: this import pins
the protected archive now, not retroactively. Retain that provenance limitation
in the private evidence record. A partial journey remains partial.

The new fixture clone is content-hashed once before provider pause using the
same canonical full-snapshot identity as the harness, including weight and
tokenizer bytes. A private preflight receipt outside the fixture pins file
metadata; changes, additions or removals are refused before model load. Normal
`status` calls do not reread all model weights.

Preflight also freezes private copies of the executables, their Metal
libraries, and the qualification policy when applicable. Each subprocess
executes those hash-verified copies, not a path that a concurrent build can
replace. Source inputs, private copies and fixture metadata are revalidated
between subprocesses and before the final receipt; drift fails the job.

`qualification` uses `.lab-window/qualification-policy.json`, a frozen policy
for exactly sixteen native cells: slots 1–4 × prompt lengths 1536/4096 × output
lengths 128/512, followed by the continuous 1800-second sustained window.
The runner invokes one fixed `native-mtp-bench` process per cell, then the
sustained phase, with no arbitrary flags, selected-cell override, exploratory
mode, or partial-run resume. Each process has a one-hour ceiling and the whole
offline child has a twelve-hour ceiling (`STUDIO_LAB_TIMEOUT_S` may lower it).
The overall ceiling bounds provider unavailability; it is not an estimate or
a guarantee that every policy will finish. Exhausting either deadline fails
the job and restores service without weakening the qualification gates.

`glm-prefill` fills the missing 16k baseline using the existing lab CLI and
Metal library; GLMBench is not required. The frozen exploratory policy has
rows 1/2/4, output length 128, one warmup and ten paired measured blocks,
250 ms arrival interval and temperature zero. Native admission stays at one.
Use prompt lengths `[16384]` to extend unchanged 4k evidence, or
`[4096, 16384]` after a named prefill-path change justifies a comparison.
The fixed matrix has three or six cells, with no sustained phase, profiler,
or journey. Each cell has a two-hour ceiling; the guarded window has a
six-hour ceiling. These ceilings bound unavailability, not expected duration.
The receipt marks the results exploratory and measurement-only; they cannot
qualify or activate native-row admission. Preserve exact-token parity and
report end-to-end TTFT separately from isolated reference prefill rates.

`qwen-qualification` runs the fixed `qwen/qwen3.6-35b-a3b` policy: native
active-row bound one, eight qualified slots, four one-row cells at prompt
lengths 1536/4096 and output lengths 128/512, plus gated cells
`s2-p1536-o512` and `s8-p1536-o512`. The continuous 1800-second sustained
phase follows on `s8-p1536-o512`, then the fixed provider-local
`native-mtp-journey-e2e --selftest-only` command captures the challenge-bank
record on the same runtime. This capture is not a coordinator canary or
live gateway proof. Preserve the preregistered 250 ms arrival
interval, ten measured blocks and existing R015 thresholds.

Prepare separate isolated snapshots in `.lab-window/fixture/target` and
`.lab-window/fixture/mtp`, plus the Qwen v1 artifact projection at
`.lab-window/qwen-artifact-manifest.json` and the frozen policy at
`.lab-window/qualification-policy.json`. Projection paths are fixed to
`target`, `mtp`, `target/tokenizer.json`, and `mtp/config.json` respectively;
their SHA-256 values identify the complete snapshots and files.
The job binds the projection and
protects both snapshot roots against drift. It needs the lab CLI and its
Metal library; GLMBench is not required. The live GLM artifact projection
remains in place during qualification. The same bounded supervisor, lock,
signed-provider restoration and completion checks apply. A completed lab job
does not publish or activate an admission.

`qwen-journey` uses the same protected Qwen inputs and fixed tuple to run only
the full local `native-mtp-journey-e2e` harness. It does not repeat the R015
matrix or sustained test. The Qwen harness tests its actual
`native_mtp_sampled_text_v1` profile, including seeded sampled parity and
forced rollback. Every local check must pass; the result remains explicitly
partial because coordinator, billing, and other external journey clauses are
not exercised by this offline process. Its child deadline is 5400 seconds and
the guarded window ceiling is 7200 seconds. Preserve existing qualification
evidence and complete external acceptance separately.

Before pausing service, qualification runs the harness's authoritative
`--validate-only` preflight without loading the model. A policy not admitted
by that parser is refused. This runner does not raise the signed production
bound or bypass policy validation; laboratory-bound amendments belong to the
model campaign. Qualification binds its current binary and frozen inputs; it
does not require that binary to be byte-identical to a previous journey's
binary. Preserve existing journey evidence in the campaign instead of rerunning
it merely to satisfy a new build identity. Completing execution also does not
replace the R015 analyzer verdict, campaign audit, signed admission deployment,
or paid gateway proof.

New job completion records bind the job kind and immutable source, executable,
Metal, fixture, policy (where applicable), imported-evidence and reviewed-runner
identities. An unrelated repository commit does not invalidate identical
inputs, and completing one job cannot suppress another. The tracked-clean
exact campaign commit is retained separately as execution provenance. The
reviewed runner comes from clean main; the hash-bound campaign clone may be
an unmerged laboratory candidate.

## Adding a fixed job kind

A job kind absent from reviewed `origin/main` is an ops-tooling prerequisite,
not a completed hardware campaign. Land the bounded runner change through
normal tooling review and CI first; report its offline regression results and
keep hardware qualification explicitly pending. Then use that reviewed-main
controller for the model campaign against its hash-bound source clone. The
model campaign retains its own premerge hardware acceptance and signed
admission/live-proof gates. Do not execute the controller from the candidate
branch or relax the clean-`origin/main` check to test a new job kind.

## Execute

From a clean checkout of the exact current `origin/main`:

```sh
bash scripts/ops/studio-lab-window.sh status
bash scripts/ops/studio-lab-window.sh next
MACPROVIDER_OPS_OWNER=studio-lab-window \
  bash scripts/ops/studio-lab-window.sh next --run
```

Announce the selected provider's temporary unavailability before executing.
Its model is unloaded for the offline diagnostic and then reloaded. Other
providers and the buyer runner remain running; there is no Pearl coordinator
restart.

The controller authenticates the installed binary against the published
signed release, freezes the source/artifact and configuration identities,
and takes the live-operations lock. The detached supervisor pauses and
drains the provider, stops its watchdog and launch job, runs the fixed
offline child under its job-specific deadline, and proves the child group is gone before
restoring the signed provider.

Restoration requires the original serving identity and configuration,
an exact process identity held stable for 120 seconds, and the watchdog
restored. A successful restore does not turn a failed diagnostic into a pass.

## Recovery and handback

If the SSH connection or local controller disappears, the detached supervisor
continues its bounded operation and restoration. Retain the live-operations
lock and journal until the controller has confirmed completion.

Re-run `status`, `next`, and `next --run` using the same window directory.
An existing journal takes precedence over a new run. Do not remove a journal,
force-release a lock, or bootstrap another provider while an offline child
may remain alive. A baseline identity/configuration mismatch is a safety
refusal, not permission to overwrite the changed files.

Recovery uses the recorded job identity, not a newly selected job in the
environment. Existing diagnostic journals and their completion records remain
recoverable. Missing lab artifacts must not prevent restoration of the signed
provider from an active journal.

If dispatch never reached a durable journal, the controller authenticates and
aborts the prepared intent under the remote journal lock. A durable abort
receipt makes this cleanup resumable after another disconnect and prevents a
delayed dispatch from starting. Interrupted terminal cleanup is also resumable.
These cleanup steps do not count as a successful diagnostic; run `status` again
to determine the next guarded step. The private lock inode is retained so
waiting processes cannot acquire a different lock for the same window.

Copy the private supervisor and diagnostic results into the campaign's
evidence store. Record the diagnostic exit status separately from restoration,
the restored version and process identity, and the watchdog/runner state.
Publish only sanitized product acceptance evidence. Never describe this
offline window as live gateway or settlement proof.
