# M2 — AC-25 API lifecycle: implementation + evidence plan (v4)

Target: SPEC-038 AC-25 (`specs/SPEC-038-continuous-batching.md:840-846`), the
API-visible lifecycle overlay (`:605-624`), gate G6 (`:886-888`), the `API lifecycle`
row of `docs/runbooks/continuous-batching-enable-gate.md`, and M2 of #1646.

v4 supersedes v3. One reviewer approved v3 with must-apply edits; the other
rejected on clause arithmetic and an over-conservative deferral. Both are
applied below.

## 0. Verdict — AC-25 cannot be closed by an evidence campaign

**Clause ledger.** The overlay table at `:614-624` has **11** rows. AC-25's
sentence at `:842-846` adds `reconnect/replay after a terminal result`, for
**12 clauses total**. G6 (`:886-888`) adds none. §4 tables 11 evidence rows
covering **8** clauses; §5 defers **4** (three overlay rows plus reconnect).
8 + 4 = 12.

Counting *obligations* rather than lifecycle points gives the sharper number,
because `Retry-After` is a live sub-requirement inside the queue-full row:
**7 fully provable now, 1 partially provable (queue-full: backpressure yes,
retry guidance no), 4 lifecycle points deferred — 5 open obligations.**
Shown here so the next reviewer does not re-derive it.

Of those twelve, **two are already satisfied** and need confirmation only:

- Case 10's **HTTP error mapping already exists**: `ModelRuntime`'s swap drain
  throws `DrainCancelledError`, mapped at `HTTPServer.swift:682` and `:1073`.
  The mapping existing is not the same as case 10 being satisfied — the drain
  evidence itself is still deferred (§5).
- Case 5c's cached-terminal replay already returns from
  `ContinuousBatchScheduler.swift:1200-1204`.

The rest are blocked by five implementation gaps. Verified on `main` @ `b9b20fe4`:

| # | Gap | Evidence | Blocks |
| --- | --- | --- | --- |
| G-1 | No queue-wait admission deadline. `:2647-2660` is a pure count/token check; only `drainTimeoutNanoseconds` (`:82`) and `tokenDeliveryTimeoutNanoseconds` (`:89`) exist | `ContinuousBatchScheduler.swift` | case 2 |
| G-2 | **Five** scheduler errors unmapped, not four. `duplicateRequestMismatch`, `idempotencyWindowExpired`, **`idempotencyAuthorityUnavailable`** (`:805`, thrown `:1330` when the claim store errors) fall through `catch { throw error }` to generic `model_not_loaded` / `internal_error` | `ContinuousBatchScheduler.swift:797-806`; `ModelRuntime.swift:3919-3925`; `HTTPServer.swift:1142-1148` | cases 5a, 5b, 5d |
| G-3 | Backpressure mapped only on the **streaming** path; non-stream bare-rethrows | `ModelRuntime.swift:3909` vs `:3676` | case 1 (non-stream) |
| G-4 | Direct HTTP never signals client disconnect: `shouldCancel: { false }`. Only `InferenceRelay` carries cancellation state | `HTTPServer.swift:624,951`; `InferenceRelay.swift:658,662,929` | cases 7a, 7b |
| G-5 | No runtime fault-injection surface. `backendOverride` is fed only by `testContinuousBatchingBackend` | `ModelRuntime.swift:1995,3018` | cases 8a, 8b |
| G-6 | Warm swap off: `enableWarmSwap` defaults `false`, live config unset. Flippable per-instance via **`MACPROVIDER_ENABLE_WARM_SWAP`** (`Config.swift:702`) — no config edit needed | `Config.swift:218,702` | case 10 |

**Not in scope, corrected from v2:** `ContinuousBatchSchedulerError.drained` and
`.drainTimedOut` are reachable only through `ContinuousBatchScheduler.drain()`,
whose sole caller in `Sources/` is `MSBThroughputCommand.swift:1420` — a
harness, not the serve path. Mapping them would ship code no HTTP evidence can
exercise. v2 wrongly attributed case 10 to G-2; case 10 is blocked by G-6 alone.

### Correction: `Retry-After` is NOT a "MAY"

