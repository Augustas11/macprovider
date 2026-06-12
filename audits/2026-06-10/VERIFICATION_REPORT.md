# Audit Verification — 2026-06-10 milestone cycle

_Generated 2026-06-12. Working tree HEAD `fd3c652` on `main`; verification on branch `chore/audit-verification`._

_Method: 8 parallel dimension-verifier agents (Architecture+Code, Security incl. XSEC-1, Testing, Performance, Dependencies, DevEx, Docs, Cross-cutting OQ+§5). Each followed the adversarial verifier pattern: locate fix → re-read audit-cited file:line with `Read` → look for the regression test the milestone prompt required → counter-evidence pass → status. Baseline test suites at branch head: `phase4-coordinator go test ./...` GREEN (13/13 packages, ~62s), `phase5-gateway` GREEN (6/6 packages, ~28s), `phase3-binary swift test --parallel` 219/219 PASS._

_One verifier override was applied during synthesis: the cross-cutting agent marked QW-5/M2-3 RESOLVED based on `MILESTONE_2_HANDOFF.md` text; the architecture dimension agent's `grep -rn SetMaxOpenConns phase4-coordinator/` proved otherwise. Both rows are NOT_RESOLVED in the final report. No other discrepancies surfaced between agents._

## Executive Summary

- **Audited:** 57 audit findings + 7 Open Questions + 39 §5 tasks = **103 entries** verified.
- **RESOLVED:** 64 (62%)
- **RESOLVED_DIFFERENTLY:** 1
- **PARTIAL:** 16
- **CODE_SHIPPED_OPERATOR_PENDING:** 7
- **NOT_RESOLVED:** 9
- **SUPERSEDED:** 1
- **DEFERRED:** 5
- **UNVERIFIABLE:** 0
- **New issues surfaced during verification:** 5 (0 High, 1 Medium, 4 Low).

### Bottom line

The 2026-06-10 audit corpus shipped substantially. All seven Quick Wins (with one clerical exception flagged below — QW-5/M2-3), Milestone 0 (safety net), most of Milestone 1 (security & correctness), most of Milestone 2 (high-leverage), and all three phases of Milestone 3 (polish) merged to `main`. The control loop the audit named as 'below the minimum bar for live money' — no CI, no external monitoring, no version-stamped builds, no scripted gateway deploy — is now in place and exercised on every push.

Remaining gaps cluster on three patterns:

1. **M2-1 strangler refactor mid-flight.** PR #36 fixed the two confirmed divergences (queue-full→StateBusy + `explicitRetries++`); PR #48 (M2-1a) extracted the per-retry tail. The three transport loops still exist on main because M2-1b (PR #61) is draft and M2-1c is not yet open. ARCH-1/CODE-1 is `PARTIAL`.
2. **Operator-action items the repo cannot prove.** `require_provider_tokens=true` flip on Pearl + N=3 token migration (M1-1/XSEC-1); M3-2 operator-key cutover; M1-7 sqlite canary day; M3-4 swift-tests branch-protection flip. Code is merged in every case; production state is the missing evidence.
3. **Small Mediums explicitly deferred or scope-bounded.** Q3 (tier-2 posture) silently deferred — handoff doc only, no `DECISION_CRITERIA` entry; Q4 (gateway append-only-forever) drafted in PR #58 but not on main, so M2-4 Part C stays gated; M3-1 follow-up (sargable RFC3339Nano normalization) intentionally deferred per the variable-width-encoding finding in `MILESTONE_3_PHASE23_HANDOFF.md`.

One additional gap was surfaced by verification itself: **QW-5/M2-3 (`SetMaxOpenConns(1)` on coordinator stores) was claimed as RESOLVED in the M2 handoff doc but never actually shipped** — `grep` returns zero hits in `phase4-coordinator/`. See `ARCH-3` for the architecture-dimension confirmation.

### Headline gaps (top 3 non-RESOLVED items, severity-ordered)

1. **ARCH-1 (High, now `PARTIAL`)** — handleChatCompletions god-function with three diverging copies of failover state machine.
2. **CODE-1 (High, now `PARTIAL`)** — Drift across three copies of failover state machine (merged with ARCH-1).
3. **DEVE-2 (High, now `PARTIAL`)** — The 3am story — single Gmail channel co-hosted on VPS, no external check.

### Open Questions snapshot

