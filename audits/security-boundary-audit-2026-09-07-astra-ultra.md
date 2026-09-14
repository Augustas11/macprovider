# Security Boundary Audit: phase3-binary and phase5-gateway

- Audit date: 2026-09-07.
- Audited merged commit: **afe6b12e1872aa7d2ddd94817120d37a77f31c0f**.
- Base: freshly fetched `origin/main`; canonical main matched this commit.
- Worktree: `/Users/augstar/.codex/worktrees/macprovider/security-boundary-audit-2026-09-07`.
- Execution: six native audit lanes explicitly configured with `gpt-6-astra`, reasoning `ultra`, followed by leader synthesis and verification. This describes the requested child-agent configuration; the parent session's model setting was not independently inspected.
- Read-only audit: no implementation changes, commits, pushes, production credential access, production probes, or signed journey creation. This requested report is the only authored repository file.
- Result: **4 High, 9 Medium, 3 Low; no confirmed Critical finding.** This is not a conformance or production-readiness certification.

## Ranked Findings

| Rank | ID | Severity | Finding | Evidence strength |
|---|---|---|---|---|
| 1 | F01 | High | Case-colliding token fields bypass gateway generation limits | Cross-layer source and local Go API documentation; end-to-end attack unrun |
| 2 | F02 | High | Gateway fallback finalizes debit without required receipt finality | Direct branches and passing tests that explicitly assert the fallback |
| 3 | F03 | High | OAuth handoffs persist reusable API keys in plaintext | Router, schema, insertion, consumption and pruning source |
| 4 | F04 | High | Local consumer classifies ambiguous sends as zero-dispatch and releases budget | Direct branches and passing tests; real-wire trigger unrun |
| 5 | F05 | Medium | Wallet receipt route omits signatures and session-level authorization | Complete gateway auth-to-upstream call path |
| 6 | F06 | Medium | Wallet inference bypasses replay storage ceilings | Admission transaction and request-type evidence |
| 7 | F07 | Medium | Wallet metadata throttles a session/IP pair, not independent identities | Source plus in-memory SQLite predicate probe |
| 8 | F08 | Medium | Forward update paths inconsistently enforce trusted revocation policy | Source plus Swift optional-binding probe |
| 9 | F09 | Medium | Credential repair accepts a recovery file with an extended ACL | Source plus in-memory Darwin ACL probe |
| 10 | F10 | Medium | Artifact manifest encoding does not uniquely bind the file set | Exact serialization collision reproduced in memory |
| 11 | F11 | Medium | Started local SSE failures omit the required terminal error | Handler and writer source; parser tests miss delivery behavior |
| 12 | F12 | Medium | Pricing metadata connections omit the public-address validation boundary | Missing enforcement confirmed; constrained SSRF is a runtime hypothesis |
| 13 | F13 | Medium | Local consumer negative transport coverage is overstated as conformant | Requirement, registry, test and existing evidence comparison |
| 14 | F14 | Low | Wallet audit persists a reversible challenge nonce | Direct field construction and audit write |
| 15 | F15 | Low | Local credential invalidation retains bytes and cannot reload a replacement | Custody lifecycle source; forwarding does stop |
| 16 | F16 | Low | Local model listing ignores upstream visibility | Handler and test explicitly implement allowlist-only listing |

Evidence means directly observed code, contracts, tests or probe output. Inference identifies consequences derived from that evidence. A runtime hypothesis is not represented as a reproduced exploit. Severity accounts for attacker prerequisites, feature flags and downstream defenses.

### F01: Case-Colliding Token Fields Bypass Gateway Limits

**Severity: High. Confidence: high in the semantic mismatch; end-to-end exploitation remains untested.**

