# Implementation audit prompt — SPEC-013 Step 9 (recommendation surface)

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / canonicalization / persistence review** of the Step 9
commit on branch `feat/cli-autotune-impl`.

Step 9 carries:

| Commit  | Step | Scope |
|---------|------|-------|
| 292b2f9 | 9    | `RecommendationEmitter` + `RFC8785JCS` + `ConfigApplier` + `EmittedRecommendation` + 22 unit tests (690 src + 498 test lines) |

Full `phase3-binary` test suite is green per the commit's
`Tested:` line (344 tests, 2 skipped, 0 failures). Codex (the
implementer) raised zero Open Questions but did flag two
explicit design rejections in the commit:

1. **JSONEncoder-only recipe hashing REJECTED** — RFC 8785 JCS
   requires canonical key ordering + whitespace-free bytes
   independent of pretty JSON output.
2. **Yams emit for config writes REJECTED** — Yams 5.1 drops
   comments/order, so the applier validates with Yams then
   rewrites only the SPEC-013 top-level owned keys via a custom
   emitter.

Both rejections are acceptable in principle per FR-F.2/F.3, but
each opens a different precision gap that this audit must
scrutinize:

- The 81-LOC JCS encoder is small (my BUILD prompt estimated
  150-300 LOC) — verify it correctly implements the rules our
  schema actually exercises (lexicographic key sort by UTF-16
  code units, no whitespace, integer rendering, JSON null
  preservation, string escaping subset).
- The custom YAML rewriter (instead of Yams round-trip) is the
  load-bearing surface for AC-9's "every non-owned key
  byte-identical pre/post" assertion.

Operator wants an independent adversarial pass BEFORE Step 10
(failure modes + signal handling + `AutotuneCommand.run()`
wiring + `tune_runs` persistence) begins.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~30-40
min. **Read-only review**.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial implementation review of the Step
9 commit (292b2f9) on branch `feat/cli-autotune-impl` in the
Augustas11/macprovider repository. The branch is already checked
out at `/Users/augstar/macprovider-poc`. Steps 1-8 are LOCKED.

Steps 10-11 have NOT landed yet — your scope is exclusively the
Step 9 commit. This is a **read-only review**.

## Context

Step 9 implements the recommendation surface that translates an
autotune run's outcome into three operator-facing artifacts:

1. Terminal RECOMMENDATION block (FR-F.1) — plain text to stdout
   with model id, knobs, target context, replicated median tps +
   p95 TTFT, alternates (NAME-ONLY smaller candidates never
   probed under STOP-on-first-feasible), exact serve command.
2. `--json` output (FR-F.2) — full schema with spec_version,
   run_id, machine fingerprint, inputs, recommendation,
   alternates, infeasible, recipe_hash, db_path.
3. `--apply` config write (FR-F.3) — atomic temp+rename to
   `~/.config/macprovider/config.yaml`; collision-safe backup
   `config.yaml.bak-<unix-ts>-<counter>` (counter 0→65535, no
   overwrite); modify ONLY the 4 owned YAML keys (`model`,
   `kv_bits`, `max_context_override`, `max_concurrency_override`).

The `recipe_hash` is the load-bearing identity for "this machine
+ this recipe" — it MUST be reproducible across runs that
produce the same recommendation (even when observed tps differs)
AND across implementations (Swift produces same hash as a
Python reference vector). The hash domain EXCLUDES observation
fields (tps_median, ttft_p95_ms, replicates, run_id, timestamps,
alternates, infeasible) per FR-F.2.

## Required reading (in this order)

1. The Step 9 commit via `git show 292b2f9`.

