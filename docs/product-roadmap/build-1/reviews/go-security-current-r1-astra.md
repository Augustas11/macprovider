# Build 1 preliminary Go security and contract review — R1

- Reviewer: independent native agent, Astra high security lane.
- Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
- Branch: `codex/product-build-1`.
- Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
- Scope: all changed and untracked coordinator and integration files listed in the complete source manifest below; relevant existing pool, WS dispatch, buyer routing, receipt settlement/recovery and gateway finality callers were read for boundary context.
- Method: static source/diff and normative-contract review. No source edits, tests, service launches, operator-secret access or child agents. Only this report was written.
- Decision: **2 MEDIUM findings; 0 CRITICAL and 0 HIGH identified in this bounded review.** This is not a passing implementation audit. It does not replace the final complete combined code/security/architecture gates, and excludes the ongoing Swift/app source changes.

## S1 — MEDIUM: Whole-extension loss bypasses immutable route validation during recovery

**Evidence.** `phase4-coordinator/internal/billing/artifact_admission.go:93–113` selects `route_snapshot_json`, unmarshals the anonymous extension and returns `(nil, nil)` at lines 106–107 when the extension is absent. It calls `loadSettlementRouteSnapshotConn` (which validates the reconstructed route and its persisted digest) only after that early return. `recovery.go:305–320` then takes the legacy `RateFor(rewards.RateCard, model)` branch; the runtime model identifier can differ from the artifact's candidate rate key. The fixture deliberately establishes this distinction.

The downstream uncached path does not repair this omission: `settlement_receipts.go:315–364` joins an already verified verdict using the persisted digest columns, without recomputing the JSON digest; lines 385–388 construct rates directly from the recreated ledger. Its new `loadArtifactAdmissionForAttempt` call is inside the positive cached-prompt branch at lines 423–431. An attempt with no cache discount does not enter it.

**Concrete failure sequence.** Persist a valid artifact-bound route and a verified receipt verdict/output, retain the request log and immutable billing config, and recover a missing ledger row after the JSON has lost the entire artifact admission extension while the stored route digest remains unchanged. This may represent corrupt or lossy persisted-state handling; this review does not claim a provider wire endpoint can write the database. The helper classifies the record as legacy, recovery selects runtime/default pricing, and the existing verified verdict can authorize the newly reconstructed uncached credit without detecting that the route JSON no longer matches its digest. Even without a verified verdict, recovery creates a non-quarantined ledger row from fallback authority instead of refusing the inconsistent artifact record.

**Consequence.** The new artifact path's explicit missing-evidence fail-closed boundary is bypassed and recovery can reconstruct the wrong monetary units. This conflicts with SPEC-047 R003's missing/changed artifact evidence refusal and the v0.1.4 requirement to preserve legacy digest interpretation without downgrading artifact-derived records; SPEC-022 R003 requires the same route/receipt/ledger binding.

**Required correction.** When a route row exists, validate its complete immutable digest before deciding that an absent extension is a genuine legacy record. Preserve behavior for genuinely absent legacy routes and byte-identical valid old snapshots. Revalidate the captured artifact/route evidence on credit synchronization independently of whether cached tokens are positive, so a prior verdict is not treated as blanket authority for mutable reconstructed state. Add a regression with the entire extension removed, unchanged stored digest, different runtime/default/candidate rates, missing ledger row and a prior verified verdict; assert no new payable credit. Also cover partial/empty extension, valid legacy recovery and uncached credit synchronization. A small detection-only test against `Validate` is insufficient for this path.

**Confidence:** high in the early-return and fallback control flow; the full monetary sequence is statically traced and must be reproduced by the implementation lane.

## S2 — MEDIUM: Promotion commit is guarded against admission-event races but not live-authority races