- RESOLVED: 3 (Q1 receipts→roadmap shipped as QW-4/M1-3 via PR #12; Q2 self-serve provisional in PR #44; Q5 deprecation cleanup via M3-5; Q7 console roadmap = trim-now-build-later)
- PARTIAL: 2 (Q4 ruled in PR #58 body but PR is still open; Q5 partial cleanup remains)
- NOT_RESOLVED + DEFERRED: 2 (Q3 tier-2 posture silently deferred; Q6 perf target not formally ruled)

### Task-table snapshot (§5)

- RESOLVED: 27 of 39
- PARTIAL: 4
- NOT_RESOLVED: 2 (QW-5 + M2-3 post-override)
- CODE_SHIPPED_OPERATOR_PENDING: 4
- DEFERRED: 2 (M2-9 → M3-11 cross-service integration test; M3-10 logRowWithBilling pairs with M2-1c)

---

## Open Questions status

### Q1 — Receipts: build or retract? — `RESOLVED`

**Evidence** PR #12 (commit 0e8283c) `docs(readme): truth sweep -- receipts to roadmap, console trim, drop version pin`. **Original citation** REPO_AUDIT.md:288 — "Receipts: build or retract? README's signed-receipt schema ... zero implementation. ... M1-3 ships honest copy. Which is it, and on what timeline?" **Fix delta** Suggested: retract OR commit timeline. Actual: short-term path taken — README receipts language moved to a roadmap/not-yet section via QW-4 (M1-3 duplicate); long-term build/retract decision NOT recorded in DECISION_CRITERIA. **Notes** Short-term "honest copy" shipped; product call (build receipts or formally drop from roadmap) is not visible in the decision log.

### Q2 — Provider token issuance model for open onboarding — `RESOLVED`

**Evidence** DECISION_CRITERIA.md Entry 60 (2026-06-11) explicitly rules: "Open Q2 ruled: provisional providers self-serve their token on first admission." Implementation: PR #44 (commit e26b245) `M1-1 Q2: self-serve provisional tokens (closes XSEC-1 open-onboarding gate)`, SPEC-003 amended to v0.8 then iterated to v0.8.3/0.8.4 (Entries 67/75/76). **Original citation** REPO_AUDIT.md:289. **Fix delta** Self-serve branch chosen. **Notes** Code shipped and merged; FR-C9.4 hardening (PR #69/#78) layered on. Production flag-flip to `require_provider_tokens=true` still operator-pending.

### Q3 — Target tier-2 posture for this beta — `DEFERRED`

**Evidence** MILESTONE_1_HANDOFF.md:55-65 — "This autopilot run asked the operator and the answer was 'Defer Part C entirely.' None of the five flags are asserted by the M1-6 deploy gate yet." **Original citation** REPO_AUDIT.md:290. **Fix delta** Deferred; M1-6 Part C is ~10-line add once decided. **Notes** No DECISION_CRITERIA entry closing Q3; remains operator-pending.

### Q4 — Gateway append-only-forever: requirement or default? — `PARTIAL`

**Evidence** PR #58 (`docs/q4-archive-rotate-decision`, OPEN — not merged) rules archive-rotate to cold storage per its body and proposes Entry 63 + `Q4_ARCHIVE_ROTATE_DESIGN.md`. **Original citation** REPO_AUDIT.md:291. **Fix delta** Decision proposed (archive-rotate) but PR not merged; Entry 63 on `main` is M3-5, not Q4 ruling (numbering collision noted in PR body). M2-4 Part C remains gated. **Notes** Direction captured in PR #58 body; canonical decision-log entry not on main.

### Q5 — Deprecation candidates (beta/web, dist tarballs, Phase-1 artifacts, .venv) — `PARTIAL`

**Evidence** PR #52 / commit 925af43 git-rm'd `logs/` and `results/`, moved REPORT.md, added `beta/requirements.txt`, anchored .gitignore. **Original citation** REPO_AUDIT.md:292. **Fix delta** Phase-1 logs/results: DONE. beta/web 410-gated demo, historical dist tarballs, root .venv: not visibly addressed. **Notes** Partial — one of four candidates fully removed.

### Q6 — Performance target — is ~25-30% coordinator overhead acceptable? — `NOT_RESOLVED`

**Evidence** No DECISION_CRITERIA entry closes Q6 explicitly. Audit §4 already states "Don't chase the ~25-30% coordinator overhead — it's inherent hop cost" (REPO_AUDIT.md:200). **Original citation** REPO_AUDIT.md:293. **Fix delta** Audit §4 implicitly answers (accept-as-standing) but no operator confirmation entry recorded. **Notes** Treat as implicitly accepted; no explicit closure.

### Q7 — Console roadmap vs copy — `RESOLVED`

**Evidence** PR #12 (commit 0e8283c) trimmed README console claims to three real views — the "trim copy" branch of Q7. No subsequent provider-management/earnings console view added. **Original citation** REPO_AUDIT.md:294. **Fix delta** Effectively resolved as the trim-copy branch via QW-4.

---

## Findings by dimension

### Architecture & Code Quality (§3.2 + §3.3)

#### ARCH-1 (High) — handleChatCompletions god-function with three diverging copies of failover state machine — `PARTIAL`

_Recalibrated severity: Medium — the live divergence bugs (state-marking + retry counter) are fixed and the most-duplicated extraction (advanceToNextProvider) is hoisted; remaining is structural duplication of three transport loops, not correctness drift_

**Evidence** PR #36 (27559ae) fixed the two confirmed divergences (queue-full→StateBusy now happens in the streaming path, see `buyer/server.go:1109-1111`; explicitRetries++ unified inside `advanceToNextProvider`). PR #48 (8f18f5a, M2-1a) extracted `advanceToNextProvider` helper at `buyer/server.go:1377-1399`. PR #36 / #48 close two of the three milestone sub-tasks; M2-1b (transportResult + 3 classifiers) exists only as draft commit `de58b9a` and is not merged; M2-1c not yet open per handoff.

**Original citation** Audit cited `buyer/server.go:840-1350` and three loops at 1056-1153, 1154-1245, 1246-1349. Current function still spans 487 lines (`handleChatCompletions` 869 → ~1356), with three loop bodies preserved at 1085-1170 (streaming), 1172-1257 (WS-tunnel non-streaming), and 1264-1356 (HTTP). The helper call is now repeated at lines 1136, 1163, 1197, and 1348.

**Fix delta** Audit recommended unifying the three transport loops into one failover skeleton. Team chose three-PR mechanical extraction: M2-1a (helper hoist, shipped) → M2-1b (transportResult classifier, drafted) → M2-1c (loop unification, not started). Two real drift bugs are gone; structural triplication remains.

**Notes** PR #36 regression tests cover the StateBusy/retry-counter behaviour; baseline buyer suite green.

#### ARCH-2 (Medium) — Synchronous SQLite write under the global pool lock (swap-audit emitter) — `RESOLVED`

**Evidence** PR #46 (221f660, M2-2). `pool/provider.go:665-674` — `ApplyHeartbeat` now calls `applyHeartbeatLocked` (which scopes `r.mu`) and then invokes `r.swapEmitter(swap)` AFTER the lock release. Concurrency contract documented at lines 614-631. `cmd/coordinator/main.go:117-189` wires a cap-64 buffered channel + dedicated drain goroutine so EmitSwap INSERTs run off-lock with best-effort drop-on-overflow. Regression tests `TestApplyHeartbeatSwapEmitterCalledWithoutPoolLock` and slow-emitter back-pressure assertion at `pool/provider_test.go:10-91`.

**Original citation** Audit cited `pool/provider.go:483-484,542-554` and `main.go:94-111`. The synchronous EmitSwap-under-lock pattern at those lines no longer exists; emission moved to non-blocking send.

**Fix delta** Implementation matches the suggested fix (collect under lock, dispatch via buffered channel after unlock). Shutdown ordering hardened beyond the audit recommendation: channel is never closed, sender + receiver coordinate via shutdownCtx to avoid send-on-closed panic.

**Notes** Phase4-coordinator suite green at baseline.

#### ARCH-3 (Medium) — Uncapped *sql.DB handles on coordinator while money path takes BEGIN IMMEDIATE — `NOT_RESOLVED`

**Evidence** `grep -rn 'SetMaxOpenConns' /Users/augstar/macprovider-poc/phase4-coordinator/` returns ZERO hits. Gateway still caps at 1 (`phase5-gateway/internal/storage/sqlite/store.go:38`). M2-3 was listed in §5 task table but no commit references it; no entry in any handoff doc says M2-3 shipped.

**Original citation** `cmd/coordinator/main.go:47-59` — opens `tokenStore`, `reqLogStore`, `auditStore` in sequence (now lines 57-74 post-drift) with no SetMaxOpenConns call. Sub-handles for `admissionStore` and `billingStore` (lines 75-84) also derive from the unconfigured `reqLogStore.DB()`.

**Fix delta** Suggested fix (`SetMaxOpenConns(1)` on each of the three handles) — not applied.

**Notes** Latent risk until coordinator concurrency rises (currently single-coordinator). The buyer hot-path `request_log_failed` 500 path at `buyer/server.go:1286-1290` (audit-era) still depends on this; same write contention shape.

#### ARCH-4 (Medium) — Gateway router/server.go 2,495-line god-file — `RESOLVED`

_Recalibrated severity: Low — file split is the canonical maintainability fix the audit asked for_

**Evidence** PR #55 (c33ed08, M3-9 Phase 1) split server.go. `wc -l phase5-gateway/internal/router/server.go` = **824 lines** (down from 2,495). New per-concern files in `internal/router/`: `chat_proxy.go` (~26KB), `disclosure.go` (~14KB), `oauth.go` (~13KB), `admin.go` (~9KB), `auth_helpers.go`, `explorer.go`, `pages.go`. The disclosure-synthesis block the audit named the strongest extraction candidate now lives in `disclosure.go` (functions `coordinatorRoutingMetadata`, `makeTier1Disclosure`, `tier2ModelHashState`, etc.).

**Original citation** Audit cited `router/server.go:134-164` (route table) and `:831-1249` (disclosure block). Current `server.go` no longer hosts disclosure synthesis; route table remains in server.go but file size cleared the god-file bar.

**Fix delta** Implementation matches suggestion: pure file split first (no behaviour change), with two follow-up fixups (`5873b4e` auth_helpers boundary, `a984e0f` chat_proxy helpers).

**Notes** Phase5-gateway suite green; integration tests untouched and passing per baseline.

#### ARCH-5 (Low) — Cross-service duplication (sqlite DSN helper, bearer compare) — document conscious debt — `NOT_RESOLVED`

**Evidence** `phase4-coordinator/internal/sqliteutil/dsn.go:8-23` and `phase5-gateway/internal/storage/sqlite/dsn.go:8-22` still hold byte-identical `WithPragmas`/`sqliteDSN` bodies (same four pragmas, same order). `grep -rn 'ARCH-5'` in *.md returns only the audit file itself; no documentation lookup of the conscious-debt rationale was added to OPS.md / coordinator README / gateway README. PR #50 (M2-8 OPS.md) shipped general ops docs but did not call this out.

**Original citation** Audit asked these be documented as 'conscious-debt copies'.

**Fix delta** No code change expected, but the *document* part of the recommendation was not done. Counts as not_resolved per the audit's own wording.

**Notes** Low impact; mention-it-once fix.

#### ARCH-6 (Low) — Billing/request-log persistence orchestration lives inline in handler closures — `DEFERRED`

**Evidence** Handoff lists M3-10 as DEFERRED, pairing with M2-1c. No commit references ARCH-6 or `logRowWithBilling` extraction. `buyer/server.go:869-974` still defines `logRowWithBilling` as an inline closure inside `handleChatCompletions` (lines 880-974). The gateway pattern the audit pointed at as the goal remains the contrast.

**Original citation** Audit cited `buyer/server.go:851-945`; the closure now spans 880-974 (drifted but same shape).

**Fix delta** Explicit deferral, paired with the M2-1 ARCH-1 work-stream so the extraction lands once the failover loops collapse to one. Justified sequencing.

**Notes** No regression risk while deferred (money math in `formula.go` is the high-stakes part and stays isolated).

#### CODE-1 (High) — Drift across three copies of failover state machine (merged with ARCH-1) — `PARTIAL`

_Recalibrated severity: Medium — same recalibration as ARCH-1 (merged finding)_

**Evidence** Same as ARCH-1. PR #36 unified the two confirmed drift bugs; PR #48 extracted the per-retry tail into `advanceToNextProvider`. The three loop bodies still exist at `buyer/server.go:1085-1170`, `1172-1257`, `1264-1356`.

**Original citation** §3.1 item 3 / §3.3 CODE-1 merged into ARCH-1 in the audit.

**Fix delta** Drift correctness fixes shipped; structural deduplication partial.

**Notes** See ARCH-1 for details.

#### CODE-2 (Medium) — Synchronous SQLite write under pool lock (merged with ARCH-2) — `RESOLVED`

**Evidence** Merged finding — see ARCH-2 for full evidence (PR #46, M2-2 regression tests at `pool/provider_test.go:10-91`, swap emission post-`r.mu`-release contract).

**Original citation** §3.3 CODE-2 merged into ARCH-2 in the audit.

**Fix delta** Same as ARCH-2.

**Notes** See ARCH-2.

#### CODE-3 (Low) — Tier-2 trust disclosure parsed from untyped map[string]any with silent zero-fallbacks (Phase-1 fallback path) — `NOT_RESOLVED`

**Evidence** `phase5-gateway/internal/router/disclosure.go:318-422` — `tier2BodyMetadataActive`, `tier2ModelHashState`, `intFromModelField` and friends still drill through `body map[string]any` with `_, _ := tier2Raw['model_hash'].(map[string]any)` zero-default-on-miss patterns (lines 319, 323, 328, 333, 338, 378, 383). No commit references CODE-3 explicitly; not on any milestone task list.

**Original citation** Audit cited `server.go:1020-1080`. Code moved to `disclosure.go` during M3-9 file split; map[string]any pattern preserved verbatim.

**Fix delta** Verifier-downgraded Low; team chose not to act (consistent with downgrade reasoning that the typed `/internal/routing` path now dominates).

**Notes** Strictly the Phase-1 fallback path; three golden tests pin the shape per the audit. Acceptable to leave as-is, but the residual silent-zero-fallback hazard the audit named is still present in code.

#### CODE-4 (Low) — Copy-pasted writeError helpers with three diverging envelope shapes — `RESOLVED`

**Evidence** PR #64 (c4d1ac1, M3-8a). All three sites now produce the unified 4-field OpenAI shape `{message,type,param,code}`:
- `phase4-coordinator/internal/buyer/server.go:3211-3236` — `writeError` delegates to `writeErrorTyped`, which encodes `map[string]any{'error': map[string]any{'message', 'type', 'param': nil, 'code'}}`.
- `phase4-coordinator/internal/billing/endpoints.go:558-560` — same 4-field shape via `writeJSON`.
- `phase5-gateway/internal/router/server.go:736-738` — same 4-field shape, accepts explicit `typ` arg.

**Original citation** Audit cited 4/3/2-field divergence at `buyer/server.go:3111`, gateway `:2304`, `billing/endpoints.go:524` — lines drifted to current locations and all three now match.

**Fix delta** Implementation matches recommendation. `readLimitedBody` cross-service duplication (the other half of CODE-4) was not part of the M3-8a scope; quick check shows it's still duplicated. Audit prioritised the writeError client-facing inconsistency, which is fixed.

**Notes** Coordinator + gateway suites green at baseline.

#### CODE-5 (Low) — Dead Swift connect-path code (unreachable wsTunneledMode branch + no-op do/catch) — `RESOLVED`

**Evidence** PR #65 (2b20af5, M3-8b). `CoordinatorClient.swift:338-344` — `connectAndRunLegacy` is now 7 lines: clears tier2Session, nils inferenceRelay, sends hello, runs receive loop. The pre-fix unreachable `if wsTunneledMode` branch and the `do/catch { throw error }` no-op pattern are gone. Caller still gates on `wsTunneledMode` at line 289 so the legacy variant is only entered when the boolean is true (consistent with the rename of the path).

**Original citation** Audit cited `CoordinatorClient.swift:280-291` (dead branch) and `:254-257` (no-op do/catch). Both code regions removed.

**Fix delta** Implementation matches suggestion.

**Notes** Swift suite green per baseline.

#### CODE-6 (Low) — Hand-rolled fmt.Sscanf/Sprintf JSON serializer for capacity tier — `RESOLVED`

**Evidence** PR #63 (b91eda4, M3-8c) + fixup `c3572ac` (legacy backward-compat). `phase5-gateway/internal/storage/sqlite/store.go:820-870` — new `capacityTierDTO` struct with json tags; `GetCapacityTier` uses `json.Unmarshal`, `SetCapacityTier` uses `json.Marshal`. Legacy fallback at line 848 reads pre-existing `fmt.Sprintf %q` rows via Sscanf so existing DBs decode cleanly. Regression test at `store_test.go:890-941` covers the legacy-row path.

**Original citation** Audit cited `store.go:767,778`. Both write/read paths now use encoding/json, matching the sibling kill-switch pattern the audit referenced.

**Fix delta** Implementation matches suggestion; team added a backward-compat path the audit didn't explicitly require (good defensive call given existing prod rows).

**Notes** Gateway suite green at baseline.

### Security

#### XSEC-1 (High) — Provider identity unauthenticated end-to-end — `CODE_SHIPPED_OPERATOR_PENDING`

**Evidence**
- PR #41 (89de1e6) `m1-1: provider_token plumbing + Bearer on WS connect (XSEC-1, pinned tier)` — Swift binary Authorization header.
- PR #44 (e26b245) `M1-1 Q2: self-serve provisional tokens (closes XSEC-1 open-onboarding gate)` — coordinator-side FR-C9 self-serve mint.
- Live coordinator deploy + rollback noted in orchestrator brief, 2026-06-12.

Sub-aspect verification:

(a) Swift Bearer header — **RESOLVED**. `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:122-138` declares `private var providerToken: String?`, init reads `config.providerToken` (line 182). At connect (line 304-305): `if let token = providerToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }`. Comment block at 122-128 explicitly tags `M1-1 / XSEC-1`.

(b) Coordinator validates tokens & impersonation guard — **RESOLVED**. `phase4-coordinator/internal/ws/server.go:944-952` retains the pinned-impersonation guard intact: `if pinned && !auth.validated { s.close(conn, CloseInvalidToken, "invalid_token"); return nil, false }`. The mismatch guard (validated providerID != hello providerID) is also intact on line 945-948. `s.tokens != nil` gating means the guard fires whenever the token store is wired (which it is in production).

(c) Production `require_provider_tokens=true` flip — **CODE_SHIPPED_OPERATOR_PENDING**. The default in `phase4-coordinator/internal/config/config.go` is `true` (audit § 3.1 item 1 confirms `config.go:357-359`). But the live production posture is held in the gitignored `coordinator.yaml` on Pearl. Orchestrator notes coordinator was `deployed + rolled back 2026-06-12` — not yet live. **Evidence that would close this**: a `beta/DECISION_CRITERIA.md` entry recording the flag flip with the live `curl coordinator.streamvc.live/healthz` or `/poolz` output confirming tokenless connects are rejected. No such entry was found in DECISION_CRITERIA.md (searched for `require_provider_tokens`, `tokens.*flip`, `flip.*token` — zero hits).

(d) All N=3 providers have valid tokens — **CODE_SHIPPED_OPERATOR_PENDING**. PR #44's self-serve provisional path means tokens are minted on first admission, so the migration path exists end-to-end. But repo cannot prove the N=3 providers' actual token state. **Evidence that would close this**: an operator log entry listing the three provider_ids with their token prefixes (the 12-char `tokenDisplayPrefixLength` from `auth/tokens.go:43`) and `last_used_at` timestamps from the coordinator token store after flag-flip.

(e) install.sh ships token provisioning — **RESOLVED via self-serve flow**. PR #44 commit body: "DECISION_CRITERIA Entry 60 records the ruling on Open Q2... provisional providers self-serve their token on first admission rather than gating on operator action. Self-serve preserves the curl-bash open-onboarding tier while still closing XSEC-1 provider impersonation at flag-flip time." `phase4-coordinator/internal/ws/server.go:605-609` implements the mint: `s.log.Info().Str("provider_id", providerID).Msg("FR-C9.1 self-serve provisional token minted on first tokenless admission")` returning `provisionalTokenMinted, token, pool.AuthSelfMinted`. install.sh therefore does NOT need to ship a token field directly — first tokenless connect mints it and persists via `acceptCoordinatorSession` (Swift, ref CoordinatorClient.swift:129-137, 578).

**Original citation**
REPO_AUDIT.md §3.1 item 1: "the binary never sets an Authorization header (CoordinatorClient.swift:111-137); coordinator defaults require_provider_tokens=true (config.go:357-359) and would *reject* every curl|bash provider — so the live tokenless beta necessarily runs with it false, and with it false prepareProviderAdmission skips the pinned && !auth.validated impersonation guard entirely (ws/server.go:602-619)".

**Fix delta**
Suggested fix was "binary sends Bearer; installer/onboarding provisions token; migrate N=3 providers; flip require_provider_tokens=true in prod". Actual: binary sends Bearer (a) PLUS coordinator self-mints provisional tokens (e); the installer-side static-provision step was replaced by self-serve at first admission per Open Q2 decision. That's a defensible deviation — it preserves open onboarding while still closing the impersonation gap once production flips the flag. Deviation reason: M1-1 handoff cited operator decision to take the self-serve path over operator-issued strangers.

**Notes**
- The exploit window remains open until (c) and (d) are operator-verified. Until `require_provider_tokens=true` is live on Pearl, the `pinned && !auth.validated` guard at server.go:949-952 still flows through (correct), but the broader posture means provisional providers are not yet identity-verified for billing attribution. SECU-6 (provider revenue gaming) is therefore still amplified.
- Coordinator was deployed and rolled back on 2026-06-12 per the orchestrator brief — production state must be re-verified after the next deploy.

#### SECU-1 (High) — Unrate-limited public /ws/provider on coordinator hostname — `RESOLVED`

**Evidence**
- PR #39 (a425900) `m1-4: rate-limit /ws/provider + per-IP semaphore (SECU-1)`.
- `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:83-89`: the `/ws/provider` location now carries `limit_req zone=ws_provider_rate burst=5 nodelay` and `limit_conn ws_provider_conn 5`, matching the api vhost. Comment at line 84 explicitly tags `M1-4 / SECU-1`.
- Header note at line 19-23 documents that the zones are declared once in the api vhost to avoid `limit_conn_zone is already bound` collision (Pearl, 2026-06-11 deploy).

**Original citation**
REPO_AUDIT.md §3.1 item 6: "nginx-coordinator.streamvc.live.conf:65-84 has none; nginx-api.streamvc.live.conf:10-11,124-134 has both."

**Fix delta**
Suggested fix: "Add the same limit_req zone=ws_provider_rate and limit_conn ws_provider_conn directives to the coordinator.streamvc.live /ws/provider location". Actual: exactly that, plus per-IP semaphore on the Go side (PR #39 commit title) — matches suggestion.

**Notes**
This is a config-only change in dist/; production deploy noted as 2026-06-11. Baseline tests are green.

#### SECU-2 (Low) — README advertises unimplemented signed receipt feature — `RESOLVED`

**Evidence**
- `README.md:22` now reads `Every response will carry a signed receipt binding (prompt, output, provider) — verifiable inference, without a datacenter (planned, not yet implemented; see [Roadmap](#roadmap))`. Tense moved from present to future, parenthetical disclaim added.
- `README.md:113`: "**Signed inference receipts — planned, not implemented.** The product surface described below is a design proposal preserved here so it isn't lost; no service in this repo currently issues, signs, or verifies receipts. Tracked as Open Question 1 in `audits/2026-06-10/REPO_AUDIT.md`." Explicit cross-reference back to the audit.

**Original citation**
REPO_AUDIT.md §3.1 item 5 (DOCS-1/SECU-2): "README advertises an unimplemented cryptographic feature ... 'Every response carries a signed receipt' + full v1 receipt schema (README.md:22,57,59-83)".

**Fix delta**
Suggested fix (b): "immediately downgrade the README language from 'every response carries a signed receipt' to a roadmap item". Actual: did exactly that, both in the headline at line 22 and the receipt-schema section at line 113. No deviation.

**Notes**
Severity Low matches the verifier downgrade in findings-raw.json (originally Medium, verifier-downgraded to Low). No implementation effort was made (option (a) — actually shipping receipts); that remains on the roadmap. SECU-6 still notes the trust gap that a real receipt would close.

#### SECU-3 (Medium) — Tier-2 posture defaults fully permissive; deploy gate doesn't assert flags — `PARTIAL`

**Evidence**
- PR #40 (0895d58) `m1-6: scripted gateway deploy + mandatory C2 + remote backup (DEVE-4/5, SECU-3)`.
- M1-6 Parts A+B landed (scripted gateway deploy in `phase5-gateway/dist/deploy-pearl-vps.sh`, mandatory C2 cross-check in `phase4-coordinator/dist/check-deploy-config.sh` hard-failing on missing gateway.yaml).
- **Part C explicitly DEFERRED.** `audits/2026-06-10/MILESTONE_1_HANDOFF.md:55-65`: "Open Q3 — Target tier-2 posture for this beta (still open, but with a decision recorded) ... **This autopilot run asked the operator and the answer was 'Defer Part C entirely.'** None of the five flags are asserted by the M1-6 deploy gate yet."
- Confirmed empirically: `grep -n 'tier2\|require_encrypted\|require_hash\|require_attestation\|posture' phase4-coordinator/dist/check-deploy-config.sh` returns only M1-6 banner comments, NO tier-2 flag assertions. Same for `phase5-gateway/dist/deploy-pearl-vps.sh`.

**Original citation**
REPO_AUDIT.md §3.4: "SECU-3 — Tier-2 posture defaults fully permissive (all five enforcement flags false, config.go:287-297; v1 plaintext hello accepted unless RequireEncryptedLeg, ws/server.go:320-323). Actual production posture lives only in the gitignored coordinator.yaml; no deploy gate asserts it."

**Fix delta**
Suggested fix: "Add a tier-2 posture assertion to check-deploy-config.sh / deploy-pearl-vps.sh that fails the deploy if the production coordinator.yaml does not set the tier-2 enforcement flags the network claims to provide." Actual: the deploy-gate infrastructure now exists (Parts A+B), making the addition a 10-line follow-up per M1-6 handoff, but the operator chose to defer Part C until tier-2 posture is decided. The MILESTONE_1_HANDOFF passage at line 63-64 confirms this is a known 10-line addition awaiting the operator decision on which flags to assert. Deviation reason: open Q3 (tier-2 target posture) unanswered.

**Notes**
- Part C deferral is explicit and documented; not a gap-by-omission.
- The verifier note in the audit clarifies external transport is TLS via tunnel — gap is payload-level only.
- Defaults at `config.go:287-297` remain unchanged (permissive). Production coordinator.yaml posture is unverifiable from repo (gitignored).

#### SECU-4 (Medium) — One shared operator key spans gateway admin, coordinator operator API, and sticky buyer path — `CODE_SHIPPED_OPERATOR_PENDING`

**Evidence**
- PR #73 (11f7c0c) `m3-2: operator-key split + coordinator env-file + de-root monitor (SECU-4 + DEVE-7)`.
- New auth helpers in `phase4-coordinator/internal/auth/tokens.go`: `OperatorOnlyBearerMatches` (line 106) for human-admin endpoints, `GatewayInternalBearerMatches` (line 129) for service-to-service `/internal/*` paths with `BearerKindServiceToken` preferred over legacy `BearerKindOperatorKey` fallback.
- `phase4-coordinator/internal/ws/server.go:2161` — `authorizedOperator` uses `OperatorOnlyBearerMatches` (operator-only, no service-token acceptance). Comment block 2138-2160 records codex security audit HIGH-1 reasoning: admin endpoints accepting service token would silently grant human-admin power to gateway post-rotation.
- `phase4-coordinator/internal/billing/endpoints.go:75-95` — billing `admin()` helper uses `OperatorOnlyBearerMatches`, explicitly comments "the gateway service token is intentionally NOT accepted here so a compromised gateway can't pivot to billing-ledger reads. Empty operator_key still means DENY (M1-5 / SECU-5)."
- `M3-2_LEGACY_FALLBACK_REMOVAL.md` tracks the legacy fallback for removal after 30 days of zero gateway-origin `key=operator_key` logs.
- Operator key split is shipped via backward-compatible bridge (PR #73 description: "Part C: split operator-key via backward-compatible bridge (SECU-4)").

**Original citation**
REPO_AUDIT.md §3.4: "SECU-4 — One shared operator key spans three planes: gateway admin endpoints (server.go:2061-2067), the coordinator operator API, and — when sticky routing is on — the hot buyer path itself (server.go:1394-1405). One leak compromises everything; no service-vs-human credential separation."

**Fix delta**
Suggested fix: "Split into two secrets: a service-to-service token the gateway uses for coordinator /internal and sticky calls, and a separate human-admin token for the gateway's own /admin plane. Rotate independently." Actual: exactly that, via `GatewayInternalBearerMatches` (service token preferred) for /internal paths and `OperatorOnlyBearerMatches` (operator-only) for human-admin paths. Plus de-root monitor and coordinator env-file indirection from DEVE-7 in the same PR. Deviation reason: shipped with a legacy `operator_key` fallback in the bridge so operators can cut over without simultaneous rotation; tracked for removal.

**Notes**
Marked CODE_SHIPPED_OPERATOR_PENDING rather than RESOLVED because: (1) the operator must actually rotate to using the new service-token credential and (2) the legacy fallback removal is gated on 30 days of clean cutover logs. Until rotation happens, blast-radius is unchanged in production. Per M3-2 handoff, cutover is operator action.

#### SECU-5 (Low) — Auth predicates fail open on empty keys (defense-in-depth gap) — `RESOLVED`

**Evidence**
- PR #37 (0c331c4) `phase4-coordinator: fail-closed auth predicates (SECU-5/TEST-5)`.
- `phase4-coordinator/internal/auth/tokens.go:55-69` (`BearerTokenMatchesHeader`): `if expected == "" { return false }` — fail-closed.
- `phase4-coordinator/internal/billing/endpoints.go:75-95` — billing `admin()` now uses `auth.OperatorOnlyBearerMatches` which uses BearerTokenMatchesHeader semantics (returns false on empty); replaces the previous fail-open `if h.operatorKey != "" && !authorized` pattern. Inline comment line 83: "Empty operator_key still means DENY (M1-5 / SECU-5)."
- `phase4-coordinator/internal/ws/server.go:2161-2172` — `authorizedOperator` delegates entirely to `OperatorOnlyBearerMatches`; comment line 2150 explicitly notes "Empty operator_key still means DENY (M1-5 / SECU-5 preserved)."
- Dead-code `auth.AuthorizedBearer` was the verifier-cited overstatement — the live patterns (authorizedOperator + billing.admin) are both fail-closed.

**Original citation**
REPO_AUDIT.md §3.4: "SECU-5 + TEST-5 — Auth predicates fail open on empty keys (ws/server.go:1717-1718, billing/endpoints.go:63), masked solely by config.Validate() in a different file; no test locks the behavior."

**Fix delta**
Suggested fix: "Invert the predicates to fail closed: an empty expected key should deny, not allow." Actual: exactly that — consolidated through a single `BearerTokenMatchesHeader` helper that fails closed, called via `OperatorOnlyBearerMatches`. The defense-in-depth invariant is now local rather than file-spanning.

**Notes**
TEST-5 merged into SECU-5 per audit. Baseline test suite green per orchestrator brief (phase4-coordinator + phase5-gateway + swift 219). No specific test name verified in this pass, but config.Validate() invariant is now belt-and-suspenders rather than the sole line of defense.

#### SECU-6 (Low) — Provider-reported token counts trusted for billing within a cap — `NOT_RESOLVED`

**Evidence**
- No PR found in `git log --grep` for SECU-6 specifically; not listed in any milestone handoff as targeted for this audit cycle.
- §5 task table does not assign SECU-6 to M1/M2/M3.
- Audit text already classifies as Low: "Buyer over-charge is correctly impossible (usageFromJSON caps at promptEstimate+max_tokens, server.go:2356-2369); the coordinator additionally clamps completion to byte-estimate (formula.go:214); the gateway settlement path lacks that cross-check. Residual: provider revenue gaming — compounded by XSEC-1."
- XSEC-1 amplification reduces as PR #41+#44 close provider identity (provider gaming becomes attributable rather than anonymous), but the gateway settlement path's missing byte-estimate cross-check at `phase5-gateway/internal/router/server.go:1607-1611` is unchanged.

**Original citation**
REPO_AUDIT.md §3.4: "SECU-6 — Provider-reported token counts trusted for billing within a cap. Buyer over-charge is correctly impossible (usageFromJSON caps at promptEstimate+max_tokens, server.go:2356-2369); the coordinator additionally clamps completion to byte-estimate (formula.go:214); the gateway settlement path lacks that cross-check."

**Fix delta**
Suggested fix: "Cross-check reported completion_tokens against the gateway's own emitted-byte estimate and flag/quarantine large divergences (the quarantine machinery already exists in hotpath.go). Longer term, the signed receipt (#2) should bind the token counts so billing inputs are attestable rather than self-reported." Actual: neither implemented. Long-term fix (signed receipts) explicitly tracked as Open Question 1 in audit and README §113 disclaim.

**Notes**
Classified as Low and apparently accepted at that severity. Provider-gaming attack surface is real but bounded by the buyer cap; at N=3 known providers with token-flip pending (XSEC-1 sub-aspects c,d), risk is operationally minimal.

### Testing

#### TEST-1 (Medium) — Gateway TestConsoleStaticContracts fails on innerHTML usage — `RESOLVED`

**Evidence**
- Fix: commit c1b2e20 (PR #10) `m0: add CI workflow and fix TestConsoleStaticContracts`.
- Test now lives at `phase5-gateway/internal/router/pages_test.go:130` (the file path moved with M3-9 router split); innerHTML ban still enforced at line 145.
- Ran `go test ./internal/router/ -run TestConsoleStaticContracts -count=1` → `ok 0.420s`.
- `grep -rn innerHTML phase5-gateway/` returns no matches.

**Original citation**
Audit cited four innerHTML usages in `frontdoor/console/index.html:1200,1378,1413,1432`. That file path no longer exists under phase5-gateway (the console was either inlined into pages.go or refactored as part of M3-9 router split); current state is no innerHTML anywhere in phase5-gateway.

**Fix delta**
Suggested: replace innerHTML with textContent. Actual: console source was reworked during the M3-9 router split (PR #55) so the test now passes. The static contract test (innerHTML ban) was preserved.

**Notes**
Downstream of DEVE-1 (CI). Gateway suite is green per baseline. Strength preserved: behavior-named contract test still locks the policy.

#### TEST-2 (Low) — TestAuthLookupP95 1ms hard assertion flakes under parallel load — `RESOLVED_DIFFERENTLY`

**Evidence**
- Fix: commit 324c561 (PR #13, M0-3a) `deflake auth-lookup p95 and wake-gap tests`.
- Current state at `phase5-gateway/internal/storage/sqlite/store_test.go:960-967`:
```
// BenchmarkAuthLookupWith10KKeys replaces the previous
// TestAuthLookupP95UnderOneMillisecondWith10KKeys: a hard 1ms ceiling in
// CI burned wall-clock and observed 13ms under parallel load; converted
// to a benchmark so the number is tracked via b.ReportMetric...
func BenchmarkAuthLookupWith10KKeys(b *testing.B) {
```
- The structural guarantee (`TestAPIKeyHashIndexExists`) is preserved as a regular test.

**Original citation**
Audit cited the 1ms hard assertion flaking at 13ms under parallel load.

**Fix delta**
Suggested: deflake. Actual: converted to a benchmark reporting `p95_ms` via `b.ReportMetric` (so the number stays trackable without flaking CI). Reason: a hard ceiling on shared CI hardware is the wrong tool; the index correctness is the load-bearing assertion and is now a separate test.

**Notes**
Deviation is the correct call — benchmark + structural test split is more durable than tuning the threshold.

#### TEST-3 (Medium) — Wall-clock-coupled WS tests cause ~48s package runtime — `PARTIAL`

_Recalibrated severity: Low (most of the wall-clock burn is gone; remaining sleeps are intrinsic to heartbeat-boundary regressions)_

**Evidence**
- Partial fix: commit 324c561 (PR #13, M0-3b) addressed the wake-gap sleep specifically.
- `phase4-coordinator/internal/ws/server_test.go:1520` is now `time.Sleep(50 * time.Millisecond)` (was 1100ms) — wake-gap threshold dropped to 25ms via test-only `WakeGapThresholdMs`.
- Two other sleeps remain at lines 1742 (`200ms` in TestActiveProviderWithoutHeartbeatStaysConnected) and 1786 (`150ms` in TestProviderClosedAfterActivityStops). These tests pin the Phase 6 heartbeat-liveness regression (see project memory `phase6-heartbeat-liveness-regression`) and intentionally drive ~3s of activity at sub-second cadence to cross the heartbeat-miss threshold.
- Package runtime: `go test ./internal/ws/ -count=1` → `ok 9.536s`. Down from audit-era ~48s.

**Original citation**
Audit: `unconditional sleeps (ws/server_test.go:1493,1715,1759), package runtime ~48s vs 6-14s for all others`.

**Fix delta**
Suggested: deflake the package. Actual: only the wake-gap test was rewritten; the two heartbeat-boundary tests still use real wall-clock. But the headline complaint (48s package runtime) is gone — now 9.5s, within the 6-14s comparison band the audit named acceptable.

**Notes**
The remaining two sleeps are inherent to what the tests assert (a real-time boundary in liveness detection). Recalibrate to Low: the WS package no longer drags the suite, and project memory `load-dependent-test-flakes-concurrent` is now defended by the eventually-pattern fixes that landed alongside M0-3b.

#### TEST-4 (Medium) — tier2 catalog package-global singleton forces ResetForTest, blocks t.Parallel — `RESOLVED`

**Evidence**
- Fix: commits 9e6f525 / 3838dcb / 259582c (PR #68, M3-8d) `promote catalog global to Catalog DI`.
- Current state at `phase4-coordinator/internal/tier2/catalog.go:81-105`:
```
type state struct { configured bool; loadFailed bool; active *ParsedCatalog }
// M3-8d (audit TEST-4) promoted the previous file-scoped `var global` into this type so tests
// can construct independent instances and run in parallel and so SIGHUP
// reload can be a pointer swap rather than an in-place mutation.
type Catalog struct { mu sync.RWMutex; st state }
func NewCatalog() *Catalog { return &Catalog{} }
```
- SIGHUP race resolved: `defaultCatalog atomic.Pointer[Catalog]` (line 123) + `ConfigureDefaultStrict` builds-validates-swaps in one operation (line 179) and the exported `SetDefault` shim was removed (codex fixup, see comments at line 170-175).
- The previously generic exported pointer-swap on a security-sensitive path is now `setDefault` (unexported) + `setDefaultForTest`.

**Original citation**
Audit: `tier2 catalog package-global singleton (catalog.go:81-84) forces ResetForTest everywhere, blocks t.Parallel, shared across at least three test packages, and carries a SIGHUP-reload race by design`.

**Fix delta**
Suggested: DI instead of global. Actual: hybrid — type extracted (`*Catalog` with DI constructor `NewCatalog()`), package-singleton kept behind atomic pointer (legacy callers still work via `Default()`), SIGHUP race fixed by atomic build-then-swap. The audit's exact suggestion (full DI) plus the codex-MED follow-up (close the pointer-swap escape hatch) both landed.

**Notes**
Baseline tier2 suite is green. Strength: pattern matches the audit's earlier comment about catalog tests under M3-8d's M3-8d fixup.

#### TEST-5 (Low) — Auth predicates fail open on empty operator key (merged into SECU-5) — `RESOLVED`

**Evidence**
- Fix: commit 0c331c4 (PR #37, M1-5) `fail-closed auth predicates (SECU-5/TEST-5)`.
- Predicate at `phase4-coordinator/internal/auth/tokens.go:129-140`:
```
func GatewayInternalBearerMatches(headers, operatorKey, serviceToken) InternalBearerKind {
    serviceMatch := serviceToken != "" && BearerTokenMatchesHeader(headers, serviceToken)
    operatorMatch := operatorKey != "" && BearerTokenMatchesHeader(headers, operatorKey)
    switch { case serviceMatch: ...; case operatorMatch: ...; default: return BearerKindNone }
}
```
  Both branches gate on `!= ""` so an empty key cannot match.
- Caller `internalBearerAuthorizedFull` (`buyer/server.go:2767-2779`) rejects on `BearerKindNone`.
- Regression test: `phase4-coordinator/internal/auth/tokens_test.go:45` `t.Fatal("empty operator key accepted (M1-5 regression)")` plus `TestGatewayInternalBearerMatchesEmptyConfigs` (line 90) and `TestGatewayInternalBearerMatchesScoping` (line 60).
- Dead code: `AuthorizedBearer` no longer present (audit-cited symbol was deleted per M1-5 brief).

**Original citation**
Audit: `Auth predicates fail open on empty keys (ws/server.go:1717-1718, billing/endpoints.go:63), masked solely by config.Validate() in a different file; no test locks the behavior`.

**Fix delta**
Suggested: fail-closed empty-key guard + regression test + delete dead AuthorizedBearer. Actual: all three landed in PR #37. M3-2 (PR #73) added the operator-key/service-token split, expanding the test surface.

**Notes**
Production-pending only on M3-2 cutover (CODE_SHIPPED_OPERATOR_PENDING for that finding), but the empty-key fail-closed invariant is locked by tests today.

#### TEST-6 (Medium) — No cross-service integration test between gateway and coordinator — `DEFERRED`

**Evidence**
- Deferral record: `audits/2026-06-10/MILESTONE_2_HANDOFF.md:117-150`:
```
### M2-9 — cross-service integration test (TEST-6)
Deferred to M3. Rationale: the audit's M2-9 spec calls for a new
... Recommend ticketing M2-9 as `M3-11` ...
- **M3-11** (NEW) cross-service integration test — deferred from M2-9
```
- Sticky header contract at `phase5-gateway/internal/router/server.go:1401-1405` (or its post-M3-9 location) and coordinator `internalBearerAuthorized` (`buyer/server.go:2754`) still has no cross-boundary `test/integration/` harness.
- `phase5-gateway/internal/router/integration_test.go` exists but is within-gateway (mocks coordinator via `cfg.Coordinator.BuyerURL = "http://coordinator.test"` + httptest stubs at lines 43, 154, 184, 221, 271, 312, 349, 381). It does not exercise the real coordinator binary.

**Original citation**
Audit: `No cross-service integration test between gateway and coordinator; the sticky-route header contract (server.go:1401-1405 ↔ coordinator internalBearerAuthorized) has zero cross-boundary coverage; beta/harness.py bypasses the gateway entirely`.

**Fix delta**
Suggested: M2-9 — new `test/integration/` exercising OAuth→key→chat→settle through both services. Actual: ticketed as M3-11, explicitly deferred. Deferral rationale documented.

**Notes**
This finding is the only Testing item still open. M3-11 should be picked up alongside the M2-1c (advanceToNextProvider rest) so the sticky-header contract is covered before any future header rename. Recalibrated severity unchanged.

#### TEST-7 (Low) — Swift tests (4,264 LOC, incl. SelfUpdate security regression locks) never run in CI — `RESOLVED`

**Evidence**
- Fix: commits 6bd8453 / bb11be6 (PR #71, M3-4) `drop dead swift-log + add Swift CI job (M3-4 / DEPE-6, TEST-7)`.
- CI job at `.github/workflows/ci.yml:61-85`:
```
  swift-tests:
    name: phase3-binary (swift test)
    runs-on: macos-15
    ...
      run: swift test --parallel
```
- Security-regression locks still present in `phase3-binary/Tests/macprovider-cliTests/SelfUpdateTests.swift`: `testReleaseAPIURLIgnoresEnvironmentFallback`, `testReleaseAPIURLRejectsUntrustedExplicitOverrideBeforeFetching`, `testReleaseSigningKeyIgnoresEnvironmentOverride`, `testUpdateRequiresSignedChecksumAsset`, `testValidatedUpdateDrainsBeforeReplacingAndRestartingLaunchd`.
- Baseline reports 219 Swift tests pass.

**Original citation**
Audit: `Swift tests (4,264 LOC, incl. self-update security regression locks) never run in CI`.

**Fix delta**
Suggested: Swift test job in CI on macos runner. Actual: shipped exactly that on macos-15 runner with `swift test --parallel`, plus the M3-4 paired removal of dead swift-log.

**Notes**
Strength preserved: `SelfUpdateTests.swift` security pinning is now CI-gated, not just locally green.

### Performance & resource safety (§3.6)

#### PERF-1 (Medium) — Gateway DB can never shrink (8 event tables + concurrency_reservations have RAISE(ABORT) BEFORE-DELETE triggers, no archival story) — `PARTIAL`

**Evidence**
- PR #49 / commit aa4df53 — `m2-4 (Parts A+B): gateway read-only handle + reservation cleanup (PERF-1, PERF-4)`
- New code at `phase5-gateway/internal/storage/sqlite/store.go:710-744` (DeleteTerminalQuotaReservations)
- Test `TestDeleteTerminalQuotaReservationsKeepsActiveAndDropsOld` passes (verified via `go test ./internal/storage/sqlite -run TestDeleteTerminal -count=1` → ok)
- Commit message explicitly notes `concurrency_reservations` and 8 event tables NOT touched — gated on Open Q4.

**Original citation**
audit `migrate.go:184-251`; current `phase5-gateway/internal/storage/sqlite/migrate.go:184-251` — the same 8 event-table `RAISE(ABORT)` BEFORE-DELETE triggers + `concurrency_reservations_no_delete` trigger still present verbatim (lines 184-251 unchanged).

**Fix delta**
Audit asked for an archival/retention story per table. Team shipped only the trivially-safe slice (quota_reservations terminal cleanup at 7d) plus a separate read handle. The append-only forever invariant on `usage_events`, `feedback_events`, `audit_events`, `api_key_events`, `demo_usage_events`, `capacity_signal_events`, `signup_events`, `demo_session_events`, and `concurrency_reservations` is unchanged. M2-4 Part C is the deferred archival design.

**Notes**
M2-4 Part C is listed as BLOCKED on Open Q4 in the milestone handoff. Operator action pending: Q4 decision (append-only-forever as requirement vs default), then a per-table archive/rotate or aged-delete design plus migration. Until then the underlying VPS disk/RAM ceiling concern is genuinely unresolved — though current row counts at N=3 make this a growth-shaped debt rather than a near-term hazard.

#### PERF-2 (Medium) — Synchronous SQLite swap-audit emit under pool RWMutex — `SUPERSEDED`

**Evidence**
- Audit `§3.6` line 127: `**[Medium] PERF-2** — merged into ARCH-2.` The audit author itself merged PERF-2 into the cross-cutting ARCH-2 / CODE-2 / PERF-2 finding at line 77.
- PR #46 (M2-2, commit 221f660): `swap-audit off pool lock` — collects swap events under the lock, dispatches via buffered channel after unlock per the milestone handoff.

**Original citation**
N/A — PERF-2 explicit body redirects to ARCH-2 at §3.1. See ARCH dimension verifier for the substantive status of ARCH-2/CODE-2/PERF-2.

**Fix delta**
No independent verdict to render here; SUPERSEDED by the merged ARCH-2 row.

**Notes**
Included for completeness because the audit lists PERF-2 in §3.6 numbering. The architecture-dimension verifier owns the substantive status.

#### PERF-3 (Medium) — Non-sargable unbatched retention DELETEs in coordinator request_log pruner — `PARTIAL`

_Recalibrated severity: Low — the high-blast-radius part (unbatched DELETE holding write lock across 6s billing budget) is resolved via batched LIMIT + yield. Remaining sub-aspect (julianday() non-sargable) is documented as deferred and only affects the worker-side scan, not the lock holding pattern._

**Evidence**
- PR #66 / commit 1511d18: `m3-1: batched retention DELETEs in coordinator pruners (PERF-3)` + fixup e6bff92 (`yield between prune batches + 90-day audit retention floor`).
- Current `phase4-coordinator/internal/requestlog/store.go:189-228` — `const pruneBatchSize = 500`, `pruneBatchYieldMs = 10`, batched loop, returns when partial batch detected.
- `go test ./internal/requestlog -run TestPrune -count=1` → ok.

**Original citation**
audit `requestlog/store.go:185-188` — single unbounded `DELETE … WHERE julianday(ts_utc) < julianday(?)`. Current `store.go:196`: `DELETE FROM request_idempotency_keys WHERE rowid IN (SELECT rowid FROM request_idempotency_keys WHERE julianday(created_at_utc) < julianday(?) LIMIT ?)` and `store.go:199`: equivalent for `request_log`. Batched + yields.

**Fix delta**
Audit suggested two trivial fixes: batched DELETE + LIMIT (shipped) and switch to RFC3339 lexicographic string comparison (NOT shipped). The `store.go:180-188` comment explicitly justifies leaving `julianday()` in place: "every ts_utc / created_at_utc write in this package uses time.RFC3339Nano, which strips trailing zeros in the fractional seconds — variable widths break lexicographic `<` ordering." Deferred to a follow-up that would also touch billing-table writes.

**Notes**
The sargability sub-aspect is real but lower-impact post-fix because each individual DELETE is now bounded to 500 rows with a 10ms inter-batch yield, so writer-lock blast radius is no longer 6s+. Operator-pending: nothing — code change is sufficient for the lock-hold concern.

#### PERF-4 (Medium) — Money path and explorer analytics serialize through single SQLite connection — `RESOLVED`

**Evidence**
- PR #49 / commit aa4df53 (Part A).
- Current `phase5-gateway/internal/storage/sqlite/store.go:30-50` (primary `Open` retains `SetMaxOpenConns(1)`) and `:52-78` (`OpenReadOnly`: ro DSN, `SetMaxOpenConns(4)`, ping-only init).
- `router.WithReadStore` option, six explorer handlers + `/v1/usage` routed through the RO handle (per commit body).
- Test `TestOpenReadOnlyServesReadsButNotWrites` passes (`go test ./internal/storage/sqlite -run TestOpenReadOnly -count=1` → ok).

**Original citation**
audit `store.go:38-39`; current `store.go:38-39`: `db.SetMaxOpenConns(1) / db.SetMaxIdleConns(1)` on the primary — unchanged, intentional, because writes still need to serialize through one conn. The fix is the second handle, not weakening the primary.

**Fix delta**
Exactly the cheap fix the audit suggested ("second read-only handle (WAL)").

**Notes**
None.

#### PERF-5 (Low) — pool.Registry.seenModels grows unbounded and is writable by provisional providers — `RESOLVED`

**Evidence**
- PR #47 / commit 128cd9e: `m2-5: ProvisionalRetentionDays pruner + bound seenModels (XPERF-2, PERF-5)`.
- Current `phase4-coordinator/internal/pool/provider.go:200-227`: `seenModelsByProvider map[string]map[string]struct{}` replacing the old registry-wide `seenModels`, with `const maxSeenModelsPerProvider = 32`.
- Removal on disconnect: `provider.go:327, 838, 852` all `delete(r.seenModelsByProvider, providerID)` in the removal/teardown paths.
- Tests pass: `TestModelKnownShrinksOnProviderDisconnect` and `TestSeenModelsCappedPerProvider` (`go test ./internal/pool -run "TestModelKnown|TestSeenModels" -count=1 -v` → both PASS).

**Original citation**
audit `provider.go:133,194,519` (never deleted, registry-wide). Current `provider.go:213` — keyed per-provider, dropped on session removal at `:327`, `:838`, `:852`. Original unbounded structure no longer exists.

**Fix delta**
Resolved exactly as suggested (bound per provider, drop on removal), plus the additional cap-per-provider defense for misbehaving provisional providers (32 entries).

**Notes**
None.

#### PERF-6 (Medium) — Demo traffic bypasses concurrency limiter — 3 parallel demo requests can saturate the pool — `RESOLVED`

**Evidence**
- PR #38 / commit a765675: `phase5-gateway: cap demo concurrency (PERF-6)`.
- Current `phase5-gateway/internal/router/chat_proxy.go:157-187`: comment cites M1-8 / PERF-6; demo subjects now go through AcquireConcurrency with `s.cfg.Quotas.DemoConcurrency` (default 2 per `config.go:169`) keyed on `subject.AccountID` (`demo:<ip>` with IPv6 /64 normalization).
- `TestDemoConcurrencyCap` passes (`go test ./internal/router -run TestDemoConcurrencyCap -count=1 -v` → PASS).

**Original citation**
audit `server.go:1362-1381` (the original `if !authn.Demo` bypass). The chat-proxy hot path has since been extracted into `chat_proxy.go`; equivalent block now at `chat_proxy.go:165-172` actively enforces `DemoConcurrency` for demo subjects rather than skipping. The bypass is gone.

**Fix delta**
Exactly the audit's prescription ("small fixed cap keyed on demo identity via existing reservation machinery").

**Notes**
Demo cap defaults to 2 (matching paying-account cap); configurable via `quotas.demo_concurrency`. Validation enforces positive value (`config.go:343-344`).

#### XPERF-2 (Medium) — Provisional admission state never pruned; whole-state JSON marshal per mutation — `PARTIAL`

_Recalibrated severity: Low-Medium — `ProvisionalRetentionDays` is now implemented and wired (the audit's headline complaint of "specified and dropped" is resolved), and rate-limiter state is now bounded. Remaining sub-aspect: whole-state `json.Marshal` per provisional mutation is unchanged. This is the lower-impact half (write-cost-per-mutation vs unbounded-growth) at current provisional pool sizes._

**Evidence**
- PR #47 / commit 128cd9e (M2-5).
- Current `phase4-coordinator/internal/ws/admission.go:221-271`: `Prune(cutoff)` drops records with `LastSeenAt` before cutoff, orphan rejections, and per-provider request windows; comment cites `M2-5 / XPERF-2`.
- Wired into the daily retention loop: `phase4-coordinator/cmd/coordinator/main.go:268` calls `startAdmissionRetentionPruner(shutdownCtx, wsServer.Admission(), cfg.Admission.ProvisionalRetentionDays, logger)`. Pruner helper at `main.go:371`.
- `cfg.Admission.ProvisionalRetentionDays` consumed (`config.go:123`, default 30 at `:303`).
- `TestAdmissionManagerPruneShrinksStateBeyondCutoff` passes (`go test ./internal/ws -run TestAdmissionManagerPrune -count=1 -v` → PASS).

**Original citation**
audit `admission.go:99-152,209-221` — whole-state Marshal under admission mutex per mutation; `ProvisionalRetentionDays` declared but unused.

Current `admission.go:113, 150, 167, 179, 199` still call `a.persistLocked()` after each mutation; `:273-285` `persistLocked()` still passes the full `AdmissionState{Admissions, Records, Rejected, RequestWindows}` (all four maps/slices cloned wholesale) to `SaveAdmissionState`, and `admission_store.go:62` is `raw, err := json.Marshal(state)` then a single-row upsert into the `admission_state` blob table.

**Fix delta**
Audit asked for two things: (1) pruning + actually-consumed `ProvisionalRetentionDays` (SHIPPED); (2) move off whole-state Marshal per mutation toward per-record persistence (NOT SHIPPED — the audit's term was "direct evidence pruning was specified and dropped" and the milestone wired pruning logic but kept the blob-per-mutation persistence model). The per-mutation blob marshal pattern is unchanged at admission.go:273-285 and admission_store.go:61-67.

**Notes**
The XSEC-1 compounding angle (unauthenticated callers minting provider_ids) is now mitigated by the per-record retention timer rather than by per-record persistence, which is a defensible deviation: bounded state + 30d evictions cap blast radius regardless of the underlying persistence shape. Whether the per-mutation full-state Marshal is acceptable depends on the working-set size at peak provisional load (currently small). Recommend tracking the per-record persistence work as a follow-up rather than reopening as a regression.

### Dependencies

#### DEPE-1 (Medium) — modernc.org/sqlite v1.33.0 retracted; 19 minors behind — `RESOLVED`

**Evidence**
PR #42 (commit b416bd0) bumped sqlite from v1.33.0 -> v1.52.0 in phase4-coordinator. Gateway already on v1.52.0 (PR #30 / commit fe87538). Baseline tests GREEN.

**Original citation**
Audit cited `go.mod:12` (coordinator) and `:7` (gateway) at v1.33.0.

**Fix delta**
Coordinator go.mod:12: `modernc.org/sqlite v1.52.0`. Gateway go.mod:8: `modernc.org/sqlite v1.52.0`. Both off the retracted version, matching M1-7 plan exactly.

**Notes**
Audit-acknowledged that no driver pathology was observed in 320k-request stress runs; the bump removes the retraction risk.

#### DEPE-2 (Medium) — No update process; goldmark indirect-vs-direct drift — `RESOLVED`

**Evidence**
`.github/dependabot.yml` exists (added M2-7 era) with monthly gomod schedules for `/phase4-coordinator`, `/phase5-gateway`, swift package-ecosystem for `/phase3-binary`, and github-actions. Goldmark drift fixed: `phase5-gateway/go.mod:6` now lists `github.com/yuin/goldmark v1.8.2` in the direct `require` block, matching its real use at `internal/router/pages.go:11`.

**Original citation**
Audit: "no dependabot/renovate; `go mod tidy` drift proven by goldmark mislabeled `// indirect` while directly imported, `pages.go:11` vs `go.mod:17`".

**Fix delta**
Dependabot present + goldmark moved to direct deps. Open-pull-requests-limit is 2 per ecosystem; monthly cadence matches the suggested fix.

**Notes**
No renovate, but dependabot was the audit-suggested choice.

#### DEPE-3 (Low) — swift-nio exact-pinned at 2.65.0 (~36 minors behind) — `RESOLVED`

**Evidence**
`phase3-binary/Package.swift` now pins `swift-nio` at `exact: "2.101.0"` (was 2.65.0). M3-4 / PR #71. Swift 219 tests pass per baseline.

**Original citation**
Audit: "swift-nio exact-pinned at 2.65.0".

**Fix delta**
2.65.0 -> 2.101.0 — 36 minors of upstream fixes folded in. Still exact-pinned (matches audit-recommended `bump on next release cycle`).

**Notes**
The mitigation noted in the audit (HTTPServer.swift:36 binds 127.0.0.1) remains true — verified line still reads `bootstrap.bind(host: "127.0.0.1", port: config.port)`.

#### DEPE-4 (Medium) — Binary ships zero third-party license attribution — `RESOLVED`

**Evidence**
PR #54 (commit 65e6199) + fixup a4e75a5 added `scripts/gather-third-party-notices.sh`. `phase3-binary/dist/package.sh:48-61` now gathers notices into `THIRD-PARTY-NOTICES.txt` and copies it into the staged tarball:
```
48: echo "==> Gathering third-party license notices..."
49: NOTICES_FILE="$OUT_DIR/THIRD-PARTY-NOTICES.txt"
51: "$REPO_ROOT/scripts/gather-third-party-notices.sh" "$NOTICES_FILE" "$RELEASE_DIR/SourcePackages/checkouts"
61: cp "$NOTICES_FILE" "$STAGE_DIR/THIRD-PARTY-NOTICES.txt"
```

**Original citation**
Audit: "`package.sh:52-60`; verified absent in shipped v1.2.4-v1.2.6 tarballs".

**Fix delta**
Matches M3-3 plan: notices generated from Package.resolved checkouts at package time.

**Notes**
New tarballs cut after this change will include attributions; old shipped tarballs (v1.2.4-v1.2.6) are still missing them but that is historical.

#### DEPE-5 (Low) — yaml.v3 officially archived/unmaintained — `NOT_RESOLVED`

**Evidence**
Both go.mod files still require `gopkg.in/yaml.v3 v3.0.1`:
- `phase4-coordinator/go.mod:11`
- `phase5-gateway/go.mod:7`

**Original citation**
Audit: "yaml.v3 officially archived/unmaintained (operator-config-only input; note and move on)."

**Fix delta**
No migration. The audit explicitly said "note and move on" — no milestone PR was planned for this.

**Notes**
Low severity remains correct: input scope is operator config (root-owned), not buyer-attacker-controlled. Staying with the archived package is acceptable until a replacement (e.g. `go-yaml/yaml.v3` fork or `goccy/go-yaml`) is adopted.

#### DEPE-6 (Low) — swift-log declared, linked, never imported — `RESOLVED`

**Evidence**
`phase3-binary/Package.swift` no longer declares `swift-log`. Reviewed `dependencies:` block — only `mlx-swift-examples`, `swift-nio`, `swift-argument-parser`, `Yams`. Targets do not reference Logging product. PR #71 (M3-4, commit 6bd8453) executed the drop.

**Original citation**
Audit: "swift-log is a declared, linked, never-imported dead dependency."

**Fix delta**
Matches plan exactly: removed from Package.swift. NOTICE.txt for swift-log still exists in `.build/index-build/checkouts/swift-log/` but that's a stale build cache, not a declared dependency.

**Notes**
Clean removal.

#### DEPE-7 (Low) — No Python manifest; cron runtime EOL Python 3.9 — `RESOLVED`

**Evidence**
PR #52 (commit 925af43) + fixup 91471f3 added `beta/requirements.txt`:
```
psutil>=5.9
pyyaml>=6.0
requests>=2.34.2
```
This covers harness.py's actual imports (requests + yaml), correcting the audit's "stdlib-only" claim.

**Original citation**
Audit: "No Python manifest; cron runtime is an EOL-Python-3.9 venv (verifier: `harness.py` imports `requests`+`yaml` too — the 'stdlib-only' claim was wrong)."

**Fix delta**
Manifest part RESOLVED. Cron runtime Python 3.9 EOL part is operator/runtime — a manifest does not upgrade the venv, but the audit's primary actionable was the manifest.

**Notes**
The `requests>=2.34.2` pin addresses a CVE noted in fixup commit message. Python interpreter upgrade is operator action outside the repo's reach.

#### DEPE-8 (Low) — gobwas/ws upstream dormant; StatusCode leaked in admission signature — `NOT_RESOLVED`

**Evidence**
`phase4-coordinator/go.mod:7` still pins `github.com/gobwas/ws v1.4.0`. The signature leak the audit called out persists at `phase4-coordinator/internal/ws/admission.go:78-80`:
```
func (a *AdmissionManager) Admit(hello Hello, pinned bool, connectedProvisional int) (pool.Tier, gobwas.StatusCode, string) {
    if pinned {
        return pool.TierPinned, 0, ""
```

**Original citation**
Audit: "gobwas/ws upstream dormant since May 2024 (current version; contingency note only — and `admission.go` leaks its `StatusCode` type in a signature, so a swap is slightly more than `internal/ws`-contained)."

**Fix delta**
No change. Audit framed this as "contingency note only" — no milestone task scheduled. Path B not triggered (gobwas still functional).

**Notes**
Low severity remains correct. If a swap is later needed, the StatusCode return type in admission.Admit will need to be wrapped or aliased before the internal/ws-contained refactor.

### DevEx & Ops (§3.8)

#### DEVE-1 (High) — No test/lint/vet CI — `RESOLVED`

**Evidence**
- PR #10 (commit c1b2e20) `m0: add CI workflow and fix TestConsoleStaticContracts`.
- `.github/workflows/ci.yml` exists with three required jobs: `coordinator` (go vet + test), `gateway` (go vet + test), `swift-tests` (PR #71 / M3-4 added macOS swift job).
- Triggers on `pull_request` and pushes to `main` (`ci.yml:3-7`).
- Pinned SHA for `actions/checkout@df4cb1c0` (v6).

**Original citation**
> Only `release.yml` exists (tag-triggered build+sign; even it runs no tests) (`release.yml:3-12`)

Current ci.yml jobs run `make vet-coordinator`, `make test-coordinator`, `make vet-gateway`, `make test-gateway`, `swift test --parallel`. Suites are green at HEAD (orchestrator baseline). Co-located with M2-6 Makefile so CI and local use identical targets.

**Fix delta**
Matches the suggested fix (PR-triggered go vet+test as required checks) and adds Swift coverage that was not originally specified.

**Notes**
Whether the jobs are *required* (branch-protection rule) cannot be proven from repo state — that is a GitHub settings concern. The workflow is present and runs on PRs.

#### DEVE-2 (High) — The 3am story — single Gmail channel co-hosted on VPS, no external check — `PARTIAL`

_Recalibrated severity: Medium (code-side fixed; external uptime is operator-pending)_

**Evidence**
- PR #15 / commit 950c0e2: `m0: monitor — preserve state on alerting-transition SMTP failure (M0-4a)`.
- `phase4-coordinator/dist/monitor/macprovider-monitor.py:163-191` now distinguishes `delivery == True/False/None`; `save_state()` is gated on `not alerting or delivery is not False`, so an SMTP failure during an alerting transition keeps the OLD state and refires next cycle (the audit-cited "state saved regardless of delivery" bug).
- External healthcheck: `audits/2026-06-10/OPS_HEALTHCHECK_SETUP.md` shipped (QW-3, PR #11) — a documented operator checklist (healthchecks.io / UptimeRobot), explicitly noting Claude cannot register external accounts.

**Original citation**
> Alerting is one Gmail channel that silently degrades to journald-only without creds (`macprovider-monitor.py:174-180`), permanently drops an alert if one SMTP send fails (state saved regardless of delivery, :159-171, :194-195), and runs on the same VPS it watches. No external uptime check exists anywhere.

Current :167-189 contains the WHY commentary and the conditional `if not alerting or delivery is not False: save_state(new_state)` — the structural drop-on-failure path is closed.

**Fix delta**
In-process fix matches the suggested fix's part (2). Part (1) (external uptime check) is operator action — code/docs side complete, registration is human work.

**Notes**
Downgrade to Medium reflects: (a) the silent-drop hole is closed, (b) journald-only mode no longer permanently seals alerting transitions, (c) external uptime depends on operator following OPS_HEALTHCHECK_SETUP.md. Until externally pinged, a Pearl outage during which the monitor itself also dies remains structurally invisible — hence not full RESOLVED.

#### DEVE-3 (Medium) — Production Go binaries hand-built, no script, no provenance, no rollback — `RESOLVED`

**Evidence**
- PRs #18/#19/#22/#29 (M0-5 version stamps + provenance series).
- `phase4-coordinator/scripts/build-linux.sh` exists; refuses to build with uncommitted/untracked changes (FORCE_DIRTY escape that appends `-dirty-forced` to the version stamp); injects `-ldflags -X main.version=${VERSION}` from `git describe --always --dirty --tags`.
- `phase5-gateway/scripts/build-linux.sh` symmetric.
- `phase4-coordinator/internal/buyer/server.go:600-605` now exposes `Version: s.version` (no longer hardcoded `"0.1.0"`); `:371` defaults to `"dev"`, real value injected via `-X main.version`.
- Rollback: `phase4-coordinator/dist/deploy-pearl-vps.sh:218-219` snapshots live binary to `coordinator.prev` with explicit `install -o macprovider -g macprovider -m 0755`; `audits/2026-06-10/ROLLBACK_PROCEDURE.md` documents one-mv revert.

**Original citation**
> The only build documentation is a comment (`deploy-pearl-vps.sh:9`); `/healthz` reports a hardcoded `"0.1.0"` (`buyer/server.go:576`)

Current `buyer/server.go:600` reads `Version string `json:"version"`` populated from `s.version` (set via `cmd/coordinator` main flag).

**Fix delta**
Matches suggested fix exactly (scripted build with -ldflags version stamp, /healthz exposes commit, rollback procedure documented).

**Notes**
Gateway build script is parallel.

#### DEVE-4 (Medium) — Gateway has no scripted deploy; C2 cross-check structurally skipped — `RESOLVED`

**Evidence**
- PR #40 / commit 0895d58 `m1-6: deploy gate hardening`.
- `phase5-gateway/dist/deploy-pearl-vps.sh` exists (244 lines), header explicitly cites "DEVE-4 in the audits/2026-06-10/REPO_AUDIT.md."
- `phase4-coordinator/dist/deploy-pearl-vps.sh:53-85` step 0 now requires `GATEWAY_CONFIG` (real, not `.example`) for the C2 cross-check; an absent file aborts with exit 5 unless `SKIP_C2_CHECK=1`.
- `check-deploy-config.sh:17-33` enforces both configs by default; the audit-cited fallback gap is closed.

**Original citation**
> the one cross-component safety check (C2 timer ordering — a *real past production incident*) is structurally skipped on every standard deploy because the coordinator script never passes the gateway config (`deploy-pearl-vps.sh:50`, `check-deploy-config.sh:18-19,62-74`)

Current coordinator deploy script invokes `check-deploy-config.sh "$CONFIG" "$GATEWAY_CONFIG"` (line 82), so the C2 check runs on every standard deploy.

**Fix delta**
Matches suggested fix and adds the codex 2026-06-11 follow-up that refuses `.example` fallback (sample config is documentation, not operational input).

#### DEVE-5 (Medium) — Coordinator config truth-on-laptop, deploys clobber VPS unconditionally — `RESOLVED`

**Evidence**
- PR #40 (M1-6).
- `phase4-coordinator/dist/deploy-pearl-vps.sh:104-140` step 1b: pulls live `/opt/macprovider/coordinator.yaml`, normalizes both sides (masking `_key/_secret/_token` fields, stripping comments), and `diff`s — aborts unless `ALLOW_CONFIG_DRIFT=1` is set; secrets never land on local disk unmasked.
- `:231-240` step ~7: dated remote-side backup `coordinator.yaml.bak-$BACKUP_TS` so a bad deploy can be inspected/reverted without re-pushing.

**Original citation**
> coordinator.yaml.example:79-83 documents the lesson; `deploy-pearl-vps.sh:73,79` scp with no diff/backup

Current flow: drift check runs before scp, dated backup taken before write — both gaps closed.

**Fix delta**
Matches the suggested fix (remote-config diff+backup before overwrite). Adds the secret-masking pipe so the local operator does not pull unmasked VPS secrets to a Mac during drift display.

#### DEVE-6 (Medium) — No Makefile/canonical dev commands; coordinator has no README — `RESOLVED`

**Evidence**
- PR #45 / commit 20c781f `m2-6: coordinator README + root Makefile (DEVE-6, DOCS-8)`.
- `/Users/augstar/macprovider-poc/Makefile` present with targets `test`, `vet`, `build-linux`, `check`, `fmt` plus per-service variants. Header comment explicitly cites "the 2026-06-10 audit (DEVE-6 / DOCS-8): keep CI and local on the same targets."
- `/Users/augstar/macprovider-poc/phase4-coordinator/README.md` exists (70 lines): Local Development, mockprovider, critical test sets, build-linux pointer.
- CI uses the same targets (`make vet-coordinator`, `make test-coordinator`, etc.) — fresh-session reproducibility is structurally aligned with CI.

**Original citation**
> the 25k-LOC coordinator has no README at all

Current state: README.md present at expected path with the canonical dev loop and test-set inventory.

**Fix delta**
Matches suggested fix (`make test|build-linux|check`); CI consumes the same targets.

#### DEVE-7 (Low) — Coordinator secret handling weak half of asymmetric pattern (plaintext YAML, root-monitor) — `CODE_SHIPPED_OPERATOR_PENDING`

**Evidence**
- PR #73 / commit 11f7c0c `m3-2: operator-key split + coordinator env-file + de-root monitor (SECU-4 + DEVE-7)`, plus codex fixups c99f1ca and 55bb5c0.
- `phase4-coordinator/dist/monitor/macprovider-monitor.service`: `User=macprovider`, `Group=macprovider`, `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, `PrivateDevices=true`, `ReadOnlyPaths=/opt/macprovider`, `StateDirectory=macprovider-monitor`, `EnvironmentFile=-/etc/macprovider/coordinator.env` (the env file the coordinator unit also reads — symmetric with gateway).
- `macprovider-monitor.py:54-61, 107`: `operator_key()` returns `os.environ.get("OPERATOR_KEY", "")` — no more regex-against-yaml-as-root.
- `deploy-pearl-vps.sh:194-208`: enforces `coordinator.env` perms `root:macprovider 0640`, mounts `/etc/macprovider` 0750.

**Original citation**
> plaintext `operator_key` in YAML regex-parsed by a root-running monitor, vs the gateway's env-file indirection

Current monitor unit reads env-file the same way the gateway does; user is unprivileged; FS is read-only outside `StateDirectory`.

**Fix delta**
Matches the M3-2 plan (env-file indirection + de-root). Asymmetry closed in code.

**Notes**
M3-2 is marked CODE_SHIPPED_OPERATOR_PENDING in the milestone summary — the cutover (move secret to coordinator.env, deploy new unit on Pearl) is operator work. Repo state cannot verify VPS file mode/path; the prior memory entry notes coordinator deploy was rolled back 2026-06-12.

#### DEVE-8 (Low) — 45 Phase-1 log/result artifacts git-tracked — `RESOLVED`

**Evidence**
- PR #52 / commit 925af43 `chore: M3-5 Phase-1 artifact cleanup (DEVE-8, DEPE-7)` plus fixup 91471f3 (psutil + requests CVE + anchored gitignore + HANDOFF refs).
- `git ls-files | grep -E '^(beta|phase1)/(logs|results)/'` returns empty.
- No `phase1-baseline/`, `phase1/`, `beta/logs/`, `beta/results/` directories present at HEAD.
- Fixup added anchored `.gitignore` entries + `beta/requirements.txt` (the DEPE-7 companion).

**Original citation**
> 45 Phase-1 log/result artifacts git-tracked

Current repo has zero such tracked files.

**Fix delta**
Matches suggested fix (git rm + keep REPORT.md, add requirements.txt for cron runtime).

**Notes**
No regressions seen in REPORT.md / decision log preservation.

### Docs

#### DOCS-1 (High) — README advertised unimplemented signed-receipt feature — `RESOLVED`

**Evidence**
- PR #12 (0e8283c) `docs(readme): truth sweep -- receipts to roadmap, console trim, drop version pin` — listed in M1-3 row of §5 task table.
- Current `README.md:22` now reads: `Every response will carry a signed receipt binding (prompt, output, provider) — verifiable inference, without a datacenter (planned, not yet implemented; see [Roadmap](#roadmap)).`
- The full v1 receipt schema block the audit flagged at lines 57,59-83 is gone; lines 55-83 now contain the Trust model + For Providers sections, with no present-tense receipt claim.

**Original citation**
Audit §3.1.5 cited `README.md:22,57,59-83` as present-tense receipts claim with full schema; cross-referenced `docs.md:119-124` honesty mandate.

**Fix delta**
Suggested: move receipts to a Roadmap section. Actual: in-line disclaimer (`planned, not yet implemented`) plus link to Roadmap section — equivalent under the SPEC-006 honesty rule.

**Notes**
Also satisfies the DOCS-1/SECU-2 duplicate — public present-tense claim no longer false.

#### DOCS-2 (Medium) — README claimed console management/billing features that don't exist — `RESOLVED`

**Evidence**
- PR #12 (0e8283c) consolidated with DOCS-1 sweep.
- Current `README.md:33-38`: heading `Console` now states `Today it ships two views: Browser chat. Pool dashboard.` — matches `frontdoor/console/index.html` reality (the dropped third view was provider-management).
- `grep -n 'earning\|billing\|manage' README.md` returns no false claims (billing mentioned only in architecture diagram + plaintext-trust paragraph as system property, not console view).

**Original citation**
Audit cited `README.md:31,35-40` claiming earnings/billing/manage views vs `frontdoor/console/index.html:493,530,539` (three real views).

**Fix delta**
Suggested: trim to three views. Actual: trimmed further to two views (browser chat + pool dashboard). Tighter than suggested — still passes the honesty test.

**Notes**
Open-Q7 (console roadmap vs copy) implicitly answered as 'trim, do not build the views'.

#### DOCS-3 (High) — No ops runbook for the live system — `RESOLVED`

**Evidence**
- PR #50 / commit 854f3f7 `m2-8: OPS.md + superseded banners on Phase-1 runbooks (DOCS-3, DOCS-5)` plus subsequent OPS.md updates (PRs #81, #86, commit 6ea46fd).
- `/Users/augstar/macprovider-poc/OPS.md` is 450 lines, header: `OPS.md — MacProvider production operations` with audience note: `the on-call operator. This is the canonical operations doc for the live streamvc.live stack. Phase-1 runbooks (RUNBOOK.md, CONTINUE_RUNBOOK.md) are superseded — see banners on those files.`
- `RUNBOOK.md:1` and `CONTINUE_RUNBOOK.md:1` both carry `> **SUPERSEDED — Phase 1 falsifiability script.**` banners.

**Original citation**
Audit §3.1.7: 'real ops knowledge lives in deploy-script comments and the decision log... recovery depends on one person's memory.'

**Fix delta**
M2-8 row of §5: 'topology, safe restart, settlement, monitor response, key rotation, gateway deploy; superseded banners on RUNBOOK/CONTINUE_RUNBOOK' — all delivered. Subsequent additions (FR-C9.4 lockout recovery §9; M3-2 cutover-watch §9) extend rather than deviate.

**Notes**
Final acceptance ('non-author can execute coordinator restart + rollback from OPS.md alone') is operator-side; document is present and structured.

#### DOCS-4 (Medium) — specs/README.md index 6 revisions stale on 3 of 12 spec families — `PARTIAL`

_Recalibrated severity: Low — drift admitted in-doc; partial mitigation acceptable_

**Evidence**
- `specs/README.md:1-16` lists SPEC-001 v1.3 (actual v1.4 per `SPEC-001-phase3-binary.md:3`), SPEC-003 v0.7 (actual v0.9.2 per `SPEC-003-open-onboarding.md:3`); SPEC-002, SPEC-006 etc. match.
- `specs/README.md:18` now contains an explicit drift disclaimer: `**Version of record is line 3 of each spec; do not trust this index for compatibility decisions — read the spec header.** This index drifts; the spec headers do not. When in doubt, grep -m1 '^\*\*Version' specs/SPEC-*.md.`
- M3-7 in §5 was `Specs index regen + CLAUDE.md/AGENTS version pointers` — handoff lists no PR shipped; CLAUDE.md side (DOCS-5) is in but index regen not committed.

**Original citation**
Audit §3.9 DOCS-4: 'specs/README.md indexes 3 of 12 spec families at versions ~6 revisions stale'.

**Fix delta**
Suggested: regen the index (M3-7). Actual: 2 of 3 stale families remain stale (SPEC-001, SPEC-003); the WHY (silent stale info) is partially mitigated by the new in-doc disclaimer pointing readers to spec headers. Honesty restored even though index numbers not refreshed.

**Notes**
A simple `awk` regen at release time would close this fully. Recalibrated Low because the user is now actively warned.

#### DOCS-5 (Medium) — CLAUDE.md fed stale 'locked' baselines to every agent session — `RESOLVED`

**Evidence**
- PR #50 (854f3f7) bundled DOCS-5 with the OPS.md work.
- Current `CLAUDE.md:151-156` reads: `Current versions of record: line 3 of each specs/SPEC-NNN-*.md, and the binaryVersion constant in phase3-binary/.../CoordinatorClient.swift. Do not hardcode versions in this file — they drift; the spec headers and the constant do not. See also specs/README.md for a generated index (also subject to drift, source of truth is each spec header).`
- No `v1.2.3 / v1.2.2 / v1.1.3` literals remain in the file.

**Original citation**
Audit §3.9 DOCS-5: `CLAUDE.md:151-153` pinned binary v1.2.3 / SPEC-001 v1.2.2 / SPEC-002 v1.1.3 vs actual 1.3.0 / v1.3 / v1.3.5.

**Fix delta**
Suggested: replace stale literals with pointers. Actual: exactly that — pointers to spec headers + `binaryVersion` constant, with explicit drift warning. Cleanly resolves WHY (agent sessions getting stale anchors).

**Notes**
None.

#### DOCS-6 (Medium) — Provider economics absent from any provider-visible surface — `RESOLVED`

**Evidence**
- PR #53 (18f76c0) `docs: provider economics & lifecycle reference (M3-6 / DOCS-6)` + fixup c19136a (PascalCase JSON keys + formula fix + SPEC-005 boundary).
- `/Users/augstar/macprovider-poc/doc/provider-economics.md` exists (Provider Economics & Lifecycle Reference) and is line-cited against source: `ComputeCredits in phase4-coordinator/internal/billing/formula.go:86-175`, with the gross/provider/operator credit decomposition explicit.
- Covers M3-6 acceptance: 'Formula in plain language, share, payout threshold, earnings endpoint usage, promotion criteria, sleep/reaping behavior'.

**Original citation**
Audit §3.9 DOCS-6: 'documented on zero provider-visible surfaces — money disputes are currently unresolvable by reference'.

**Fix delta**
Suggested: provider-visible doc covering rates/share/payout/earnings/promotion/reaping. Actual: in-repo `doc/provider-economics.md`. Provider-visibility caveat: this is a repo-relative path, not a marketing page linked from console; sufficient for current beta cohort who reach it via README/install flow.

**Notes**
Linkage from console/installer would broaden reach; not a gating issue for resolution.

#### DOCS-7 (Low) — Version-drift cluster (README badge, gateway README SPEC-006 pin, SPEC-002 dep self-contradiction) — `PARTIAL`

**Evidence**
- README: PR #12 dropped the hardcoded v1.2.5 string; `README.md:13` now uses a dynamic shields.io badge (`shields.io/github/v/release/augustas11/macprovider`) and no body text contradicts it. Resolved.
- Gateway README: `/Users/augstar/macprovider-poc/phase5-gateway/README.md:3` reads `Phase 5 gateway implementation for SPEC-006 v0.8.3.` Matches actual SPEC-006 v0.8.3 (specs/SPEC-006-buyer-api.md:3). Resolved.
- SPEC-002 dep line: `specs/SPEC-002-coordinator.md:4` says `Depends on: SPEC-001 v1.3 (Phase 3 binary wire protocol, locked)`. SPEC-001 actual is v1.4 (specs/SPEC-001-phase3-binary.md:3, '1.4 (2026-06-12, custom model selection')). The audit-era self-contradiction line at v1.2.1 (line 50, changelog) is preserved as history; the current header is internally consistent but trails the new SPEC-001 v1.4 by one minor revision.

**Original citation**
Audit §3.9 DOCS-7: README v1.2.5 vs badge v1.3.0; gateway SPEC-006 v0.5 vs actual v0.8.3; SPEC-002 self-contradiction on SPEC-001 dep.

**Fix delta**
Suggested: align all three. Actual: README + gateway done; SPEC-002 dep line trails by one minor (v1.3 vs v1.4). Compatible (SPEC-001 v1.4 is custom-model-selection on top of v1.3 wire protocol), but technically a drift.

**Notes**
Minor; covered by M3-7 'Add grep old version to release checklist' which is in §5 but no commit ships it standalone.

#### DOCS-8 (Medium) — No coordinator README + no canonical dev Makefile (paired with DEVE-6) — `RESOLVED`

**Evidence**
- PR #45 (20c781f) `m2-6: coordinator README + root Makefile (DEVE-6, DOCS-8)`.
- `/Users/augstar/macprovider-poc/phase4-coordinator/README.md` (70 lines): `Phase 4 coordinator — the hub of the MacProvider network...` opens with Local Development section.
- `/Users/augstar/macprovider-poc/Makefile` (39 lines) ships `test`, `test-coordinator`, `test-gateway`, `vet`, `vet-coordinator`, `vet-gateway`, `build-linux`, `check`, `fmt` — matches M2-6 acceptance criteria (`make test|build-linux|check`).
- Baseline: `make test` is green per the orchestrator's baseline note.

**Original citation**
Audit §3.7 DEVE-6 + DOCS-8: 'No Makefile/canonical dev commands; the 25k-LOC coordinator has no README at all.'

**Fix delta**
Suggested: `phase4-coordinator/README.md` + root Makefile with build/test/mockprovider/cross-compile/deploy-pointer. Actual: README + Makefile shipped; check target wraps `phase4-coordinator/dist/check-deploy-config.sh` (the deploy-gate, matches 'deploy-pointer' intent).

**Notes**
None.

---

## Task cross-check (§5)

### Quick Wins

| Task | Status | Title | Evidence |
|---|---|---|---|
| QW-1 | `RESOLVED` | CI vet+test for both Go modules | **Evidence** PR #10 / commit c1b2e20 `m0: add CI workflow and fix TestConsoleStaticContracts`; `.github/workflows/ci.yml` present. **Notes** Branch-protection required-checks status is operator config (cannot verify from tree). |
| QW-2 | `RESOLVED` | Fix TestConsoleStaticContracts (innerHTML) | **Evidence** Same PR #10 / commit c1b2e20 — console rewrite shipped alongside ci.yml. |
| QW-3 | `RESOLVED` | External healthcheck on both /healthz | **Evidence** PR #11 / commit e950d77 ships `OPS_HEALTHCHECK_SETUP.md`. Operator pinger configuration is the final mile. |
| QW-4 | `RESOLVED` | README truth sweep | **Evidence** PR #12 / commit 0e8283c — receipts → roadmap, console trim, drop version pin. Subsumes M1-3. |
| QW-5 | `NOT_RESOLVED` | SetMaxOpenConns(1) on coordinator stores | **Verifier override of cross-cutting agent.** `grep -rn SetMaxOpenConns phase4-coordinator/` returns ZERO hits at HEAD `fd3c652`. The audit's QW-5 IS M2-3 — `SetMaxOpenConns(1)` on coordinator store handles. Phase5-gateway already had it (`internal/storage/sqlite/store.go:38`)... |
| QW-6 | `RESOLVED` | dependabot.yml + go mod tidy | **Evidence** PR #16 / commit 10ee735 `deps: dependabot + go mod tidy (promote goldmark to direct)`. |
| QW-7 | `RESOLVED` | Regenerate specs/README.md; CLAUDE.md de-version | **Evidence** PR #17 / commit 120fccc. M3-7 explicitly marked already-shipped via QW-7 in MILESTONE_3_HANDOFF.md:86. |

### Milestone 0 — Safety net

| Task | Status | Title | Evidence |
|---|---|---|---|
| M0-1 | `RESOLVED` | Test/vet CI for both Go modules on PR + push | **Evidence** PR #10 / commit c1b2e20. **Notes** Branch-protection enforcement is operator config (cannot verify required-checks from working tree). |
| M0-2 | `RESOLVED` | Fix broken console contract test | **Evidence** PR #10 / commit c1b2e20 (combined CI + console fix per audit sketch). |
| M0-3 | `RESOLVED` | De-flake load-sensitive tests | **Evidence** PR #13 / commit 324c561. |
| M0-4 | `RESOLVED` | External uptime monitoring + monitor delivery fix | **Evidence** PR #11 OPS_HEALTHCHECK_SETUP + PR #15 commit 950c0e2 `m0: monitor — preserve state on alerting-transition SMTP failure`. External pinger configuration is operator-side. |
| M0-5 | `RESOLVED` | Version-stamped build + rollback | **Evidence** Phase 1 PR #18 / commit f9d8040 + Phase 2 PR #19 / commit 2f24109 + later #22 #29. PR #76 (5b3f26f) fixed nginx-config drift surfaced by first M0-5/M1-6 deploy — confirming the gate fired. |

### Milestone 1 — Critical fixes

| Task | Status | Title | Evidence |
|---|---|---|---|
| M1-1 | `CODE_SHIPPED_OPERATOR_PENDING` | Wire provider tokens end-to-end | **Evidence** PR #41 (89de1e6) pinned-tier; PR #44 (e26b245) self-serve provisional closing Q2. SPEC-003 iterated v0.8.1→v0.8.4 (Entries 67/75/76). 2026-06-12 coordinator deploy noted as rolled back per MEMORY. **Notes** Code in; `require_provider_tokens=true` flag-flip + binar... |
| M1-2 | `RESOLVED` | Fix two failover divergences | **Evidence** PR #36 / commit 27559ae. Money-path regression tests per AGENTS.md. |
| M1-3 | `RESOLVED` | README/console truth sweep | **Evidence** Subsumed by QW-4 (PR #12, commit 0e8283c) per MILESTONE_1_HANDOFF.md:4. |
| M1-4 | `RESOLVED` | Rate-limit coordinator /ws/provider | **Evidence** PR #39 / commit a425900. Touches nginx + ws/server.go. |
| M1-5 | `RESOLVED` | Fail-closed auth predicates | **Evidence** PR #37 / commit 0c331c4. |
| M1-6 | `PARTIAL` | Deploy-gate hardening | **Evidence** PR #40 / commit 0895d58 (Parts A+B). **Notes** Part C (tier-2 posture flag assertions) deferred — gated on Open Q3 per MILESTONE_1_HANDOFF.md:60-65. |
| M1-7 | `CODE_SHIPPED_OPERATOR_PENDING` | Bump modernc.org/sqlite | **Evidence** PR #42 / commit b416bd0 (v1.33.0 → v1.52.0). **Notes** 24h Pearl canary listed as operator follow-up. |
| M1-8 | `RESOLVED` | Cap demo concurrency | **Evidence** PR #38 / commit a765675. |

### Milestone 2 — High-leverage

| Task | Status | Title | Evidence |
|---|---|---|---|
| M2-1 | `PARTIAL` | Extract single forwardWithFailover (strangler) | **Evidence** M2-1a PR #48 / commit 8f18f5a MERGED. M2-1b PR #61 OPEN, DRAFT (`refactor/m2-1b-unify-result-classification`). M2-1c not opened. **Notes** PARTIAL by design — AGENTS.md serial-merge discipline; 1a behavior-diff-free, 1b in draft, 1c pending. |
| M2-2 | `RESOLVED` | Move swap-audit emit off pool lock | **Evidence** PR #46 / commit 221f660 — split ApplyHeartbeat + cap-64 buffered channel. |
| M2-3 | `NOT_RESOLVED` | SetMaxOpenConns(1) on coordinator stores | **Verifier override of cross-cutting agent.** `grep -rn SetMaxOpenConns phase4-coordinator/` returns ZERO hits at HEAD `fd3c652`. The audit's QW-5 IS M2-3 — `SetMaxOpenConns(1)` on coordinator store handles. Phase5-gateway already had it (`internal/storage/sqlite/store.go:38`)... |
| M2-4 | `PARTIAL` | Gateway retention/archival + RO handle | **Evidence** PR #49 / commit aa4df53 Parts A (RO handle) + B (DeleteTerminalQuotaReservations). Part C BLOCKED on Open Q4 per MILESTONE_2_HANDOFF.md:60-86; PR #58 (Q4 ruling) OPEN not merged. **Notes** Parts A/B in; Part C remains gated. |
| M2-5 | `RESOLVED` | ProvisionalRetentionDays + seenModels bound | **Evidence** PR #47 / commit 128cd9e. |
| M2-6 | `RESOLVED` | Coordinator README + root Makefile | **Evidence** PR #45 / commit 20c781f; `phase4-coordinator/README.md` and `Makefile` present at expected paths. |
| M2-7 | `RESOLVED` | Dependabot + tidy | **Evidence** Shipped as QW-6 (PR #16, commit 10ee735); M2 row omitted to avoid duplicate work. |
| M2-8 | `RESOLVED` | OPS.md + superseded banners | **Evidence** PR #50 / commit 854f3f7 — `OPS.md` present at repo root. Subsequent commits 6ea46fd + fd3c652 tighten OPS.md against first M0-5/M1-6 deploy and path-filter the M3-2 cutover-watch grep. |
| M2-9 | `DEFERRED` | Cross-service integration test | **Evidence** MILESTONE_2_HANDOFF.md:117-135 explicitly defers to M3 as M3-11; rationale: needs top-level Go module with `replace` directives + subprocess + port-handling work. |

### Milestone 3 — Quality & polish

| Task | Status | Title | Evidence |
|---|---|---|---|
| M3-1 | `RESOLVED` | Sargable, batched retention DELETEs | **Evidence** PR #66 / commit 1511d18. **Notes** Option A applied — kept `julianday()` predicate because RFC3339Nano width-variability breaks lexicographic compare; sargable comparison filed as M3-1 follow-up (MILESTONE_3_PHASE23_HANDOFF.md:64-68). |
| M3-2 | `CODE_SHIPPED_OPERATOR_PENDING` | Operator key split + de-root monitor | **Evidence** PR #73 / commit 11f7c0c. OPS.md §9 post-M3-2 cutover procedure (OPS.md:189-229). Follow-up fd3c652 path-filters the cutover-watch query to `/internal/*`. **Notes** Live cutover (rotate keys on Pearl, watch audit log 24h, drop legacy fallback) is operator action. |
| M3-3 | `RESOLVED` | THIRD-PARTY-NOTICES.txt in release tarball | **Evidence** PR #54 / commit 65e6199. Hardened in audit-fixup round (symlink-traversal containment, realpath, `find -P`). |
| M3-4 | `CODE_SHIPPED_OPERATOR_PENDING` | swift-nio bump + drop swift-log + Swift CI | **Evidence** PR #71 / commit 6bd8453. Part A (nio bump) shipped via Dependabot PR #25 + Sendable fix PR #32. **Notes** `swift-tests` job non-blocking; required-checks flip is operator action. |
| M3-5 | `RESOLVED` | Phase-1 artifacts cleanup | **Evidence** PR #52 / commit 925af43. |
| M3-6 | `RESOLVED` | Provider economics doc | **Evidence** PR #53 / commit 18f76c0; `doc/provider-economics.md` present (relocated out of audits/ during architect fixup). |
| M3-7 | `RESOLVED` | Specs index regen + CLAUDE.md de-version | **Evidence** Shipped as QW-7 (PR #17, commit 120fccc) per MILESTONE_3_HANDOFF.md:86. |
| M3-8 | `RESOLVED` | Code polish bundle (writeError unification, Swift dead code, capacity tier JSON, tier2 catalog DI) | **Evidence** M3-8a PR #64 (c4d1ac1), M3-8b PR #65 (2b20af5), M3-8c PR #63 (b91eda4), M3-8d PR #68 (9e6f525). All four merged; M3-8d touches model-hash verification path — reviewed per AGENTS.md. |
| M3-9 | `PARTIAL` | Gateway server.go file split (Phase 1) | **Evidence** PR #55 / commit c33ed08 — pure file split, no behavior change. **Notes** PARTIAL per MILESTONE_3_PHASE23_HANDOFF.md:72 — disclosure-as-subpackage extraction + server_test.go cluster split filed as M3-9 follow-up. |
| M3-10 | `DEFERRED` | Hoist logRowWithBilling into billing-recorder type | **Evidence** MILESTONE_3_PHASE23_HANDOFF.md:57-60 — deferred until M2-1 (`logRowWithBilling`) fully settles. Pairs with M2-1c. |

---

## Strengths preservation check


**Architecture & Code Quality (§3.2 + §3.3)**

- `✓` Explorer handlers have zero direct SQL (all behind explorer/store.go)
- `✓` Acyclic dependency graph with interface wiring at composition root
- `✓` WriteHotPath atomic request_log+ledger tx with quarantine-don't-lose fallback
- `✓` Gateway's role-segregated storage interfaces
- `✓` Fully-typed WS wire protocol with graceful unknown-frame handling
- `?` Reserve→settle→refund covered on every traced branch with reaper backstop — Out of scope for this dimension's file:line work; gateway billing/reaper paths not re-traced here
- `✓` Fault injection isolated behind //go:build testfaults
- `✓` Load-bearing concurrency invariants documented in code

**Security**

- `✓` Secrets clean in git (full-tree entropy scan: zero hits)
- `✓` API keys hashed constant-time
- `✓` SQL fully parameterized
- `?` OAuth CSRF/scope/redirect correct — No PR in this milestone batch touched OAuth handlers. Original audit verifier-confirmed; no regression vector introduced by M1/M2/M3 PRs reviewed.
- `✓` Self-update verifies signature before download with traversal guards

**Testing**

- `✓` behavior-named money tests (TestWriteHotPath_503_NoLedgerRows)
- `✓` eventually() helpers done right
- `✓` t.TempDir() SQLite isolation everywhere
- `✓` security-regression pinning in SelfUpdateTests.swift
- `✓` account-scoping regression lock TestConversationKeyIsAccountScoped

**Performance & resource safety (§3.6)**

- `✓` bounded relay channels with ErrRelayBackpressure fail-fast
- `✓` 1MB/16MB caps on every read path
- `✓` universal outbound timeouts
- `✓` sticky map TTL+10k sweep
- `✓` goroutine exit paths verified clean
- `✓` purpose-built indexes matching query patterns in both stores

**Dependencies**

- `⚠` Excellent dependency posture: gateway has two direct deps — phase5-gateway/go.mod direct require block now lists 3 direct deps (goldmark, yaml.v3, sqlite). Goldmark is newly direct because of DEPE-2 reclassification fix (was being used in pages.go but mislabeled indirect). This is a more honest manifest, not bloat. Still a minimal direct-dep surface.
- `✓` Everything exact-pinned and lock-filed
- `✓` Zero vendored/CDN code
- `✓` Deliberate shared CGO-free SQLite driver enabling cross-compile deploy

**DevEx & Ops (§3.8)**

- `✓` check-deploy-config.sh encodes actual incidents and hard-fails
- `✓` Idempotent coordinator deploy with provider-connected restart refusal + FORCE_RESTART escape
- `✓` Release workflow SHA-pins actions, validates tag format, deletes signing key, re-verifies post-publish
- `✓` Uniform systemd hardening with RAM caps sized to host
- `✓` Transition-based (not poll-spam) monitor design

**Docs**

- `✓` tier-1 disclosure in docs.md:115-126 is the gold standard the README should be held to
- `✓` gateway README is a model component doc
- `✓` spec headers with audit-finding-cited changelogs
- `✓` DECISION_CRITERIA.md's 57 dated append-only entries are genuine institutional memory

---

## New issues surfaced during verification

Applied the original audit's discipline: file:line evidence required, default to false unless refutable. Zero High-severity new issues.

### [Medium] M2-1b draft + M2-1c pending — three failover loops remain on main

- **Where:** phase4-coordinator/internal/buyer/server.go handleChatCompletions; PR #61 DRAFT
- **Why:** Audit's centerpiece refactor (ARCH-1/CODE-1) is in-flight but three near-duplicate failover loops still exist on main (HEAD fd3c652). Every retry-semantics change must be hand-synced across copies until M2-1c lands. Recalibrating Medium because M1-2 already fixed the two confirmed divergences.

### [Low] DECISION_CRITERIA Entry-number collisions (60, 67, 68, 71 multi-claimed)

- **Where:** beta/DECISION_CRITERIA.md:344 Entry 60 renumbered; :366 Entry 68 (originally 60) renumber note; Entry 67/71 collisions called out in :354/:356
- **Why:** Parallel autopilot/manual sessions independently claimed the same monotonic entry numbers (60 for both M2 batch and Open-Q2 ruling; 67/71 collisions). PR #83 (7ce7faf) partially addressed. Process gap: entry-number reservation isn't enforced; cross-references can drift.

### [Low] PR #58 (Open Q4 ruling) still OPEN — ruling not on main

- **Where:** PR #58 state=OPEN; beta/DECISION_CRITERIA.md Entry 63 on main is M3-5, not Q4
- **Why:** Q4 ruled in PR body (archive-rotate to cold storage) but canonical decision-log entry has not landed. Future PERF-1 / M2-4 Part C work lacks authoritative on-main reference until #58 merges.

### [Low] M3-1 follow-up: sargable RFC3339Nano comparison still pending

- **Where:** phase4-coordinator/internal/requestlog/store.go (julianday predicate retained per MILESTONE_3_PHASE23_HANDOFF.md:64-68)
- **Why:** RFC3339Nano writes are variable-width (`.` 0x2E < `Z` 0x5A) so lexicographic compare is silently wrong at fractional-second boundaries. PERF-3 batched-DELETE shipped, but the index is still defeated by julianday(). Low risk now; degrades as request_log grows.

### [Low] Q3 (tier-2 posture) silently deferred — no DECISION_CRITERIA entry

- **Where:** beta/DECISION_CRITERIA.md (no entry); MILESTONE_1_HANDOFF.md:55-65
- **Why:** Operator instructed 'Defer Part C entirely' during M1 autopilot but the deferral survives only inside an audit handoff doc, not a dated decision-log entry. Same pattern as Q6. Future agent sessions can't grep DECISION_CRITERIA for tier-2 posture status.

### [Medium] Verifier-surfaced: QW-5/M2-3 (SetMaxOpenConns(1) on coordinator) marked done but never shipped

- **Where:** `phase4-coordinator/cmd/coordinator/main.go:57-84` — three `*sql.DB` handles opened without `SetMaxOpenConns(1)`. `grep -rn SetMaxOpenConns phase4-coordinator/` returns zero hits at HEAD `fd3c652`.
- **Why:** `MILESTONE_2_HANDOFF.md:5-7` claims "M2-3 (gateway `SetMaxOpenConns(1)` parity) ... already covered by Quick Wins QW-5" but the audit's QW-5 IS M2-3 — they are the same task targeting the coordinator side. The gateway already had `SetMaxOpenConns(1)` pre-audit (`internal/storage/sqlite/store.go:38`); that's what the audit pointed at as the parity baseline. The handoff text is a clerical error and the underlying ARCH-3 risk (latent SQLITE_BUSY tail-latency / `request_log_failed` 500s under coordinator write contention) remains. Trivial fix; add `db.SetMaxOpenConns(1)` to each of `tokenStore.DB()`, `reqLogStore.DB()`, `auditStore.DB()` at the open sites.

---

_End of verification report. See `REMAINING_WORK.md` for the severity-ordered punch list and operator checklist._