2. The Step 9 source under audit:
   - `phase3-binary/Sources/macprovider-cli/RecommendationEmitter.swift`
     (402 lines, NEW).
   - `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
     (81 lines, NEW).
   - `phase3-binary/Sources/macprovider-cli/ConfigApplier.swift`
     (207 lines, NEW).
   - `phase3-binary/Tests/macprovider-cliTests/RecommendationEmitterTests.swift`
     (300 lines, NEW; ~14 unit tests).
   - `phase3-binary/Tests/macprovider-cliTests/ConfigApplierTests.swift`
     (198 lines, NEW; ~8 unit tests).
   - `phase3-binary/implementation-notes.html` — new
     `spec013-autotune-step9` section.

3. The locked SPEC (READ-ONLY):
   - `specs/SPEC-013-cli-autotune.md` v0.3 §5.6 FR-F.1
     (terminal block fields), FR-F.2 (full JSON schema + hash
     input domain + JCS rules), FR-F.3 (--apply atomicity +
     backup counter + 4 owned keys).
   - §8 AC-9 (--apply round-trip + byte-identical non-owned
     keys + idempotence).
   - §8 AC-11 (JSON schema validation).
   - §8 AC-12 (recipe_hash 4 properties: reproducible
     same-machine, reproducible cross-implementation, sensitive
     to machine RAM, sensitive to binary version).

4. RFC 8785 JCS reference (for the JCS encoder verification):
   https://datatracker.ietf.org/doc/html/rfc8785 §3.2 (object
   key sort by UTF-16 code unit), §3.2.2 (number rendering per
   ECMA-262), §3.2.3 (string escaping).

5. The four owned YAML keys per Step 9's surface area, confirmed
   in `phase3-binary/Sources/MacProviderCore/Config.swift` lines
   239-241: `kv_bits`, `max_context_override`,
   `max_concurrency_override`. Plus `model` at top-level.

## Severity definitions (unchanged from prior steps)

- **CRITICAL** — silent contract violation that breaks one of
  AC-9/AC-11/AC-12 properties; the JCS encoder produces
  non-canonical bytes that diverge from a reference Python
  implementation; recipe_hash leaks an observation field;
  ConfigApplier's backup overwrites an existing file;
  ConfigApplier mutates a non-owned key; anti-regression broke
  any Step 1-8 test.
- **MAJOR** — Step 9 contract gap; JCS encoder has a subtle
  precision drift (e.g. wrong key sort comparator, missing
  string escape, wrong number rendering); ConfigApplier write
  is not atomic; backup counter exhaust behavior wrong;
  terminal block omits a required field; --json schema field
  missing or mis-typed.
- **MINOR** — quality issues, naming, test edge cases, missing
  forward-compat seam.
- **QUESTION** — design choice where the SPEC was silent.

## Critical constraints (unchanged from prior steps)

1. SPEC-013 v0.3 is LOCKED.
2. Anti-regression — 322 baseline tests + 22 new = 344 must
   pass.
3. Strict clean-room on d-inference.
4. Read-only.
5. NO SIGKILL escalation in v1.
6. Step 9 must NOT wire `AutotuneCommand.run()` — Step 10's
   job. Verify Step 9 stays standalone.

## Audit categories — work through each

### Category A: RFC 8785 JCS encoder correctness

The highest-risk surface in Step 9. Codex shipped 81 lines —
verify each rule the spec demands is enforced for the schema
our hash input exercises.

A.1  **Object key sort** must be UTF-16 code unit order per
     RFC 8785 §3.2.3 (NOT byte order, NOT case-insensitive).
     For our domain keys (`binary_version`, `candidate_models`,
     `chip`, `knobs`, `model`, `ram_gb`, `target_context`),
     UTF-16 vs UTF-8 vs ASCII order is identical (all
     lowercase ASCII), so the bug would only show on
     hypothetical mixed-case keys. Verify the comparator's
     INTENT is UTF-16 code unit even if our data doesn't
     exercise the edge.

A.2  **No whitespace** anywhere. The output bytes must contain
     no spaces, no `\n`, no `\t`, no indentation. A test would
     reveal this — assert `jcsBytes.contains(0x20)` returns
     false for a representative input.

A.3  **Number rendering per ECMA-262**. For integers
     (`ram_gb`, `kv_bits`, `max_concurrency_override`,
     `max_context_override`, `target_context`), the format is
     the decimal representation without trailing zeros or
     leading `+`. Verify the encoder doesn't emit
     `4.0` for `4` or `04` for `4`. The 81-LOC encoder must
     handle Int rendering correctly; if it routes through
     `Double`, ECMA-262 rules apply and may introduce
     subtleties.

A.4  **`null` for omitted `kv_bits`**. When the unquantized
     cell wins, the JCS input's `knobs.kv_bits` must be the
     literal JSON `null` token (4 ASCII bytes), NOT omitted
     from the object, NOT the string `"unset"`, NOT `0`. Verify
     this in the encoder AND in the test
     `testRecipeHashOmitsKVBitsCorrectlyWhenNilWins` (or
     equivalent).

A.5  **String escaping** for the keys/values that contain
     escapes. Our domain strings (model ids like
     `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, chip
     `Apple M2`) only use printable ASCII (no special chars).
     Verify the encoder correctly handles the cases it would
     hit: forward slash `/` (RFC 8785 says don't escape unless
     in a contextual position — the JSON spec allows but
     doesn't require escaping `/`). The 81-LOC encoder should
     NOT escape `/` since RFC 8785 §3.2.2.2 prefers the
     unescaped form. If the encoder escapes `/` to `\/`, the
     bytes drift from the reference Python implementation that
     doesn't escape, and AC-12 property 2 (cross-impl) breaks.

A.6  **Array order preserved**. `candidate_models` MUST appear
     in input order, not sorted. Verify the encoder doesn't
     sort array elements (only object keys).

A.7  **`testRecipeHashMatchesReferenceVector`** — the most
     important test. Walk it line by line:
     - The hash input JSON must be the literal:
       ```
       {"binary_version":"1.4.0","candidate_models":["mlx-community/Qwen2.5-Coder-7B-Instruct-4bit","mlx-community/Llama-3.2-3B-Instruct-4bit"],"chip":"Apple M2","knobs":{"kv_bits":4,"max_concurrency_override":1,"max_context_override":4000},"model":"mlx-community/Qwen2.5-Coder-7B-Instruct-4bit","ram_gb":16,"target_context":4000}
       ```
     - The expected hex must be computable independently. Run:
       ```
       printf '%s' '<the above JSON>' | shasum -a 256
       ```
       on your codex sandbox; the result should match the
       literal hex baked into the test. If they DON'T match,
       the JCS encoder is producing different canonical bytes
       than the literal — that's a CRITICAL precision drift.

     **If the test passes** but the expected hex was baked in
     from a run of the Swift encoder itself (not an
     independent computation), the test is tautological. That's
     a MAJOR test-quality gap because AC-12 property 2
     specifically requires cross-implementation determinism.

A.8  **Trailing zero / scientific notation guard**. ECMA-262
     number rules render `1e-7` for very small numbers and
     positive exponents for very large. Our integers don't
     hit either, but if the encoder accidentally treats them
     as `Double`, large integers (e.g. `max_context_override
     = 131072`) could emit as scientific notation. Verify
     this doesn't happen for typical context sizes.

### Category B: recipe_hash domain isolation

B.1  Walk the recipe_hash computation. The hash input MUST be
     EXACTLY the 7 documented fields (plus 3 nested knobs):
     `binary_version`, `candidate_models`, `chip`, `knobs`
     (`kv_bits`, `max_concurrency_override`,
     `max_context_override`), `model`, `ram_gb`,
     `target_context`. NO observation fields leak in.

B.2  Confirm the following fields are NOT in the hash input
     (this is the "identifies recipe, not observation"
     invariant):
     - `run_id`, `started_at`, `ended_at`
     - `os_version` (intentionally excluded per spec — OS
       updates don't drift the recipe)
     - `stage1_replicates`, `stage2_replicates`,
       `gate_ttft_ms`, `tps_tie_epsilon` (test/tuning
       parameters)
     - `tps_median`, `ttft_p95_ms`, `replicates` (the
       measurements themselves)
     - `alternates`, `infeasible` (run-shaped, not
       recipe-shaped)
     - `db_path`, `serve_command` (path/CLI artifacts)

     A leak of any of these = CRITICAL (recipe_hash would
     drift between runs that should be identical).

B.3  `testRecipeHashIgnoresObservationFields` — verify the
     test actually constructs two `RecommendationInputs` that
     differ ONLY in observation fields (`tpsMedian`,
     `ttftP95MS`, `runID`, `startedAt`, `endedAt`) and asserts
     the resulting hashes are IDENTICAL. If the test only
     varies one observation field, that's a MINOR test gap.

B.4  `testRecipeHashSensitiveToMachineRAM` — verify the test
     produces DIFFERENT hashes for `ramGB = 16` vs
     `ramGB = 8`. AC-12 property 3.

B.5  `testRecipeHashSensitiveToBinaryVersion` — verify the
     test produces DIFFERENT hashes for `binaryVersion =
     "1.4.0"` vs `binaryVersion = "1.5.0"`. AC-12 property 4.

B.6  Edge: when `recommendation == nil` (no model picked),
     what is recipe_hash? SPEC says the JSON
     `recipe_hash` field is part of the schema, so it must be
     SOMETHING — but the hash input requires
     `recommendation.model` and `recommendation.knobs`. Spec
     ambiguity. Codex's choice should either:
     (a) Omit recipe_hash from JSON when recommendation is nil
         (additive-field interpretation), or
     (b) Hash a degenerate input where model + knobs are some
         sentinel (e.g. empty string + null knobs).
     Flag whichever choice Step 9 made and note it as a
     QUESTION for Step 10's wiring.

### Category C: SHA-256 + format wrapping

C.1  Walk the SHA-256 computation. Verify:
     - `CryptoKit.SHA256.hash(data:)` (or equivalent) is fed
       the EXACT JCS bytes (not a hex string, not a UTF-16
       encoding).
     - The 32-byte digest is hex-encoded LOWERCASE (verify
       `%02x` format string, not `%02X`).
     - The output is prefixed with `sha256:` (literal lower)
       and contains exactly 64 hex chars after the prefix.

C.2  `testJSONOutputRecipeHashFormat` — verify the test
     asserts the regex `^sha256:[0-9a-f]{64}$` AND the absence
     of uppercase chars.

### Category D: Terminal block (FR-F.1)

D.1  Walk the terminal block emitter. Verify all required
     fields per FR-F.1 are present:
     - Model id (full HF path)
     - Knobs section with `kv_bits`, `max_concurrency_override`,
       `max_context_override` (YAML key names, NOT CLI flag
       names — this is the round-trip surface)
     - Target context
     - Measured: median tps + p95 TTFT + replicate count
     - Alternates list (NAME-ONLY)
     - Serve command line (CLI flag names: `--kv-bits`,
       `--max-batch`, `--max-context`)

D.2  **stdout vs stderr.** The terminal block MUST go to
     stdout per FR-F.1. Verify the emitter returns the block
     as a string (Step 10 will print to stdout) — but if Step
     9 already wires print(), verify it's `print` not
     `FileHandle.standardError.write`.

D.3  `testTerminalBlockEmitsKVBitsUnsetWhenNilWins` — when
     `kvBits == nil`:
     - Terminal renders `kv_bits: unset` (string literal)
     - Serve command line omits `--kv-bits N` entirely
     Verify both assertions in one test (the most efficient
     check).

D.4  `testTerminalBlockShowsNoRecommendationWhenRecommendationNil`
     — passing nil recommendation:
     - Produces a "NO RECOMMENDATION" header (or similar
       clearly-empty marker)
     - Lists infeasibles in size-ordered iteration order
     - Does NOT emit a serve command line

### Category E: --json schema (FR-F.2)

E.1  Walk the JSON emitter. Verify every documented field is
     present:
     - `spec_version` literal `"SPEC-013 v0.3"`
     - `run_id` (UUID string)
     - `started_at` / `ended_at` (ISO 8601 with Z suffix)
     - `machine.{ram_gb, chip, os_version, binary_version}`
     - `inputs.{target_context, candidate_models[],
       stage1_replicates, stage2_replicates, gate_ttft_ms,
       tps_tie_epsilon}`
     - `recommendation.{model, target_context, knobs{...},
       tps_median, ttft_p95_ms, replicates, serve_command}`
       OR `null`
     - `alternates[]` (string array, may be empty)
     - `infeasible[].{model, rank, reason}`
     - `recipe_hash`
     - `db_path`

E.2  **YAML key names in `recommendation.knobs`**: the JSON
     output must use `kv_bits`, `max_concurrency_override`,
     `max_context_override` — NOT `kvBits`, `maxBatch`,
     `maxContext`. This is the v0.1 spec bug — the keys map
     to YAML, not to Swift property names or CLI flags.
     Verify Step 9 did not regress here.

E.3  `kv_bits == null` (literal JSON null) when the
     unquantized cell wins. NOT `"unset"` string. NOT omitted
     from the knobs object. Verify the encoder behavior.

E.4  `testJSONOutputMatchesSpec013Schema` — every documented
     field present with documented type. Verify the assertion
     style: ideally a schema check (every key present), not
     just spot-checks.

E.5  `testJSONOutputRecommendationFieldIsNullWhenNotSelected`
     — `inputs.recommendation == nil` produces JSON
     `"recommendation": null`, NOT `{}` or omitted.

E.6  **alternates list**: array of NAME-ONLY model ids, in
     input order, AFTER the chosen model. Verify the slice
     logic. Edge cases:
     - Chosen is first → alternates = rest of list
     - Chosen is last → alternates = `[]`
     - Chosen is middle → alternates = entries AFTER chosen
     - Chosen is not in input list (operator passed override
       that diverged) → undefined per spec; flag as QUESTION
       if Step 9 made a choice.

E.7  `testAlternatesListIsSliceAfterChosenModel` and
     `testAlternatesListEmptyWhenChosenIsSmallest` —
     verify both tests cover the documented contract.

### Category F: kv_bits nil propagation (cross-cutting)

The `kvBits = nil` (unquantized baseline) case has four
distinct surfaces and they MUST all agree:

F.1  Terminal block: `kv_bits: unset` (string)
F.2  Serve command line: no `--kv-bits` flag at all
F.3  JSON output: `"kv_bits": null` (literal JSON null)
F.4  JCS hash input: `"kv_bits":null` (literal JSON null)
F.5  ConfigApplier YAML write: NO `kv_bits:` line in the
     output YAML (the key is omitted, not written as `null`)
F.6  ConfigApplier summary string: `kv_bits=unset` (matches
     terminal convention)

A divergence between any two of these = MAJOR (operator
copy-pastes one form, but the apply path produces a
different recipe).

### Category G: ConfigApplier backup counter (FR-F.3)

G.1  Walk the backup path computation. Verify the algorithm:
     - First try `<config>.bak-<unix-ts>-0`.
     - If exists, try counter `1`, `2`, ... up to `65535`.
     - If `65535` is still taken, throw
       `backupCollisionsExhausted` (or named equivalent).
     - NEVER overwrite an existing file.

G.2  `testApplyCreatesBackupAtCounterZeroWhenNoCollision`
     and `testApplyIncrementsCounterWhenBackupExists` —
     verify both test cases. The increment test must
     pre-create `.bak-<ts>-0` (not just rely on timing).

G.3  `testApplyThrowsWhenAllCountersExhausted` (if shipped)
     — if not, MINOR (acceptable trade-off given 65536-file
     pre-creation is impractical). The codex implementation
     might have a parameterized upper bound for testing —
     verify it does.

G.4  **Race condition**: between checking "does this counter
     path exist" and "create this file as backup", a
     concurrent autotune could create the path. Walk the
     create logic — is it `open(O_EXCL)` semantics, or a
     stat-then-create? The latter has a TOCTOU window. Flag
     if so (MINOR for v1; documented limitation).

### Category H: ConfigApplier atomic write (FR-F.3)

H.1  Walk the atomic write algorithm. Verify:
     - The new YAML is written to a temp file in the SAME
       directory as the target config.yaml.
     - The temp file is then renamed to the target via
       POSIX `rename` (which is atomic on macOS HFS+/APFS
       when source and dest are in the same directory).
     - NOT `FileManager.replaceItem` (which does
       delete-then-rename and is NOT atomic).

H.2  `testApplyWriteIsAtomic` (if shipped) — verify the
     atomicity is asserted. If not testable directly,
     verify the implementation calls `Darwin.rename` /
     `posix_rename` and not `FileManager.replaceItem`.

H.3  Verify the temp file is on the SAME filesystem as the
     target. If the temp is in `/tmp` and config is in
     `~/.config`, those may be different filesystems and
     `rename(2)` returns `EXDEV`. The implementation
     should construct the temp path adjacent to the target
     (e.g. `<configPath>.tmp.<unix-ts>.<pid>`).

### Category I: ConfigApplier non-owned key preservation (FR-F.3, AC-9)

This is the load-bearing claim of the "Yams emit rejected,
custom rewriter" design decision. AC-9 says non-owned keys
must be byte-identical pre/post.

I.1  Walk the YAML rewrite algorithm. The expected design:
     - Parse the original config via Yams to validate it's
       valid YAML.
     - Locate the 4 owned keys in the raw text (regex,
       line-by-line scan, or similar).
     - Replace the values of the 4 owned keys with the new
       values.
     - Write the modified text back.

     Risks:
     - **Comments adjacent to owned keys**: if `model: foo
       # comment` is rewritten as `model: bar`, the comment
       is lost. Is this acceptable per FR-F.3? Yes — spec
       allows comment loss if the YAML library doesn't
       preserve them. But verify the implementation doesn't
       accidentally CORRUPT the line (e.g. produce
       `model: bar# comment` with no whitespace).
     - **Multi-line values**: if `model: |\n  foo\n  bar` is
       the original, naïve replacement could leave dangling
       indentation. Verify the rewriter handles this OR
       documents the v1 limitation that owned-key values
       MUST be single-line strings/ints.
     - **Key absent from original**: if `kv_bits` was not
       in the original config, the rewriter must INSERT it.
       Verify the insertion position is consistent (e.g.
       end of file, or near other owned keys).
     - **Key present but nil-valued**: if original has
       `kv_bits:` (no value) or `kv_bits: null`, the
       rewriter must replace correctly without producing
       `kv_bits: 4null`.

I.2  `testApplyPreservesNonOwnedKeysVerbatim` — verify the
     test:
     - Writes a config with several non-owned keys
       (`coordinator_endpoint`, `provider_token`,
       `log_path`).
     - Applies a recommendation.
     - Asserts the non-owned keys are BYTE-IDENTICAL pre/post.
     - Ideally, asserts COMMENTS adjacent to non-owned keys
       are preserved (the apply did not corrupt them).

I.3  `testApplyMutatesOnlyFourOwnedKeys` — diff pre/post;
     ONLY the 4 owned keys' values change. Verify the test
     does a proper YAML key-by-key diff, not just a string
     contains check.

I.4  **Spec round-trip test** the binary's `Config.swift`
     parser MUST be able to read the post-apply config and
     return the new owned values. Codex may not have shipped
     this test (it's an AC-9 round-trip property that Step
     11 would normally cover); flag if missing as MINOR
     forward-compat.

I.5  Edge: what if the original config has TWO instances of
     the same key (`model: foo\nmodel: bar`)? The
     custom rewriter's behavior is undefined; flag as
     QUESTION.

### Category J: Idempotency (FR-F.3, AC-9)

J.1  `testApplyIsIdempotent` — verify the second apply with
     the same recommendation produces a post-apply config
     byte-identical to the first post-apply (modulo backup
     paths). If the test asserts something weaker (e.g.
     "didn't throw"), that's a MAJOR test gap.

J.2  The backup PATH differs across calls (different counter
     or timestamp), so the test must exclude backup path from
     the comparison.

### Category K: launchd restart hint (FR-F.3)

K.1  Verify `RecommendationEmitter.launchdRestartHint()` (or
     equivalent) produces a string containing:
     - `launchctl bootout`
     - `launchctl bootstrap`
     - The plist path
       `~/Library/LaunchAgents/live.malibu.provider.plist`
     - The service identifier (`live.malibu.provider`).

K.2  `testLaunchdRestartHintIncludesBootoutAndBootstrap` —
     verify the assertions cover the substrings above.

K.3  The hint is emitted to STDERR (not stdout) per FR-F.3.
     If the helper just returns a string, Step 10 decides
     the destination — that's fine. If Step 9 already prints,
     verify it goes to stderr.

### Category L: Anti-regression on Steps 1-8

L.1  Run `swift test --package-path phase3-binary` and verify
     344 tests + 2 skipped, 0 failures.

L.2  `git show 292b2f9 --stat` adds 6 files (3 source + 2
     test + implementation-notes); verify no existing source
     modifications.

L.3  Stage1Iterator + Stage2HillClimb + AutotuneDB +
     ProviderPreWarmer + CandidateProviderRunner unchanged.

### Category M: Forward-compatibility (Step 10)

M.1  Step 10 (`AutotuneCommand.run()` wiring) needs:
     - Build the `RecommendationInputs` from Stage 1 +
       Stage 2 results.
     - Call `RecommendationEmitter.build(_:)`.
     - Print the terminal block to stdout.
     - If `--json`, print the JSON to stdout.
     - If `--apply`, invoke `ConfigApplier.apply(...)` and
       print the summary.
     - If `--apply` AND NOT `--drain`, print
       `launchdRestartHint()` to stderr.
     Verify the seams are present (init parameters,
     accessor methods, no hidden static state).

M.2  Step 10 also needs to persist `recipe_hash` to
     `tune_runs.recipe_hash`. Verify the
     `EmittedRecommendation.recipeHash` field is accessible
     for that persistence (not hidden in a struct internal).

M.3  `recommendation == nil` branch: if no model was
     picked, Step 10 must still emit a JSON (with
     `recommendation: null`), still write a `tune_runs`
     row, but MUST NOT call `ConfigApplier.apply`. Verify
     `RecommendationEmitter.build(_:)` returns an
     `EmittedRecommendation` with a non-empty JSON in this
     case (the terminal block can be "NO RECOMMENDATION").

### Category N: Anything else

Examples:
- The implementation-notes section accurately describes the
  JCS encoder decisions (key sort, number rendering, null
  handling, string escape subset implemented).
- Naming consistency with prior steps
  (`RecommendationEmitter`, `ConfigApplier`, `RFC8785JCS`).
- The codex commit's two `Rejected:` directives are
  documented in implementation-notes.html with rationale.

## Output structure

APPEND to
`/Users/augstar/macprovider-poc/specs/SPEC-013-impl-audit.md`:

```
---

## Round 16 audit (Codex on 292b2f9 — Step 9 round 1)

**Audited:** commit 292b2f9 on branch feat/cli-autotune-impl
**Auditor model:** Codex / GPT-5
**Audit round:** Step 9, round 1 of N
**Date:** 2026-06-18
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]
**Step 9 readiness:** [READY TO PROCEED TO STEP 10 / FIX REQUIRED]

### Executive summary

[2-3 paragraphs.]

### Findings

Group by category A-N.
```

## Out of scope

- Inspecting d-inference source
- Modifying any file
- Re-litigating Steps 1-8 (LOCKED)
- Auditing Steps 10-11 (not yet started)
- Re-litigating SPEC-013 v0.3 LOCK

## Done criteria

- New `## Round 16 audit ...` section appended
- Earlier rounds (1-15) unchanged
- Every category A-N has a section (even if `(no findings)`)
- Every finding has severity, location, what / why /
  recommendation
- `swift test --package-path phase3-binary` was run and the
  result reported
- The `printf '...' | shasum -a 256` cross-check on the
  reference vector was attempted; the result reported
- Verdict line states READY TO PROCEED TO STEP 10 or FIX
  REQUIRED

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: 30-40 min.
- The 81-LOC JCS encoder (Category A) is the load-bearing
  precision surface. A subtle deviation would break AC-12
  property 2 (cross-implementation determinism).
- The custom YAML rewriter (Category I) is the load-bearing
  preservation surface for AC-9.
- If verdict is READY TO PROCEED TO STEP 10: Claude commits and
  fires Step 10 (failure modes + signal handling +
  `AutotuneCommand.run()` wiring + `tune_runs` persistence +
  size-ordered candidatesBySize for Stage 1).
- If verdict is FIX REQUIRED: fix-pass + next round.