**Evidence.** `phase4-coordinator/internal/ws/model_admission_authority.go:49–76` obtains a provider snapshot, checks sanctions and calls the authority resolver, then constructs and appends each promotion. `model_admission.go:264` and `:658` protect the append with `ExpectedCurrentEventID` plus the admission tuple; they do not condition the commit on the pool/session/config/sanction state that authorized it. Registry `Resolve` and `Conn` each release their read lock before returning (`pool/provider.go:2607–2634`); feed/config snapshot reads similarly do not span the admission append. A successful resolver result therefore does not guarantee its predicates remain current at append time.

**Concrete failure sequence.** Let the `settlement_capable` resolver return a valid snapshot, then replace/disconnect the provider session, apply an exclusion/sanction or change the effective billing/feed authority before `AppendModelAdmissionDecision`. The admission event ID can still be unchanged, so the event CAS succeeds and the HTTP offer/retry response reports `settlement_capable` from stale authority. Mutating live state while a resolver returns (or blocking the append at a deterministic test barrier) gives a controlled regression interleaving. A feed/config change during the resolver after its snapshots were captured creates the same gap.

**Consequence.** Invalid positive capability can be persisted and returned. Subsequent route/status checks substantially contain this: `buyer/model_admission.go:112–127` and `refreshArtifactAdmissionStatus` re-resolve and demote mismatches. This finding does **not** assert that stale promotion alone bypasses those paid-routing checks. It remains a direct breach of SPEC-047 v0.1.4's requirement to recheck current session/generation, sanctions, lease and probe validity when committing, and misstates provider-facing capability until another read/route corrects it.

**Required correction.** Establish a commit-time authority guard tied to the same session/config/sanction generation that was validated, with invalidation serialized against the promotion, or an equivalent transaction/guard that refuses stale commits. Retain the admission-event CAS for withdrawal/reoffer/revocation. Ensure offer and retry return a current valid result rather than a stale positive state. Add deterministic races at both promotion boundaries for session replacement/disconnect, exclusion/sanction and billing/feed change, not only mutations before selection or an old admission event.

**Confidence:** high in the missing shared commit guard and stale-state interleaving; no runtime race reproduction was run in this review.

## Accepted boundaries and remaining validation limits

- The provider's catalog key, discovery/evaluation digests, proposed artifact hashes and local preparation are not used as signed model or rate authority. The resolver binds the live SPEC-010 candidate identity to the verified primary artifact and independently loaded Tier2 material, requires the canonical manifest hash, and rejects missing/incorrect explicit rates.
- Candidate-catalog and Tier2 body digests remain distinct. The route digest covers the complete optional artifact/rate/session extension using integer-preserving canonicalization. Signed prompt/cache/completion rates, share and multiplier are carried into hot-path billing and the normal artifact recovery path.
- Retry reuses the closed authenticated offer schema and current signature verifier; it compares the pending offer identity and reserves request/nonce keys across retries and normal events. Coordinator event CAS prevents a stale probe from overwriting withdrawal/reoffer. Probe traffic uses the provider wire session, not a provider-specified endpoint dereference.
- Normal receipt verification still binds provider key, request attempt, output/usage and immutable route digest; gateway finality uses verified outcome before settling the buyer's token reservation. The artifact extension does not itself authenticate computation or grant an attestation tier.
- New tests cover selected authority mutations, rate fields/default refusal, simple event CAS, retry signature/tuple replay, extension field digest influence, normal captured-rate recovery, cached receipt settlement and a nonstream real-service fixture. They do not cover S1/S2's full interleavings. The legacy test checks field omission and validation but should also pin a pre-change digest value, especially when adjusting the recovery helper.
- The parent supplied prior successful coordinator/gateway suites, WS/buyer race tests, billing race tests and the real-service fixture result (20 buyer tokens, 16 gross credits, 14 provider credits). These runs were not rerun or independently observed by this reviewer. The parsed Swift companion's teardown assertion was reported pending when assigned. Both integration fixtures use disposable keys and deterministic provider output; neither is physical MLX or production conformance evidence. The real-service journey is nonstream and does not newly prove the artifact extension through streaming/failover.