**Affected paths:** `phase5-gateway/internal/router/chat_proxy.go:265`, `:289`, `:450`, `:599`, `:3401`; `phase5-gateway/internal/router/wallet_sessions.go:600`; `phase4-coordinator/internal/buyer/server.go:5232`, `:5333`, `:5338`; `phase4-coordinator/internal/routing/dispatch.go:54`; `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:58`; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:2466`.

**Authority:** [SPEC-006 configured request caps and admission](../specs/SPEC-006-buyer-api.md#L559), [SPEC-040 R004/R005](../specs/SPEC-040-wallet-native-buyer-sessions.md#L144).

**Evidence:** Gateway admission unmarshals into a Go struct. Go's documented case-insensitive matching processes object members in order. For the body below, gateway admission selects `1`, checks that value against its configured limit, and derives the reservation from it. The gateway forwards the original body. Coordinator validation and Swift request parsing instead read the exact lower-case `max_tokens` member, selecting `100000`. Coordinator's noncanonical/duplicate-field guard covers `model`, not `max_tokens`; its model rewrite preserves other fields. The Swift value is passed into generation.

```json
{"model":"llama","max_tokens":100000,"Max_tokens":1,"messages":[{"role":"user","content":"hi"}]}
```

**Scenario and limits:** An authenticated buyer, demo subject, or enabled wallet-session signer supplies both keys, requesting more generation than gateway/session admission authorized. A wallet signature binds the raw bytes but does not align their interpretation. Non-streaming generation does not have the gateway's incremental streaming cutoff. Model context, runtime and request-time limits still apply; final gateway usage is bounded by its reservation accounting. This finding is generation-cap bypass and unreserved compute exposure, not unlimited monetary debit. The complete malicious request was not executed against a running provider.

**Tests:** The fresh gateway suite and selected Swift parser tests pass. Targeted searches found no `Max_tokens`/`MAX_TOKENS` collision cases. Existing normal cap tests validate only one interpretation.

**Minimal fix slice:** Reject duplicates and noncanonical spellings of security-relevant request fields before reservation, using parser semantics shared with downstream consumers. Add a cross-service negative matrix for cap, stream and other accounting fields across API-key, demo and wallet modes. Prove that the malicious body causes zero provider dispatch.

### F02: Missing or Overridden Receipt Finality Can Finalize Buyer Debit

**Severity: High. Confidence: high for the explicit fallback; adapter trailer timing is a source-supported runtime hypothesis.**

**Affected paths:** `phase5-gateway/internal/router/chat_proxy.go:2215`, `:2270`, `:2295`, `:2314`, `:2572`, `:2601`; streaming early returns at `:1506`, `:1519`; `phase5-gateway/internal/router/anthropic_messages.go:1089`; `phase5-gateway/internal/router/responses.go:834`.

**Authority:** [SPEC-022 R-7.6/R-7.7](../specs/SPEC-022-verified-model-settlement.md#L608) supersede legacy fallback for covered enforce-mode traffic; [R-8.1](../specs/SPEC-022-verified-model-settlement.md#L624) requires verified finality before final buyer debit.

**Evidence:** When finality trailers were declared but absent, `settlementFinalityHold` with reason `missing_settlement_finality_trailer` calls `settleAfterCommit` with `unverified_streaming`. That path records and attempts a final settlement effect. Separately, `invalid_provider_response` overrides coordinator finality before the finality switch. The override is not limited to observe/legacy traffic.

**Scenario and limits:** Missing finality on covered enforce-mode traffic can finalize reported/estimated debit before receipt verification. The unconditional invalid-provider override also permits a debit despite pending/refund authority; that particular pending/quarantined combination was not dynamically reproduced. Positive provider credit or payout corruption was not demonstrated.

**Timing hypothesis:** The Messages and Responses adapters can set their terminal state at `[DONE]` and return before transport EOF populates HTTP trailers. Coordinator declares finality at `phase4-coordinator/internal/buyer/server.go:2509` and flushes stream data before terminal accounting. Delayed trailers could therefore trigger this fallback during otherwise healthy inference. The passing local raw-chat integration test does not reproduce or clear this adapter-specific condition.

**Tests:** `TestSPEC022GatewayStreamingSettlementTrailersControlBuyerDebit/declared-missing-trailer-settles-unverified` explicitly expects a settled row (`server_test.go:2440`). `TestAnthropicMessagesNonStreamingInvalidProviderResponseIgnoresVerifiedFinalityDebit` (`anthropic_messages_test.go:475`) and its streaming counterpart (`:1592`) assert that facade validation takes precedence. They test verified authority, not pending/quarantined negatives. All passed in the fresh gateway suite.

**Minimal fix slice:** Preserve the reservation hold whenever declared/enforce-mode finality is incomplete, and apply coordinator finality before facade outcome handling. Safely consume transport finality or reconcile asynchronously. Test delayed/missing trailers over actual HTTP for Chat, Messages and Responses, plus malformed provider output paired with pending, quarantined and zero-settled authority.

### F03: OAuth Handoffs Store Reusable API Keys in Plaintext

**Severity: High. Confidence: high.**

**Affected paths:** `phase5-gateway/internal/router/oauth.go:363`; `phase5-gateway/internal/storage/sqlite/store.go:372`, `:1097`, `:1126`, `:1133`; `phase5-gateway/cmd/gateway/main.go:353`; `phase5-gateway/README.md:13`.

**Authority:** [SPEC-006 sections 6.4/6.5](../specs/SPEC-006-buyer-api.md#L2057) prohibit full-key storage and require hash/HMAC storage.

**Evidence:** `redirectOAuthHandoff` inserts the full API key into `oauth_handoffs.api_key`. Consumption changes only `consumed_at`. The five-minute handoff expiry and periodic deletion neither revoke the API key nor remove copies already captured in WAL/snapshots/backups. Ordinary API-key storage otherwise uses hashes; the README's hash-only claim omits this exception.

**Scenario and limits:** A reader of a DB/WAL/backup containing a handoff row recovers an account bearer usable until API-key revocation, even after handoff consumption/expiry. Requires a configured OAuth return-to handoff and storage read compromise. No unauthenticated remote DB access or deployed filesystem exposure was established.

**Tests:** `TestOAuthHandoffFlowRoundTrip` (`internal/router/oauth_handoff_test.go:82`), `TestOAuthHandoffStoreConsumeReplay` (`internal/storage/sqlite/store_test.go:360`) and expiry/prune tests at `:382`/`:397` cover delivery/replay, not absence of plaintext bearer material. They passed.

**Minimal fix slice:** Persist a hashed one-time handoff and account/issuance intent; atomically consume that intent and mint the API key during exchange, retaining only its hash. Test database contents and concurrency. Address historical raw-key copies and any necessary revocation as a separately authorized operational step.

### F04: Ambiguous Local Sends Release Budget as Zero

**Severity: High. Confidence: high in classification and ledger behavior; medium in untested real-wire triggering details.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift:1343`, `:1353`, `:1365`, `:5667`, `:5885`, `:6021`.