v2 claimed `:614` was a MAY and proposed softening the enable-gate Required
Evidence row. **That was a misreading and the proposal is withdrawn.** The
overlay header at `:607` reads "MUST map every batched request to exactly one
API-visible terminal outcome", and `:614` requires bounded retry guidance
"*when the gateway surface supports it*" — a conditional requirement, not
permission. The runbook's stop condition already says "missing retry guidance
**where required**", which is the correct restatement.

**The determination is already answerable, and the answer is yes.**
`phase5-gateway/internal/router/server.go:1255-1396` sets `Retry-After` on
rejection paths, so the gateway surface supports it and `:614`'s condition is
**met — i.e. the requirement is live**, not dormant. Consequence: proving
buyer-visible retry guidance needs the gateway/relay path, which Lane I
(`--no-join`, direct HTTP) structurally cannot exercise. Case 1 therefore
splits: its backpressure half is provable on Lane I, its `:614` retry-guidance
half joins the deferred set. **No PR in this campaign may relax the enable
gate.** Open sharpening: confirm whether those gateway paths cover
provider-backpressure rejection specifically or only rate-limit rejection.

**Consequence:** M2 is Phase A (implementation) then Phase B (evidence). If
Phase A is not funded, AC-25 does not close and the gate keeps blocking
promotion. State that rather than banking partial rows.

## 1. Live target state (measured 2026-09-22)

| Fact | Value | Source |
| --- | --- | --- |
| Host | Mac Studio M3 Ultra 256 GB | `ssh macstudio` |
| Installed binary | `/Users/a1/macprovider/macprovider-cli` sha256 `b0bb4034…` | matches signed v1.8.176 of record |
| `mlx.metallib` | present, 3814108 bytes, same directory | Package identity gate |
| launchd | `live.malibu.provider` pid 24373 + watchdog | `launchctl list` |
| Model | `qwen3-coder-30b-a3b-instruct`, artifact sha `10adb5da…` | provider config |
| Mode | `continuous_batching: canary`, `paged_kv.enabled: true` | provider config |
| Slots | `max_concurrency_override: 8` (hard cap 8, `ProviderStatus.swift:159`) | provider config |
| Queue limit | unset → `2 × 8 = 16`; max `8 × 8 = 64` | `ContinuousBatching.swift:181-191` |
| Terminal cache | `max(16, 2 × 16) = 32`; no production override | `ContinuousBatchScheduler.swift:115-118` |
| `enable_warm_swap` | unset → **false** | `Config.swift:218` |
| `GET /healthz` | **404** — not a usable liveness probe | measured |

These four are asserted from the live box and are not verifiable from a
read-only checkout: slots 8, the 404, the metallib bytes, and the binary sha.
Re-measure and paste raw output into the bundle; do not carry them on my word.

Carry one correction: the release-train "Active candidate" row still says
`slots 4`. Live is 8.

**176 predates #1672**, so acceptance coverage is not enforced on this binary.
The M7 activation build will enforce it and needs the tuple declared first.

## 2. Phase A — implementation slice

One campaign PR (AGENTS.md: code + Studio e2e, one PR, audit once at freeze).

1. **Queue-wait deadline** (G-1) — bounded admission wait, distinct API code,
   distinguishable from scheduler crash and unsupported tuple per `:615`.
2. **Map three errors** (G-2) — `duplicateRequestMismatch`,
   `idempotencyWindowExpired`, `idempotencyAuthorityUnavailable`, each to its
   own code with the settling/non-settling disposition. Explicitly record
   `.drained` / `.drainTimedOut` as serve-path-unreachable today; either wire
   `scheduler.drain()` into the swap path or declare it out of scope.
3. **Non-stream backpressure parity** (G-3) — same code both paths. Reconcile
   `inferenceRan: true` on that error with "non-settling, no receipt"; if the
   flag is wrong for a pre-admission rejection, fix it and say so.
4. **Direct-HTTP cancellation** (G-4) — wire real disconnect into
   `shouldCancel`. Without it a closed curl burns a slot while the request runs
   on, and 7a/7b cannot be evidenced on the direct path at all.