## Complete owned source SHA-256 manifest

Hashes capture the review target before implementation follow-up. Any change invalidates this report's coverage for that file and requires review of the resulting combined diff.

Captured UTC: 2026-09-10T08:47:09.926145+00:00

```text
f0518cfc02120082b1de14a9f69afb6f540910d3d31b8b843ea5defbd2c9384d  phase4-coordinator/cmd/coordinator/main.go
d9bb77bd5a1cccf5bb8ae924204a80ab17060156391c6c96abdf786c93b1c17c  phase4-coordinator/internal/billing/artifact_admission.go
2d7bc85d9d9cf4c47627c76b752ac069619aada6f84f4b09b7a84643c8d2bd3d  phase4-coordinator/internal/billing/artifact_admission_test.go
2c6228c2e97b15e6a1c3ee7b4db6c14270787a65a089df52f9092a4018b7b05b  phase4-coordinator/internal/billing/quarantine_test.go
95c68af6ea5bbf11df33e57e8ff6060d7bbc118ea6b277c3dd5a2d1dda59e3ae  phase4-coordinator/internal/billing/recovery.go
2cc705c4a1f4137cc25b22aa317ddf30f303a7c27bae8bb221a8d8fef53d2597  phase4-coordinator/internal/billing/route_snapshot.go
8ef7fd08e8d0c25fe3c01d4efb0a55adace67a1b12c7accc646b56b64e809533  phase4-coordinator/internal/billing/settlement_receipts.go
898f16a533db9868777226799f282e7db5fd8b4a378c1ca4a653f65d2449988a  phase4-coordinator/internal/buyer/autotune_feeds.go
89d2672ca3237399619e8878c1e85bbc42ffd51b8a54cac74e72dca2aab63858  phase4-coordinator/internal/buyer/billing_recorder.go
5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549  phase4-coordinator/internal/buyer/model_admission.go
36776909256a4bb1ee0531efe157f185fa103163a7c8f9164968a1b01b75b94a  phase4-coordinator/internal/buyer/model_admission_authority.go
e9aeebde04fa0db5132854ad7b822a217a730447851e4f612c6d9d50bbbeb080  phase4-coordinator/internal/buyer/model_admission_authority_test.go
09242070eca6cebe3cd732829b9d14df3a9ec3d06f4a762ef08746d1b329d73f  phase4-coordinator/internal/buyer/route_snapshot.go
379913f313ecef918883bf554f90f582a880c3efa49079e622bd5f5f6d29117d  phase4-coordinator/internal/ws/model_admission.go
c634f7b5c0671b65528d25636743718e1d1bc3a23b5849b055239ea5bf9cf39b  phase4-coordinator/internal/ws/model_admission_authority.go
77eec1de1add7e7d8565191e10f252bb4082236860fa2bb0dad2f148eab661b7  phase4-coordinator/internal/ws/model_admission_authority_test.go
9edd8750696c67ec42e4f4d1dc9b5508240519cfd4a8d24c6614660c1ccde4f4  phase4-coordinator/internal/ws/model_admission_retry.go
03dc78cd089dc3f9b0d9755f7e84c4c978c63cb37067915f2e5dab7b9109d175  phase4-coordinator/internal/ws/server.go
6d63ad8f0d9ffcb2a52c1a2945053a4fbe197305b14b3714e8bf04125f284935  test/integration/build1_artifact_journey_test.go
83c8b28ef0078b15b2d6a16a8d3b3c098fbee4a1414feec88b9d444575eb4551  test/integration/build1_cli_bridge_test.go
8114ef52d6522d1888c49be407ca1a612ac1849ef2d55b261318830b546c3cac  test/integration/build1_transport_test.go
db64abc20609af21c9c3769316d38df83f9c3562f7273ad48984b0f714f6dfdf  test/integration/harness_test.go
```