**Authority:** [SPEC-045 R005/R007](../specs/SPEC-045-local-consumer-endpoint-mode.md#L141), [Phase 3 budget design](../specs/design/spec-045/BUILD_SPEC_045_PHASE_3_BUDGET_LEDGER.md#L60).

**Evidence:** Once `NWConnection.send` starts, both timeout and every send error become `preDispatchUnavailable`. Non-streaming and eligible streaming ledger branches settle that classification to zero; the error reports `forwarded_upstream=false`. The send-error helper even reclassifies an already-dispatched error. Streaming downstream disconnect or an already-started response is handled earlier and retains the admission estimate (`ConsumeCommand.swift:5869`, `:5997`).

**Scenario and limits:** An upstream send/callback error or send-deadline race occurs after bytes may have reached the gateway; for streaming, the downstream remains active and its response has not started. Restoring local admission capacity permits subsequent requests/client retries beyond the intended local spending ceiling. Ordinary streaming client disconnect is not a demonstrated zero-budget bypass, and no internal automatic retry was found. The unsafe classification and refund are proven by code/tests; a partial-send/reset or timeout race was not reproduced against a real TLS gateway.

**Tests:** `testPhase3DSendFailureIsPreDispatch` (`ConsumeCommandTests.swift:1651`) explicitly blesses the reclassification; `testPhase3DPreDispatchTransportFailureSettlesReservationToZero` (`:1594`) verifies zero settlement. Both were included in the passing Swift run.

**Minimal fix slice:** Treat failure after send begins as ambiguous/dispatched and conservatively retain exposure; reserve zero settlement for demonstrably pre-send failures. Add partial-send/reset and timeout-race tests for both transports, including the next request's budget admission and recovery after restart.

### F05: Wallet Receipt Access Omits Signed, Session-Scoped Admission

**Severity: Medium. Confidence: high in the gateway authorization omission; full HTTP reproduction unrun.**

**Affected paths:** `phase5-gateway/internal/router/receipts.go:36`, `:47`, `:75`, `:89`; `internal/router/auth_helpers.go:134`; `internal/router/wallet_sessions.go:495`; `internal/auth/wallet.go:370`, all under `phase5-gateway/`.

**Authority:** [SPEC-040 R005](../specs/SPEC-040-wallet-native-buyer-sessions.md#L160) requires signatures for session-authenticated HTTP requests; [R008](../specs/SPEC-040-wallet-native-buyer-sessions.md#L249) restricts self-service scope.

**Evidence:** The receipt route accepts a valid `mps_` bearer through `authenticateAny`, extracts only its account ID, and queries coordinator receipts without session identity. It never requires the Ed25519 request signature, inserts replay admission, checks request/session membership, or rechecks account status. The wallet semantic-header profiles have no receipt route. Session revocation/expiry checks still apply to the bearer.

**Scenario and limits:** Possession of an active session bearer without its signing key can retrieve a known request's receipt from the same account, including requests outside that session. A still-active session on a blocked account also lacks the account recheck on this path. Knowledge of a request ID and enabled sessions are prerequisites; this is account-bounded receipt metadata exposure, not another account's data or inference-spend bypass.

**Tests:** `TestBuyerReceiptRetrievalAuthAndRedaction` (`phase5-gateway/internal/router/receipts_test.go:13`) covers buyer/operator/demo behavior and redaction, not unsigned wallet, blocked account or cross-session receipt access.

**Minimal fix slice:** Reject wallet-session bearers on receipts until an explicit signed, replay-protected, session-scoped receipt contract exists; alternatively implement that complete contract and its negative tests. Do not merely add a signature while preserving account-wide authority.

### F06: Wallet Inference Ignores Replay Storage Ceilings

**Severity: Medium. Confidence: high.**

**Affected paths:** `phase5-gateway/internal/storage/sqlite/store.go:2007`, `:2048`, contrasted with `:2139`; `phase5-gateway/internal/storage/types.go:301`; `phase5-gateway/internal/router/wallet_sessions.go:610`.

**Authority:** [SPEC-040 R010](../specs/SPEC-040-wallet-native-buyer-sessions.md#L303) requires hard per-session replay record/byte limits.

**Evidence:** Inference admission inserts replay material without checking the configured ceiling. Its admission request type lacks ceiling inputs; only metadata admission checks them. Duplicate/mismatch and token-cap transactions do exist.

**Scenario and limits:** An enabled, validly signed session can continue adding records after its configured replay ceiling through small or refunded inference attempts. Token caps do not bound refunded attempts. The growing history also expands later exposure-query work. Rate/time/resource controls still apply; disk exhaustion was not reproduced. No wallet replay/session/challenge pruning implementation was found in this pass.

**Tests:** `TestWalletReplayDuplicateAndMismatchDoNotReserveAgain` (`wallet_session_test.go:261`) and cap concurrency tests (`:577`) cover identity/token exposure. `TestWalletMetadataRateLimitAndReplayCeiling` (`:286`) checks only metadata capacity. Paths are under `phase5-gateway/internal/storage/sqlite/`; all passed.

**Minimal fix slice:** Pass limits into serialized inference admission and enforce them before insertion, preserving duplicate/mismatch precedence. Test at-cap inference and refunded-attempt accumulation. Plan retention-safe pruning separately so it cannot reopen replay.

### F07: Metadata Throttling Can Be Multiplied by Session or IP

**Severity: Medium. Confidence: high, including a query-level reproduction.**

**Affected paths:** `phase5-gateway/internal/storage/sqlite/store.go:2150`; `phase5-gateway/internal/config/config.go:373`.

**Authority:** [SPEC-040 R005](../specs/SPEC-040-wallet-native-buyer-sessions.md#L212) and [R010](../specs/SPEC-040-wallet-native-buyer-sessions.md#L307).

**Evidence:** The count predicate is `session_id = ? AND metadata_client_ip = ?`. It does not enforce independent session, account and IP limits. The exact predicate over an in-memory fixture returned `2` for the original pair, `0` for a new IP, and `0` for a new session.

**Scenario and limits:** A valid buyer cycles its sessions from one IP, or one session through several egress IPs, multiplying the configured 120/minute metadata limit. Defaults allow 100 active sessions/account and 60 issuances/hour. These budget-free requests perform serialized replay writes and can fetch model metadata upstream. Enabled wallet sessions and signing keys are required; this is bounded resource amplification, not an unauthenticated flood claim.

**Tests:** `TestWalletMetadataRateLimitAndReplayCeiling` (`phase5-gateway/internal/storage/sqlite/wallet_session_test.go:286`) verifies the same pair. Its new-IP case increases the rate limit and tests capacity instead, missing the bypass.

**Minimal fix slice:** Check independent session, account and normalized-IP counts in the existing admission transaction, with appropriate indexes and tests changing each dimension independently.

### F08: Forward Updates Inconsistently Enforce Revocation Policy

**Severity: Medium. Confidence: high in control flow; exploitability requires conflicting trusted policy and release metadata.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:213`, `:493`, `:632`; `AutoUpdateMarker.swift:2448`, `:2456`; `SignedReleaseDiscovery.swift:97`; `SelfUpdate.swift:167`, `:194`, `:888`; `MacProviderCLI.swift:3125`, all CLI paths.

**Authority:** [SPEC-020 R002](../specs/SPEC-020-provider-autoupdate.md#L398) retains policy checks on recovery; [R-2.2](../specs/SPEC-020-provider-autoupdate.md#L452) requires revocation independently of a minimum.

**Evidence:** Both automatic rails use `if let minimum = policy.minimum, belowMinimum || revoked`; a nil minimum skips revocation. The effective policy allows that state. An equivalent Swift probe printed `NIL_MINIMUM_REVOKED_REJECTED false`. Separately, manual `SelfUpdate.run` persists discovery policy, compares only installed/target version, and reaches activation without checking the effective minimum/revocations. Rollback has independent policy enforcement.

**Scenario and limits:** Automatic update can select a revoked but correctly signed newer target when no floor exists. Manual update can bypass a persisted restriction when a valid signed discovery target conflicts with it. Attackers cannot manufacture release signatures; no real installation, public-feed manipulation or deployed policy inconsistency was tested.

**Tests:** `testHandleCoordinatorRecommendationReturnsForwardProgressFailureOnBelowMinimum` (`AutoUpdateTests.swift:3543`) uses a nonnil floor. Signed discovery, monotonic policy, replay and equivocation tests pass but do not cover nil-floor revocation or manual activation against persisted restrictions.

**Minimal fix slice:** Use one forward-target policy validator for both automatic rails and manual update, evaluating revocation independently of the optional floor before preparation and activation. Test refusal before download/drain/swap.

### F09: Credential Repair Accepts Extended ACL Recovery Sources

**Severity: Medium. Confidence: high, including an in-memory Darwin API reproduction.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/CredentialsCommand.swift:488`, `:528`, `:580`; correct sibling check at `ProviderCredentialStore.swift:628`.

**Authority:** [SPEC-001 protected-source repair](../specs/SPEC-001-phase3-binary.md#L1074); explicit rejection contract at `CredentialsCommand.swift:396`.

**Evidence:** The repair validator treats `acl_get_entry` returning zero as evidence of no ACL, without inspecting the returned entry. Darwin returns zero for successful retrieval. In-memory calls produced `ACL 0 0 True`: creation succeeded, retrieval succeeded, and an entry was present. Repair then imports the source into missing/corrupt authoritative custody.

**Scenario and limits:** An owner-owned 0600 config has an ACL granting another principal write access, authoritative custody is missing/corrupt, and operator/app repair runs. The command accepts attacker-writable recovery material as protected. Existing read exposure from a permissive ACL is not newly caused by repair.

**Tests:** `testCredentialRepairRejectsUnprotectedOrSymlinkedSource` (`ProviderCredentialStoreTests.swift:514`) covers 0644, symlink and hardlink, not a nonempty ACL. The test helper itself correctly checks entry absence at `:904`. Existing tests pass.

**Minimal fix slice:** Reject a nonnil ACL entry and preserve error handling; add a nonempty ACL fixture proving refusal before any authoritative-store mutation.

### F10: Artifact Digest Encoding Permits Different File Sets

**Severity: Medium. Confidence: high in encoding collision; bounded impact.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:3469`, `:4243`, `:4274`; `DurableModelArtifactStore.swift:100`, `:111`; `ModelRuntime.swift:1113`, `:1415`.

**Authority:** [SPEC-023 section 3.2](../specs/SPEC-023-installer-autotune-recommend.md#L359) defines the ambiguous encoding; it delegates identity meaning to SPEC-010 section 3.7. This is both a normative and implementation gap.

**Evidence:** Entries serialize as unescaped `path LF size LF SHA LF`. Accepted filenames may contain LF. Replacing separate `LICENSE` and `config.json` entries with one filename containing the first entry's serialized size/hash and the second name creates identical manifest bytes and SHA-256 for a different file set. The in-memory exact-encoding probe printed `MANIFEST True True True 87`; the injected filename is 87 bytes. No cryptographic hash collision or signing key is needed.

**Scenario and limits:** An attacker controls a snapshot/cache directory presented to verification. Exact file-set identity can be bypassed. Arbitrary replacement of existing weight contents, successful inference with substituted weights, and code execution were not demonstrated; later loading may fail because a required ordinary filename is missing.

**Tests:** Existing `testModelArtifactHashRejectsSymlinkAndHardlink`, `testModelArtifactHashIsDeterministicForSameFiles`, `testModelArtifactHashIncludesHiddenFiles`, and `testCachedArtifactResolverRequiresExactRevisionAndHash` in `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift` do not cover delimiter injection. Those artifact-specific tests were inspected, not run in this session.

**Minimal fix slice:** Amend the normative path grammar to reject LF/control characters and enforce it before download writes and hashing. This can preserve current normal-path digest bytes. Add the collision regression; a different length-prefixed encoding would require explicit migration.

### F11: Started Local SSE Failures Omit a Terminal Error

**Severity: Medium. Confidence: high in wire-writing logic; client SDK behavior untested.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift:5502`, `:5868`, `:5909`, `:6587`.

**Authority:** [SPEC-045 R007/R008](../specs/SPEC-045-local-consumer-endpoint-mode.md#L157), [Phase 2 proxy-safety design](../specs/design/spec-045/BUILD_SPEC_045_PHASE_2_PROXY_SAFETY.md#L72).

**Evidence:** After the local response starts, upstream failure calls `writeStreamingEnd`, which writes a normal HTTP end and closes without the required redacted terminal SSE error. Both ledger and no-ledger paths do so. The ledger path can still settle conservatively; the defect is client-visible failure signaling.

**Scenario and limits:** A reset, missing DONE marker or malformed later event follows valid SSE data. A connected client sees partial data followed by normal HTTP completion, without the required error code. Some clients independently require a terminal marker; no claim is made that every SDK reports success.

**Tests:** `testPhase3IStreamingParserRejectsMalformedBodyAfterHead` (`ConsumeCommandTests.swift:3896`) checks the parser, and `testPhase3IStreamingSSEHeadAndEventsEmitBeforeUpstreamCompletion` (`:4386`) checks early delivery. Neither checks terminal-error emission by both handlers. They passed.

**Minimal fix slice:** Emit exactly one redacted terminal SSE error when the local client remains writable, then end. Preserve conservative exposure and suppress writes after local disconnect. Cover both ledger modes.

### F12: Pricing Metadata Omits Per-Connection Address Validation

**Severity: Medium. Confidence: high in missing enforcement; constrained SSRF remains an untested runtime hypothesis.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift:89`, `:3191`; `phase3-binary/Sources/macprovider-cli/ConsumeTrustedPricing.swift:233`, `:237`, `:252`.

**Authority:** [SPEC-045 R003](../specs/SPEC-045-local-consumer-endpoint-mode.md#L125), [Phase 2 upstream boundary](../specs/design/spec-045/BUILD_SPEC_045_PHASE_2_PROXY_SAFETY.md#L49).

**Evidence:** After startup DNS validation, pricing GETs use fresh hostname-based URLSession connections, without repeated global-IP validation, validated-IP connection or connected-peer validation. The chat transport separately resolves, validates and pins; this finding does not apply to its connection path.

**Runtime hypothesis and limits:** An operator-configured attacker-controlled hostname passes public DNS at startup then resolves privately for pricing. A successful HTTPS GET additionally requires a trusted certificate for that hostname on the reachable private endpoint. Even a failed TLS attempt may connect to a prohibited address. These GETs carry no buyer Authorization, use only fixed rate-card/sidecar paths, refuse redirects and require a trusted pricing signature. Buyer credential exfiltration, arbitrary-path SSRF and unsigned-pricing admission were not demonstrated.

**Tests:** `testLoaderFetchesCanonicalEndpointsAndFailsClosedWithoutFallback` (`ConsumeTrustedPricingTests.swift:88`) injects a fetch closure; `testDefaultFetchRejectsUnboundedHeadersStatusAndOversizedMetadata` (`:119`) injects URLProtocol. Both pass but bypass real DNS/peer selection.

**Minimal fix slice:** Apply validated/pinned metadata connections with normal hostname verification and no buyer credentials. First reproduce public-to-private resolution changes for the body and signature fetch independently.

### F13: Required Negative Transport Coverage Is Marked Conformant

**Severity: Medium. Confidence: high. This is an assurance finding, not an additional proven exploit.**

**Affected paths:** `specs/CONFORMANCE.json:7013`, `:7046`; `phase3-binary/Tests/macprovider-cliTests/ConsumeCommandTests.swift:63`, `:103`, `:110`, `:4721`, `:4767`; `ConsumeConformanceJourneyTests.swift:8`, `:93`, `:159`.

**Authority:** [SPEC-045 R008](../specs/SPEC-045-local-consumer-endpoint-mode.md#L163), [Phase 4 conformance design](../specs/design/spec-045/BUILD_SPEC_045_PHASE_4_CONFORMANCE_JOURNEY.md#L22).

**Evidence:** R008 is marked conformant with its gap cleared, although mandatory negative TLS, repeated-DNS, connected-peer, proxy and redirect credential-boundary tests are not established by the cited tests. Fake-gateway forwarding replaces the production pinned transport with a client returning synthetic responses and public resolver results. Pinned-client tests exercise byte/parser helpers. The real socket fixture calls itself through URLSession; its local-endpoint scenario intentionally rejects before dispatch and verifies zero gateway requests.

Existing signed Aug-24 evidence at `journeys/evidence/local-consumer-endpoint-20260824T060103Z.redacted.json:151` covers SDK chat, budget, restart and redaction observations, not that negative transport matrix. It was read, not recreated.

**Scenario:** Review/release decisions may treat real credential-egress rejection as proven while actual transport regressions remain outside tested paths. Passing injected tests cannot establish absence of credential bytes at a forbidden real endpoint.

**Tests:** All selected existing Consume tests pass. The gap is the absent real transport matrix, not a failing unit test.

**Minimal fix slice:** Add adversarial tests that execute the production transport and measure zero credential bytes at prohibited endpoints. Until that evidence exists, correct the R008 conformance claim. Do not create new signed acceptance evidence merely to silence the registry gap.

### F14: Audit Rows Reveal the Wallet Challenge Nonce

**Severity: Low. Confidence: high.**

**Affected paths:** `phase5-gateway/internal/router/wallet_sessions.go:129`, `:157`; `phase5-gateway/internal/storage/sqlite/migrate.go:423`.

**Authority:** [SPEC-040 R001](../specs/SPEC-040-wallet-native-buyer-sessions.md#L111) requires storing only a nonce hash.

**Evidence/scenario:** `challenge_id = "wch_" + nonce` is written into durable append-only audit data. An audit reader can reverse that construction. The nonce alone cannot mint a session without account authentication and the wallet signature.

**Tests/gap:** Registration tests cover signatures, expiry and one-time consumption but do not assert absence of the nonce or reversible encodings in audit payloads.

**Minimal fix slice:** Generate an independent opaque challenge ID and bind it to the challenge; test audit payload redaction. Confidence is high; severity remains Low because the other authorization factors are intact.

### F15: Local Credential Replacement and Invalidation Lifecycle Is Incomplete

**Severity: Low. Confidence: high.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift:3509`, `:4199`.

**Authority:** [SPEC-045 R003](../specs/SPEC-045-local-consumer-endpoint-mode.md#L129), [R008 lifecycle coverage](../specs/SPEC-045-local-consumer-endpoint-mode.md#L163).

**Evidence/scenario:** Immutable credential identity/custody never reloads a valid replacement. Invalidation reports missing but retains cached bytes until deinit. Deletion does prevent later forwarding, so no reachable authentication bypass was found. Rotation needs restart, and invalidated bytes remain longer than the intended lifecycle.

**Tests:** `testCredentialFileRejectsExtendedACLAndRevalidatesDeletion` (`ConsumeCommandTests.swift:432`) verifies invalid status, not valid replacement reload or buffer clearing.

**Minimal fix slice:** Define and test controlled revalidation/reload and best-effort clearing of owned buffers on invalidation. Avoid claiming language/runtime-wide secret erasure.

### F16: Local Model Listing Uses Only the Operator Allowlist

**Severity: Low. Confidence: high.**

**Affected paths:** `phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift:6396`; `phase3-binary/Tests/macprovider-cliTests/ConsumeCommandTests.swift:5649`.

**Authority:** [SPEC-045 R002](../specs/SPEC-045-local-consumer-endpoint-mode.md#L117) requires upstream-visibility filtering.

**Evidence/scenario:** The local handler fabricates entries from the configured allowlist without intersecting upstream visibility. An allowed but unavailable/unauthorized model can be advertised to the caller. Gateway admission remains authoritative, so no access escalation was established.

**Tests:** `testPhase2ModelsReturnsOnlyLocalAllowlistEntries` explicitly pins the current behavior and passed.

**Minimal fix slice:** Intersect trusted upstream-visible IDs with the local allowlist, with a bounded, fail-closed visibility policy and tests for unavailable/unauthorized entries.

## Scope and Exclusions

The primary review covered `phase3-binary/Sources/macprovider-cli/`, its XCTest suites, gateway router/auth/storage/config/startup and README. Connected `MacProviderCore` parsers, phase3 app diagnostics, gateway settlement journal, coordinator validation/routing/finality and the local integration harness were read where necessary to close a call chain. Relevant authority/conformance indexes, normative specs and design prompts were compared.

This was a broad boundary audit, not an exhaustive line-by-line review of all ML kernels, platform frameworks, dependency internals, installer/release infrastructure or coordinator services. The complete Malibu Xcode app, release packaging/notarization and production deployment were not audited. No `d-inference` source was inspected. No secrets, Keychain items, payout material, real wallets or production configurations were accessed. Existing public/redacted evidence was used only for scope assessment.

The report addresses the pinned commit. Other active worktrees/branches and subsequent upstream changes were not used as fixes or evidence of the audited state.

## Boundary Map

The following map records authority, entrypoint, attacker-controlled material, failure behavior and evidence. Referenced test names in findings resolve under their stated module.

| Boundary and owner | Code path | Inputs / authority crossing | Existing coverage | Observed disposition |
|---|---|---|---|---|
| Local consumer auth: SPEC-045 R001/R003 | `ConsumeCommand.swift:3440,4744` | Local caller headers/token/origin into buyer-credential access | Consume ambiguous-auth, header, origin, ACL/deletion tests | Keyed bearer check and bounded admission fail closed; F15 lifecycle gap |
| Local HTTP parsing: SPEC-045 R002/R008 | `ConsumeCommand.swift:4816,4910,5002,2042` | Raw request line/framing/JSON/path/encoding | Raw NIO pipeline, duplicate/depth/framing/resource vectors | Fixed endpoint and generated headers; no arbitrary-path forwarding found |
| CLI upstream chat: SPEC-045 R003 | `ConsumeCommand.swift:1118,1178,1182,1307` | Operator origin, DNS answers, TLS peer, network errors | Origin/address tests, injected client and parser tests | Public-IP resolve/pin and hostname TLS present; F04 and F13 qualify assurance |
| Pricing trust: SPEC-045 R003/R004, SPEC-023 | `ConsumeTrustedPricing.swift:193,233,296` | Metadata endpoint plus signed rate-card bytes | Signature, freshness, policy, status/header/size cases | Signature/estimate admission fails closed; address-policy gap F12 |
| Local budget/persistence: SPEC-045 R004/R005 | `ConsumeCommand.swift:2228,2679,2868,2913,5320` | Concurrent requests, restart, replaced files, incomplete settlement | Lock, inode, replay/recovery, concurrent budget and saturation cases | Durable conservative ledger ordinarily; ambiguous send exception F04 |
| Local SSE: SPEC-045 R002/R007 | `ConsumeCommand.swift:835,1509,5502,5909` | Untrusted headers/chunks/compression/termination | Incremental parser and resource accounting tests | Size/decoded bounds present; missing terminal error F11 |
| Provider local HTTP: SPEC-001 | `HTTPServer.swift:199,347,492,819` | Same-host callers/browser-origin requests | Browser content-type/origin negatives and HTTP request suites | Loopback bind, body cap, browser POST checks; host/rebinding hypothesis remains |
| Coordinator/Tier-2: SPEC-002/SPEC-008 | `CoordinatorClient.swift:21,469,481,1726`; `InferenceRelay.swift:80,102,107,141` | Authenticated coordinator frames and encrypted request bindings | Coordinator host tests, Tier-2 AAD/replay and relay tests | No plaintext fallback; duplicate/cap/body gates. Inbox lacks a global bound |
| Local control: SPEC-025/SPEC-035 | `ControlSocket.swift:1172,1205,1323,2003` | Local socket peer and framed commands | ControlSocket/metrics/status tests inspected | Private permissions, same-EUID authorization, 64-KiB frames |
| Provider custody/repair: SPEC-001/SPEC-003 | `ProviderCredentialStore.swift:319,378,525,936`; `CredentialsCommand.swift:528` | Config/file/Keychain state into authoritative bearer | 32 selected custody tests passed | Main backend fails closed on unsafe files; repair ACL exception F09 |
| Updates: SPEC-020 R002 | `SelfUpdate.swift:328,515,2050,2216`; `AutoUpdater.swift:213,493` | Release discovery/archive/signatures and persisted policy | Five selected discovery/policy tests passed | Signature/integrity chain present; forward-policy gaps F08 |
| BYOM/model identity: SPEC-046/SPEC-047, SPEC-023 | `BYOMDiscovery.swift:1905,1918,1932,3299`; `AutotuneRecommend.swift:4274` | Local adapter URL/response, candidate package, snapshot filenames | Real loopback BYOM negatives inspected; admission tests selected | Loopback/redirect/schema/tuple gates; manifest flaw F10 |
| Gateway API-key/OAuth: SPEC-006 | `auth/keys.go:38`; `router/oauth.go:17,363`; `storage/sqlite/store.go:1058` | OAuth state/callback, bearer and handoff | OAuth replay/CSRF/allowlist/revoke tests | State bound/atomically consumed; plaintext custody exception F03 |
| Wallet auth/replay/caps: SPEC-040 | `router/wallet_sessions.go:77,408,495,600`; `storage/sqlite/store.go:1708,2007,2112,2268` | Account bearer, wallet proof, session signature, IDs/IPs | Challenge race, replay mismatch, revocation fence and cap tests | Main signed routes fail closed; F05-F07/F14 |
| Relay-blind admission: SPEC-041 | `router/relay_blind.go:455,572,634`; `storage/sqlite/store.go:2166` | Required envelope, key bindings, nonce/replay metadata | Disabled, malformed, duplicate, freshness, quota-zero and redaction tests | Default-off; canonical requests reject before execution; successful decryption deferred |
| Gateway routing/normalization: SPEC-006/SPEC-042 | `router/chat_proxy.go:265,283,599`; `router/pool_selection.go`; `router/headers.go` | Buyer JSON, pool selector, internal-looking headers | Pool authorization/freshness and forwarding tests | Pool admission/internal headers fail closed; F01 parsing differential |
| Settlement/receipt authority: SPEC-022/SPEC-040 | `router/chat_proxy.go:2270`; `router/settlement_reconcile.go`; `settlement/journal/journal.go`; `router/receipts.go:19` | Provider output, coordinator finality, durable effects, receipt IDs | Gateway race suite and local raw-chat reconcile integration | Journal/idempotency present; authority exception F02 and receipt exception F05 |
| SQLite/config/startup: SPEC-006/SPEC-040/SPEC-042 | `storage/sqlite/store.go:35`; `config/config.go:556`; `phase5-gateway/cmd/gateway/main.go:42` | Config secrets/flags, existing DB schemas, concurrent writers | Migration, transaction hygiene, config and startup tests | Future-schema rejection, serialized writes/query-only reads, missing-secret failures |
| Diagnostics/admin/browser: SPEC-035/SPEC-006/SPEC-007 | `DoctorCommand.swift:854,1017`; `EgressPerfTrace.swift:148`; `router/auth_helpers.go:17`; `router/cors.go:32`; `router/pages.go:77` | Logs, status, errors, browser requests and operator bearer | Redaction/perf tests selected; bundle/admin/CORS suites inspected | No confirmed bearer leak or operator bypass; runtime bundle/Keychain limits below |

Swift filenames in this map are in CLI Sources unless a different module is named; abbreviated gateway filenames are under `phase5-gateway/internal/`. The findings provide full paths and the audit SHA fixes all line references.

Relevant build/design owners include [SPEC-040 implementation](../specs/design/spec-040/BUILD_SPEC_040_WALLET_NATIVE_BUYER_SESSIONS_IMPL.md), [SPEC-041 implementation](../specs/design/spec-041/BUILD_SPEC_041_RELAY_BLIND_REQUEST_ENCRYPTION_IMPL.md), [SPEC-045 proxy safety](../specs/design/spec-045/BUILD_SPEC_045_PHASE_2_PROXY_SAFETY.md), [SPEC-045 forwarding/settlement](../specs/design/spec-045/BUILD_SPEC_045_PHASE_3D_UPSTREAM_FORWARDING_SETTLEMENT.md), [SPEC-045 SSE relay](../specs/design/spec-045/BUILD_SPEC_045_PHASE_3I_INCREMENTAL_SSE_RELAY.md), and [SPEC-042 gateway pool authorization](../docs/design/spec-042-v0.1-slice-gateway-pool-auth.md).

## Important No-Finding Notes

- The main protected-file credential backend uses descriptor-relative/no-follow access, owner/mode/link/ACL checks, private directories, locking and durable atomic writes. No additional cross-user custody bypass was established beyond repair F09.
- Chat egress separates local and upstream Authorization, reconstructs allowed headers, rejects non-public resolution, pins the connection address and verifies the original TLS hostname. Redirect, proxy and DNS negative-test limitations remain F13; static inspection is not wire proof.
- Local parsing rejects tested duplicate/deep JSON, ambiguous framing and unsafe targets; compressed SSE is rejected and decoded non-streaming response bounds exist. The suspected unbounded subsequent-pipelined-URI issue was rejected after inspecting SwiftNIO's URL/header-byte bound and read backpressure.
- Local ledger locking, durable reservation transitions, file-identity checks and restart recovery have substantive coverage. Missing usage ordinarily holds conservatively. These controls do not compensate for the incorrect send classification.
- Wallet registration atomically consumes bound challenges; active-session caps, replay mismatch/duplicate handling, account-scoped management and dispatch revocation fencing are present. Receipt and resource-control exceptions are separately ranked.
- Canonical relay-blind required envelopes are rejected before quota/dispatch when unavailable. The code does not implement successful provider key ingestion/decryption, and the registry keeps those requirements pending. Tier-2 coordinator encryption is not equivalent to SPEC-041 relay blindness. No canonical required-envelope plaintext downgrade, provider-private claim, or completion-private claim was established.
- BYOM probes use literal loopback, bounded streaming reads, no ambient cookies/proxies and redirect refusal. Candidate status/withdrawal responses bind the expected tuple and closed schema; candidate discovery is not earning authority.
- Pool selection checks account authorization and capability freshness before quota; wallet/demo pool selection fails closed. Buyer-supplied internal authority headers are reconstructed.
- Gateway settlement journaling, payload-aware idempotency and recovery have coverage. The journal can intentionally continue settlement after its own write failure (`chat_proxy.go:2615`), so recovery coverage is conditional on successful journaling; this audit did not establish an additional invariant violation in that documented branch.
- Signed release discovery, signed checksums, artifact binding, CLI/app signing identity and embedded binary identity checks are present. No signature forgery/archive execution bypass was established. Revocation-policy enforcement remains F08.
- Doctor/status/performance output inspected did not reveal a confirmed bearer leak. App diagnostics have redaction and symlink tests, but the complete app test suite and live support-bundle creation were not run.
- Gateway secret resolution fails closed, normal API-key revocation is account-scoped, OAuth state is cookie-bound and atomically consumed, CORS uses an allowlist, and operator/admin routes require operator authority.
- Wallet sessions and relay-blind execution are default-off; disabled-session rejection has tests. README/AC_STATUS generally distinguish local tests from pending live evidence. SPEC-045's rollup remains pending/not-deployed despite conformant child rows, while SPEC-046/047 mappings lag implemented local tests; those stale rollups do not establish deployment.

## Unresolved Hypotheses

These observations are not additional ranked vulnerabilities.

| Hypothesis | Evidence and prerequisites | Focused reproduction / disposition |
|---|---|---|
| Facade completion precedes finality trailers | Early returns in F02; requires delayed trailer delivery | Real HTTP fixture that flushes DONE, delays verified/pending/quarantined trailers, and inspects debit before/after EOF |
| Slow upstream headers retain local capacity | `ConsumeCommand.swift:1401,1472` refreshes a 30-second timer on bytes, including partial headers | Drip incomplete headers below byte limits and measure an absolute header deadline; clarify whether SPEC-045's header deadline applies independently to upstream |
| API-key ambiguity differs from wallet fencing | `chat_proxy.go:703,921` refund ordinary quota on transport/read failure | Trace real coordinator credited work versus intentional no-delivered-output refund before asserting a financial defect |
| Mixed-case relay sentinels escape exact scanning | `relay_blind.go:485` scans exact lower-case keys, while struct decoding is case-insensitive | Reject/trace malformed mixed-case envelopes across adapters. No valid canonical encrypted payload was shown to disclose plaintext |
| Provider status DNS rebinding | Local GET status lacks the POST Origin gate/Host allowlist | Browser-based DNS-rebinding test, including private-network access enforcement. No browser exploit reproduced |
| Coordinator-driven resource exhaustion | Unbounded inbox at `CoordinatorClient.swift:1858`; some BYOM admission responses buffer before size checks at `BYOMDiscovery.swift:1589,1627` | Requires hostile configured/authenticated coordinator; establish buyer reachability before escalating severity |
| Legacy filesystem hardening gaps | Some serve-lock/KV/SE-handle/SQLite creation relies on namespace protection, owner or umask | Cross-principal ACL/symlink/race tests in isolated fixtures. No default cross-user secret exposure established |

## Next Three Implementation PRs

F01-F03 take priority because they affect shared gateway admission, financial finality and reusable credentials. F04 affects the opt-in local consumer, and its real-wire trigger remains untested; it should follow immediately, not be treated as low priority.

1. **Align gateway request admission semantics (F01).** Make cap/accounting interpretation identical across gateway, coordinator and provider before any reservation/dispatch. Include API-key/demo/wallet negative cases and exact raw-body evidence proving zero dispatch for collisions. Keep this independent of the settlement-policy change.
2. **Preserve coordinator receipt authority through gateway finality (F02).** Remove covered enforce-mode fallback debit, retain/reconcile holds, and test real delayed/missing trailers and facade-invalid output across all three endpoint families. Demonstrate no final debit until verified and correct quarantine/zero-settled refund.
3. **Remove reusable OAuth keys from handoff storage (F03).** Consume an issuance intent and mint only at exchange, with transactional one-time behavior and hash-only persistence tests. Document historical-copy remediation as an operational follow-up, without using production credentials in implementation tests.

Immediately following these: F04 local ambiguous-send accounting with real transport fault fixtures. Then combine the related wallet resource controls F06/F07, address F05 signed receipt admission, and implement the bounded CLI policy/custody/identity corrections F08-F12. Correct conformance evidence F13 as part of the relevant transport-testing slice. No implementation was performed in this session.

## Commands and Verification Results

All test commands below used the audit worktree. Test-generated caches/artifacts were temporary; no test source was added.

### Startup and Pin

From `/Users/augstar/macprovider-poc`:

```bash
git status -sb
git worktree list
sed -n '1,240p' AGENTS.md
sed -n '1,240p' CLAUDE.md
git fetch --prune origin
git rev-parse origin/main
git worktree add /Users/augstar/.codex/worktrees/macprovider/security-boundary-audit-2026-09-07 -b codex/security-boundary-audit-2026-09-07 origin/main
```

All succeeded. Startup status was clean `## main...origin/main`; fetch emitted no changes; the SHA was `afe6b12e1872aa7d2ddd94817120d37a77f31c0f`. `git rev-parse HEAD` in the fresh worktree returned the same SHA. Existing worktrees were inventoried and left untouched.

Targeted `rg`, `sed`, `nl` and structured JSON/source reads supplied the cited evidence. A speculative lookup of `phase4-coordinator/internal/buyer/validation.go` found no file; the actual validation was then located in `server.go`. No test failure was hidden by that lookup.

### Gateway

Working directory: `phase5-gateway/`.

```bash
go version
go test -race -count=1 -timeout 5m ./...
go vet ./...
```

- Module-selected toolchain: `go1.26.6 darwin/arm64` (the root default reported 1.26.4 before module selection).
- Race suite: exit 0. `cmd/gateway` 3.656s; `internal/auth` 2.820s; `internal/config` 2.252s; `internal/router` 208.216s; `internal/settlement/journal` 1.588s; `internal/spec015contract` 2.696s; `internal/storage/sqlite` 18.404s. `internal/storage` reported no test files.
- `go vet ./...`: exit 0, no output.
- Source contains intentional coordinator-owned seam skips in `internal/router/seam_harness_test.go:367,376`; package success is not a claim that those skipped scenarios executed.

### Swift

Toolchain: Apple Swift 6.3.3, target `arm64-apple-macosx26.0`. Working directory: `phase3-binary/`.

```bash
swift test --scratch-path /tmp/macprovider-security-audit-20260907-swift-build --disable-automatic-resolution --filter 'ConsumeCommandTests|ConsumeTrustedPricingTests|ProviderCredentialStoreTests|InferenceRelayTests|HFRedirectGuardTests|CoordinatorHostValidationTests|BYOMAdmissionTests|StrictJSONParserDepthTests'
```

Exit 0: **211 XCTest tests, 0 failures, 0 unexpected**, 0.799s selected-test execution after the isolated build. The separate Swift Testing runner discovered 0 tests; that does not replace the XCTest count. Dependency/build warnings were emitted; this audit does not claim a warning-free build.

```bash
swift test --skip-build --scratch-path /tmp/macprovider-security-audit-20260907-swift-build --disable-automatic-resolution --filter 'EgressPerfTraceTests|ProviderServeLockTests|AutotuneDBTests|KVDiskCacheFormatTests|testSignedReleaseDiscoveryVerifiesSignatureExpiryAndTamperResistance|testDiscoveryStateRejectsReplayAndEquivocationBeforeMutation|testSignedPolicyPersistenceIsMonotonic|testUnsignedReleasePolicyMetadataIsIgnored|testHandleCoordinatorRecommendationReturnsForwardProgressFailureOnBelowMinimum|testDoctorReportRedactsLogsByConstruction'
```

Exit 0: **72 XCTest tests, 0 failures, 0 unexpected**, 1.020s. Suites: AutoUpdate 5; AutotuneDB 4; Doctor 1; EgressPerfTrace 12; KVDiskCacheFormat 45; ProviderServeLock 5. Total selected Swift tests across both runs: **283**.

### Local Cross-Service Checks

Working directory: `test/integration/`.

```bash
go test -race -count=1 -timeout 5m -run '^(TestSpec022V04StreamingSettlementReconcilerE2E|TestInternalBearerWrongTokenRejected|TestInternalBearerNoAuthRejected|TestInternalBearerServiceTokenAccepted|TestInternalBearerOperatorKeyRejectedPostCutover|TestStickyHeaderForwardedToCoordinator|TestGatewayGitHubOAuthDisabledRoutesReturn404)$' .
```

Exit 0: `github.com/augstar/macprovider-integration`, 9.292s, seven selected tests. Harness builds local coordinator/gateway binaries and uses synthetic fixtures. No signed journey test was selected or created. This validates ordinary raw-chat finality, internal bearer separation, header forwarding and disabled OAuth; it does not reproduce F01 or adapter trailer timing.

### In-Memory Probes

Working directory: audit root. Exact combined probe:

```bash
python3 - <<'PY'
import ctypes, hashlib, sqlite3
lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
lib.acl_init.argtypes = [ctypes.c_int]
lib.acl_init.restype = ctypes.c_void_p
lib.acl_create_entry.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)]
lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
lib.acl_free.argtypes = [ctypes.c_void_p]
acl, created, found = ctypes.c_void_p(lib.acl_init(1)), ctypes.c_void_p(), ctypes.c_void_p()
create_rc = lib.acl_create_entry(ctypes.byref(acl), ctypes.byref(created))
get_rc = lib.acl_get_entry(acl, 0, ctypes.byref(found))
print('ACL', create_rc, get_rc, bool(found.value))
lib.acl_free(acl)
def digest(data):
    return hashlib.sha256(data).hexdigest()
def manifest(files):
    return ''.join(f'{path}\n{len(data)}\n{digest(data)}\n' for path, data in sorted(files.items())).encode()
trusted = {'LICENSE': b'license-bound-to-snapshot', 'config.json': b'{"model_type":"llama"}', 'model.safetensors': b'synthetic-weight-fixture'}
merged_path = 'LICENSE\n' + str(len(trusted['LICENSE'])) + '\n' + digest(trusted['LICENSE']) + '\nconfig.json'
substituted = {merged_path: trusted['config.json'], 'model.safetensors': trusted['model.safetensors']}
a, b = manifest(trusted), manifest(substituted)
print('MANIFEST', a == b, digest(a) == digest(b), set(trusted) != set(substituted), len(merged_path.encode()))
db = sqlite3.connect(':memory:')
sql = "WITH wallet_session_replays(session_id,metadata_client_ip,created_at) AS (VALUES ('s1','ip1','2026-09-07'),('s1','ip1','2026-09-07')) SELECT COUNT(*) FROM wallet_session_replays WHERE session_id = ? AND metadata_client_ip = ? AND created_at >= ?"
print('THROTTLE', *(db.execute(sql, (s, ip, '2026-09-07')).fetchone()[0] for s, ip in [('s1','ip1'),('s1','ip2'),('s2','ip1')]))
PY
```

Exit 0; exact output:

```text
ACL 0 0 True
MANIFEST True True True 87
THROTTLE 2 0 0
```

These are API/encoding/query-level proofs, not filesystem, HTTP or provider exploit tests. No files or network were used by this probe.

```bash
swift -e 'let minimum: String? = nil
let revoked = true
var rejected = false
if let minimum = minimum, minimum == "floor" || revoked {
    rejected = true
}
print("NIL_MINIMUM_REVOKED_REJECTED", rejected)'
```

Exit 0: `NIL_MINIMUM_REVOKED_REJECTED false`. This validates the optional-binding behavior, not an actual installation.

`go doc encoding/json.Unmarshal` in the gateway module exited 0 and confirmed case-insensitive struct matching and in-order duplicate replacement. The local `acl_get_entry(3)` documentation was also inspected. No web behavior was assumed to override the checked local implementation.

### Report Consistency and Worktree Verification

Completed checks:

- A read-only Node report validator exited 0: 16 unique finding sections, severity counts of 4 High / 9 Medium / 3 Low, 32 valid relative links, 38 valid fully qualified source references, and no missing paths or out-of-bounds line references.
- Independent Astra/Ultra reviews checked authority/coverage, the four High findings, F05-F14 and relevant no-finding statements against source. Corrections tightened the streaming-disconnect exclusion in F04, the F01 reservation reference, map paths and prioritization rationale. No severity change was required.
- Test totals reconcile to 283 selected Swift tests with zero failures, seven selected passing integration tests, and the passing gateway race suite and vet command described above. Unrun exploit scenarios remain explicitly labeled.
- `git diff --exit-code` and `git diff --cached --exit-code` each exited 0 with no output.
- `git status --short --untracked-files=all` exited 0 and listed only `?? audits/security-boundary-audit-2026-09-07-astra-ultra.md`.
- `git rev-parse HEAD origin/main` exited 0 and returned `afe6b12e1872aa7d2ddd94817120d37a77f31c0f` for both refs.
- Canonical-checkout `git status -sb` exited 0 with `## main...origin/main` and no changes. The audit worktree is retained solely to deliver the uncommitted report.

## Residual Risks and What Was Not Tested

- No full Swift suite, full Malibu app/Xcode suite, ML model inference, real secure-enclave/Keychain access, installer/notarized release execution, full integration suite, production nginx/configuration or production spending/settlement was tested.
- No hostile TLS/DNS/proxy, partial-send, timed slow-header, browser DNS-rebinding, power-loss, crash-at-every-write or concurrent filesystem-ACL attack was dynamically reproduced. Focused reproductions are specified where relevant.
- No proof of the F01 multi-parser attack against a running Swift provider, or F02 facade delayed-trailer behavior, was produced. Their confirmed source defects and untested consequences are distinguished above.
- Tests may generate synthetic keys, local databases and temporary binaries. No operator secrets were loaded and no signed journey artifact was created. Build/test caches are not implementation changes.
- Same-user process compromise, privileged/root attackers, OS cryptographic guarantees, dependency supply-chain vulnerabilities and ML kernel/native parser memory safety were not exhaustively evaluated.
- Gateway SQLite creation does not itself enforce private file modes and the service lacks an explicit UMask, but deployment creates restricted data directories; arbitrary-local-user readability was not established. Backup custody remains especially important because of F03.
- Default-off wallet/relay features reduce current exposure but do not prove deployed flags are off. This audit did not inspect production deployment state.
- Passing tests establish only the exercised behavior. Some explicitly encode unsafe behavior, and the conformance discrepancy is itself a finding.