5. **`Retry-After` determination** (see §0) — answer, record, do not edit the gate.
6. **Fault-injection decision** (G-5) — recommend **no hook**: 8a/8b stay
   fixture-only and AC-25 does not fully close. Rationale, since a reviewer
   asked why G-1/G-3/G-4 are acceptable where G-5 is not: `backendOverride`
   exists today only as a compile-time seam fed by `testContinuousBatchingBackend`
   (`ModelRuntime.swift:1995,3018`). A runtime hook would *widen an existing
   test-only seam into production* — a new, operator-reachable way to induce
   failure on a buyer-serving inference path. G-1/G-3/G-4 add no such seam:
   they map errors that already occur, bound a wait, and honour a disconnect.
   (G-4 does change buyer-visible behaviour, so the distinction is seam-widening
   versus behaviour-correcting, not merely "reporting versus inducing".)

Phase A is audited on its own: three lanes, 0 C/H/M, before any evidence runs.
If that audit does not clear before the hardware window closes, the campaign PR
stays in draft and **no Phase B evidence is collected** — evidence gathered
against unaudited serving-path changes is not usable for the gate, and
collecting it anyway would invite recording it later as if it were.

## 3. Lanes and which binary each runs

| Lane | Binary | Cases | Notes |
| --- | --- | --- | --- |
| L — live 8080, buyer-serving | **signed v1.8.176** (unchanged, no restart) | 4, 9 | Neither needs a Phase A change |
| I — isolated `18080` | **Phase A build** | 1 (backpressure half), 2, 3, 5a, 5b, 5c, 5d, 7a, 7b | See launch mechanism below |
| deferred | — | 6, 8a, 8b, 10 | See §5 |

### Lane I launch mechanism — the failure here is silent

v3 said "run from the installed package path". That was wrong and dangerous.
`serve` re-execs via `execCanonicalInstall` (`MacProviderCLI.swift:3289-3299`)
whenever the launched path differs from canonical, and canonical resolves from
`launchdProgramBinaryURL()` (`AutoUpdateMarker.swift:421-430`) — on the Studio,
the live `live.malibu.provider` job. A Phase A build launched from elsewhere
would **silently exec into signed 176**, and every Phase-A-dependent case would
collect evidence from the wrong binary while appearing to succeed. The only
literal reading of v3's instruction — overwrite the live install — is the
buyer-serving binary swap §7 declares out of scope.

The purpose-built escape is `isolatesNoJoinLabServe`
(`MacProviderCLI.swift:1426-1436`). Precisely: `credential_store:
protected_file` is what bypasses the re-exec guard at `MacProviderCLI.swift:1493`;
`--no-join` **plus** protected-file then triggers the separate
lifecycle/control-path isolation at `:1529`, which is what keeps the lab
instance off the incumbent's launchd lease and control files. Both flags are
required, for two different reasons. This is the same shape the 2026-09-21
keyed first-turn lab e2e used.

Lane I therefore runs the Phase A build from **its own packaged directory**,
binary and `mlx.metallib` colocated (satisfying the runbook `:126-130` metallib
disqualifier), launched with `--no-join` and `credential_store: protected_file`.

**Positive check, mandatory before any case is recorded:** resolve the serving
pid's executable path (`lsof -p <pid>` / `ps`) and its SHA-256, and assert it is
the Phase A build, not `b0bb4034…`. The failure mode is silent success, so
absence of an error is not evidence.

### Evidence-class split — default is proceed

The bundle is **two evidence classes**: signed-176 for L, Phase-A-build for I.
The runbook prefers this shape (`:127`, "preferably a non-production test
provider"), so the **default is to proceed with the split and record it as an
evidence-class caveat in the bundle**. Escalate only if a reviewer rejects the
split at audit; if that happens, Lane L moves to the Phase A build and §7 needs
a binary-swap and rollback procedure for a buyer-serving box, which does not
exist today. v3's "get a ruling before collecting" is withdrawn — it made
execution wait on an adjudication with no named decider and no default.

The enable gate *prefers* this split — "Run the real-serve proof on the exact
hardware tuple that will be enabled, **preferably a non-production test
provider**". Lane I is the preferred shape, not a concession.

Lane I with `--no-join` proves direct-HTTP semantics only.

## 4. Evidence matrix (Phase B, after Phase A lands and is audited)

| # | Overlay clause | Lane | Trigger | Expected | Settlement |
| --- | --- | --- | --- | --- | --- |
| 1 | Queue full before admission (backpressure half) | I | `continuous_batch_queue_limit: 1`, `max_batch: 1`, 3 concurrent, **streaming and non-streaming** | 503 `continuous_batching_stream_backpressure`, same code both paths after G-3. The `:614` retry-guidance half is **deferred** — see §0 and §5 | Non-settling, no receipt |
| 2 | Queue wait timeout | I | Saturate slots, queue one past the new deadline | New distinct code, distinguishable from crash and unsupported tuple | Non-settling |
| 3 | Unsupported tuple before admission | I | Relaunch with `continuous_batching: on`, **`kv_bits` and `draft_model` unset** — both are evaluated before the capability branch (`ContinuousBatching.swift:296-303`) and would yield a different code; draft with `max_batch == 1` returns without throwing at all (`:347-349`), so startup would succeed | **Preflight rejection**, per `:616` "Strict mode fails preflight". Observable is a **stderr line `continuous_batching_local_capability_unavailable` + `ExitCode(2)`** — no HTTP status is ever emitted. Note `.on` cannot boot at all on this binary: `configurationCapability` does not pass `schedulerBackendAvailable`, so it defaults false and strict startup always throws (`ContinuousBatching.swift:204-226,266,288`). v2's "also capture an HTTP 400" is withdrawn as impossible | Non-settling |
| 4 | Permissive/canary serial-route | L | Single request with `temperature != 0` (or tools / `logprobs` / `logit_bias`) | 200 serial; stderr `event=batching_unsupported action=serial_routed reason=request_local_state_unrepresented` (`ContinuousBatching.swift:25`, logged `ModelRuntime.swift:3107`). Second trigger: omit `X-Request-ID` → `stable_request_id_unavailable`. **v3's sticky trigger is withdrawn** in favour of this simpler one. Note for the record: an earlier claim that direct HTTP cannot carry a conversation key was **wrong** — `HTTPServer.swift:560` applies `.withConversationKey(...)` from the `X-MacProvider-Provider-Conversation` header, which is how the 2026-09-21 keyed first-turn e2e drove live 8080. The sticky reason may therefore be reachable, but it requires an actual cache hit to engineer; the overlay (`:616`) requires reason-coded telemetry, not that specific reason, so the cheaper deterministic trigger is used instead | Settling, one receipt, serial |
| 5a | Duplicate ID before acceptance | I | Two concurrent POSTs, identical `X-Request-ID` and body | Attach or reject; never a second accepted unit of work | One settling owner |
| 5b | Duplicate ID, mismatched | I | Same ID, different body | Distinct mismatch code (G-2) | Non-settling |
| 5c | Duplicate after acceptance, within retention | **I** | Complete, resend same ID | Cached terminal result, no re-inference. Moved off Lane L: every synthetic request evicts the oldest terminal entry into a tombstone (`:2420-2426`), so a real buyer reconnecting on an evicted ID would hit the unmapped `idempotencyWindowExpired` → 500 | Non-settling replay |
| 5d | Retention rolled | I | **N+1 completed requests, N = max(16, 2 × the Lane I queue limit actually in use)** — eviction fires only on terminal-result insertion, so backpressure-rejected requests do not count. Then resend the original ID | `idempotencyWindowExpired` (G-2) via tombstone check at `:1250` | Non-settling |
| 7a | Cancel before first token | I | Disconnect during prefill (needs G-4) | No tokens, waiter cleaned up, slot released | Non-settling |
| 7b | Cancel after first token | I | Disconnect after first SSE frame (needs G-4) | Exactly one terminal frame, no late tokens | Non-settling |
| 9 | Successful usage finalization | L | Normal 256-token request | 200, `[DONE]`, receipt usage matches served model hash | Settling, exactly one receipt |

## 5. Deferred clauses and what that costs

- **Case 6, reconnect/replay through the relay.** The clause the enable-gate
  Durable replay row names as *the* outstanding gap: "packaged proof that
  reconnect/replay after a terminal result carries the correct settlement
  disposition through usage/receipt code".

  v3 deferred this on an overstrong premise — that it needs a provider joined
  to `coordinator.malibu.tech`. It does not. `test/integration/` already runs
  real coordinator and gateway binaries in temp state with
  `externalWebSocketProvider` (`harness_test.go:278`) and feeds coordinator
  `inference_request` frames through the **real Swift `InferenceRelay`** as a
  subprocess (`swift_relay_provider_test.go:210`). Nothing joins production.

  **Split the clause accordingly:**
  - *Phase A, now, cheap:* extend that harness to cover reconnect/replay after
    a terminal result and assert settlement disposition. This is real relay
    semantics and belongs in the campaign PR as regression coverage.
  - *Still deferred:* it is **not** AC-25 enable evidence. The harness builds
    via `swift build --product macprovider-cli`
    (`swift_relay_provider_test.go:72`) — the worktree build the enable gate
    explicitly disqualifies — and the fixture is relay-blind and deterministic
    rather than real MLX/CB. Packaged relay proof still needs a joined
    packaged instance.

  Before accepting an indefinite deferral of the packaged half, spend one
  scoping probe: a local `phase4-coordinator` build with unconfigured policy is
  a known-working join target, so the throwaway-coordinator path may be cheaper
  than assumed. **Highest-value remaining row; scope it immediately after
  Phase A.**
- **Cases 8a/8b**, scheduler failure pre/post side effects — fixture-only, G-5,
  by recommendation above.
- **Case 10**, warm-swap drain — needs `MACPROVIDER_ENABLE_WARM_SWAP=true` and
  a joined instance for the coordinator-heartbeat swap path; the already-mapped
  `DrainCancelledError` is the surface it must exercise. Deferred with case 6.

- **Case 1's `:614` retry-guidance half** — the gateway supports `Retry-After`
  (§0), so the requirement is live, and proving buyer-visible retry guidance
  needs the gateway/relay path Lane I cannot exercise. Deferred with case 6.

**Ledger: 7 clauses proven, 5 open** (cases 6, 8a, 8b, 10, and case 1's
retry-guidance half; case 1's backpressure half is proven). **AC-25 does not
close at M2.** The enable-gate API lifecycle row stays unchecked. Say so; do
not mark M2 done.

**Ownership of the standing blocker.** Cases 6 and 10 are funding-gated — more
work closes them. 8a/8b are not: absent a fault-injection hook they can never
produce packaged evidence, so what unblocks G6 is a *decision* — can the gate
accept scheduler-fixture evidence for those two clauses? That question needs an
owner, not another campaign.

## 6. Invariants checked on every case

Exactly one terminal event; settling vs non-settling as tabled; no duplicate
receipt; no cross-request attribution of tokens, stop reason, usage or receipt;
no buyer receipt/usage/billing/model-identity/settlement/API-schema change.

**Per-case binary assertion:** before recording any Lane I case, re-assert the
serving pid's executable path and SHA-256 against the Phase A build (§3). The
re-exec failure mode is silent, so this is an invariant, not a setup step.

## 7. Safety

- Never broad `pkill`. Narrow `pgrep -af`; launchd by label only.
- Lane I: separate config, state dir, port; never touches live 8080 config.
- Queue-limit lowering only in Lane I.
- Lane L is **low-risk, not no-risk** — cases 4 and 9 are real buyer-serving
  traffic. Unique request IDs, paced, no config change, capped request count.
- If the §3 ruling moves Lane L onto the Phase A build, that is a binary swap
  on a buyer-serving box: it needs a written rollback to the signed 176 install
  and a health check by real completion before and after. Not covered today.
- Restore watchdog and verify with a real completion (not `/healthz`, 404).
- Sanitize: no provider/buyer tokens, bearer headers, keys, or conversation text.
- Sticky stays fail-closed; no case drives positive `cached_prompt_tokens` into
  a batch — case 4 proves it does not.

## 8. Deliverables

1. Campaign PR: Phase A code, `Retry-After` determination recorded, and the
   slots 4→8 release-train correction. **No enable-gate relaxation.**
2. `docs/runbooks/continuous-batching-ac25-lifecycle-evidence-<date>.md` in the
   enable-gate template shape, with evidence class, binary sha and metallib sha
   per lane, and the four deferred clauses listed as open.
3. Three-lane audit at freeze, 0 C/H/M.
4. Update #1646 M2 with proven clauses only; leave the enable-gate API
   lifecycle row unchecked while any clause is open.

## 9. Out of scope

M3, M4 (AC-26 sticky), M6/A5 economics, M7 activation.
