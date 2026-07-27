# RESEARCH — Trust-Minimized Benchmark & Catalog Roadmap

Date: 2026-07-27 (r4 — revised after three adversarial rounds + codex security/architect audits)
Status: research document (non-normative; basis for GitHub issues and implementation tracking)
Scope: catalog, benchmark, hardware verification, provider admission, routing, buyer/provider UX trust model
Related: #744, #745 (closed, fixed by #751), #742 (closed, fixed by #748), #687, #584, #582, PR #772, SPEC-002, SPEC-004, SPEC-005, SPEC-006, SPEC-008, SPEC-010, SPEC-013, SPEC-017, SPEC-022, SPEC-023 (v0.8), SPEC-027, SPEC-029, SPEC-030, SPEC-031, SPEC-032, SPEC-033, SPEC-034, SPEC-036

Evidence tags:

- **[E-code]** — verified by reading code at `origin/main` `8a39c636` (2026-07-27). This branch adds only this document; no code differs from that base.
- **[E-spec]** — verified by reading a spec/runbook/decision-log document **in this repo**
- **[E-issue]** — from a GitHub issue or PR body (not in-repo; re-readable via `gh`)
- **[E-session]** — reported in a prior operator session; not re-verified this pass (read-only Pearl DB query attempted, blocked by session policy)
- **[I]** — inference; a judgment, not an observation

---

## 0. If You Read Nothing Else

**One measurement decides whether this roadmap's central thesis is executable.** The thesis (§1.5) is that coordinator-observed buyer-path performance should replace provider self-report as the authority for privileges. Every high-value item consumes per-(provider, model, workload-bucket) observed aggregates. Nobody has checked that current buyer demand produces enough requests to fill those buckets. At 1–2 providers and prebeta demand, splitting traffic across (provider × model × workload class × concurrency) plausibly yields single-digit or zero samples per bucket — in which case the observed-evidence machinery degrades to its own fallbacks and the operator has bought a timer.

**R0 (§10) is therefore the first item: query the existing `request_log` for requests/day per (provider, model) and per candidate bucket.** It costs an afternoon, uses data already persisted, and it gates R4/R5/R9. Do not schedule the probation block before that number exists.

**The committed minimum path, if nothing else ships** (~12–20 operator hours, no open questions blocking any of it):

| | Item | Why it is unconditional |
|---|---|---|
| 1 | **R2** — overclaim remediation (`README.md:22`, SDK doc) | Violates SPEC-006:343's own normative rule; buyer-facing; no dependencies |
| 2 | **R3a** — ceiling-drift *detection* (persist `MaxAdmittedMinRAMGB`, alert on heartbeat model switch) | Closes the one Tier-0 technical hazard — a silent switch invalidating the only live integrity chain — without routing exclusion, so §11's sole-provider questions do not block it |
| 3 | **R1a** — nullable `ttft_ms`/`decode_ms` columns on `request_log` | Only item whose value strictly increases with earlier start; columns only, no classifier |
| 4 | **R0** — the demand-volume query | Decides everything downstream |

Everything past that line is **conditional on R0's answer** and is presented as analysis, not as an approved plan.

---

## 1. Executive Summary

MacProvider today has a **strong integrity chain over the wrong root**. The catalog signing pipeline, the append-only release ledger, the model-hash consistency checks, the route snapshots, and the settlement receipts are all real and mostly well built — but every performance claim and almost every identity claim they protect originates as **provider self-report**. Signing, verifying, and receipting a self-reported number does not make it true; it makes it *tamper-evidently* self-reported.

1. **Catalog `bench_gate` numbers are not evidence.** Of the 9 live rows, 5 have no throughput benchmark behind their gate, and the 4 "measured" rows were measured on a single M5 32 GB machine — some while the #745 bug meant the benchmark loaded a *different model* than the one it was recorded under (§4.1). Both client and coordinator correctly treat these gates as advisory-only. [E-code, E-issue]
2. **The hardware verifier proves identity anchoring, not benchmark truth.** SPEC-033 §10.2 says so itself: "string-level self-consistency + an operator trust anchor, not proof the benchmarks ran on that hardware"; "cross-provider borrow is blocked, self-fabrication is not." The anchored `hardware_identity_hash` is an HMAC over a locally generated random file plus two sysctl strings — not device-rooted, and **rotatable by deleting one file** (§3.4, §4.11). [E-spec, E-code]
3. **Nothing in production ties serving to verification.** The SPEC-032 hello gate is off in the live Pearl overlay (verified 2026-07-22), canary off, telemetry drift off, losslessness off, SPEC-036 unwritten. The only enforcing integrity mechanism is Tier-2 Pillar A hash verification — a consistency check on a value the provider computes about itself (§4.6). [E-code, E-spec]
4. **Even with the hello gate on, the capacity ceiling has no routing consumer.** SPEC-032 FR-HG7 is a spec-acknowledged CRITICAL gap: a provider admitted on a small model can heartbeat-switch to a larger or uncatalogued model and the pool applies it unconditionally (§4.5). [E-code, E-spec]
5. **The most valuable unexploited asset is coordinator-observed performance — subject to §0's volume caveat.** The coordinator already measures true per-request TTFT and decode wall-time on every buyer request and throws them away, because `request_log` has no columns for them (§4.7). It is the only performance signal the provider does not author. Its power is **bounded three ways** (§3.3): substitution of cheaper work beats it, output buffering distorts it, and it needs sample volume that may not exist.

**Why the #744 provenance/signing work is not enough by itself** (required finding): PR #772 was the right *labeling* move, but it changes what we *say* about the numbers, not where they *come from*. Three specifics: (a) the provenance values in production are a **hardcoded client-side backfill table**, not signed catalog bytes — the signature covers zero provenance bytes, and the coordinator accepts nil and substitutes nothing; (b) provenance "does not by itself admit or reject cached benchmarks" (SPEC-023 §3.1) — metadata about an advisory field; (c) the enforcement pipeline (`ResolveMaxAdmission`, hash checks, settlement) never reads provenance at all. Signing harder or labeling better cannot fix a system whose admission evidence is fabricatable by construction (§4.2, §4.3).

**The upgrade question** (required finding): the answer is **not** "lock the provider to the first model at hello" — that blocks legitimate upgrades and invites identity churn. §6 defines the alternative, with the load-bearing correction from review: **observed latency/throughput can only *demote*, and can only gate capacity *within an already-proven model class*.** It cannot authorize a cross-class ceiling raise, because model substitution scores *better* on every latency metric than honest service of the larger model. Cross-class raises need a model-discriminating signal, not a speed signal (§3.3, §6.3 Step 4).

**What this roadmap deliberately does not do**: it does not gate supply growth on adversarial defenses the current cohort has never needed. Every incident in the log has been honest-system error, not attack (§9.1). The scarce resource is providers. r3/r4 accordingly **shrink** the committed plan (§0), gates the expensive block on a measurement (R0), cuts one item outright (former R6), and marks the probation design as conditional analysis rather than approved work.

---

## 2. Current System Map

### 2.1 Components and their real function

| Component | Where | What it actually does | Prod status |
|---|---|---|---|
| Catalog signing | `scripts/resign-autotune-static.sh`, `scripts/catalog-release.py`, `AutotuneRecommend.swift:1342-1488`, `internal/buyer/autotune_feeds.go:144-205` | Ed25519 over exact feed bytes; keyring v4 `active` / v5 `bridge`; append-only ledger + tombstones; freshness/policy/pairing checks | Live; v4-signed `published-2026-07-10-catalog-recovery-v1` |
| Catalog rows | `phase3-binary/dist/static/autotune-candidates.json` (+ canonical + baked, byte-parity enforced `catalog-release.py:1594-1602`) | 9 rows: `model_id`, `model_revision`, `model_sha256`, `min_ram_gb`, `min_bandwidth_tier`, `bench_gate{min_sustained_tps,max_4k_ttft_ms}`, `notes` | Live; **no row carries `bench_gate.provenance`** |
| Autotune recommend (SPEC-023 v0.8) | `AutotuneRecommend.swift`, `AutotuneCommand.swift` | Single-replicate 4k probe per candidate (`Stage1Iterator.swift:428-624`); ranks by `payout × measured_tps × demand × shortage` (`:1690-1696`); hard vetoes thermal/swap/buyer-TTFT/cached-admission (`:1833-1836`); bench_gate advisory (`:1874-1886`) | Live client-side |
| Hardware evidence submission | `AutotuneHardwareEvidence.swift`, `internal/onboarding/hardware_evidence.go` | JCS-canonical blob POSTed with **bearer token only — no signature over the evidence** (`:243-252`); dedupe by `evidence_sha256` | Live, default-on |
| Hardware verifier (SPEC-033) | `internal/stats/hardwareverify/verify.go`, `cmd/stats-hardware-verifier/`, migrations 007/008/015/016/017/019 | Shape/consistency checks + 4-tuple operator trust match + chip profile; `waiting_trust` = all gates passed except operator rows; dual-control approval (019) | Live worker on Pearl |
| Hello admission | `internal/ws/server.go:2116-2464` | Catalog envelope; model-hash vs signed catalog (`:891-916`); SPEC-032 gate `:2332-2394` → `ResolveMaxAdmission` (`internal/autotune/gate.go:18-58`) computes a ceiling from the provider's **own** benchmarks | Envelope + hash live; **gate off** |
| Heartbeat | `internal/ws/server.go:4261-4362`, `internal/pool/provider.go:1811-1923` | Re-sends all capability fields; pool overwrites `ModelID`, RAM, context, concurrency, TPS estimate **unconditionally** (`:1851`); no ceiling re-check | Live |
| Routing | `internal/pool/provider.go:409-443`, `internal/routing/filter.go:134-188`, `internal/routing/candidate.go:66-92`, `internal/buyer/server.go:5637-5647, 6385-6450` | Eligibility = auth state + catalog mode + no pending receipt key + ready + free slots; match = case-insensitive `ModelID` equality + self-reported context + Tier-2 hash predicate; "fast" ranks on `EffectiveThroughput` | Live; `require_hash_verified: true` |
| **Gateway quota / usage / settlement** | `phase5-gateway/internal/storage/` (`usage_events` DDL `sqlite/migrate.go:9`, `ReservationSettlement` `types.go:147-156`, `sqlite/store.go:1291-1320`), SPEC-006:179, :1007-1011 | Owns buyer quota reservation, `usage_events`, and reservation settlement — **the surface any probation pricing change must touch** | Live |
| Coordinator billing / payout | `internal/billing/route_snapshot.go`, `settlement_receipts.go`, `payout.go` | Receipt binds request↔snapshot↔model_hash↔usage; `payout.go:118-128` **voids a payout row when `payableProvider < minPayoutCredits`** | Shipped; settlement mode default `observe` |
| Tier weighting (existing) | `internal/routing/candidate.go:71-92`; `pool.TierProvisional` (`pool/provider.go:119` — **a per-provider scalar**) | `Weights{Pinned:1.0, Provisional:0.3}`; SPEC-002 v1.1 §5 Step 2.5. **Also the canary sanction state**: `pool/provider.go:1352-1355` bans a `TierProvisional` provider on canary trip while pinned providers only degrade | Live |
| Canary (SPEC-031) | `internal/ws/server.go:3525-3681`, `canary_probe.go`, `internal/canarycorr/` | Nonce-echo liveness + latency gates + sanctions; FR-CAN22 sole-provider floor (`pool/provider.go:1348`, precedes the tier branch) | **Disabled in prod** |
| Tier-2 Pillar A | `internal/tier2/catalog.go:331-372, 751-757` | Provider-reported boot-time hash vs signed catalog; `mismatch`/`invalid` route-excluded | **Enforcing (the only one)** |
| OPoI / telemetry drift | `internal/pow/drift.go` | WARN-only; compares provider heartbeat self-report against provider benchmark self-report | Dormant |
| Losslessness (SPEC-030) | `internal/ws/losslessness.go` | TV-distance between plain/speculative arms of the same provider | Shipped, disabled, verdict fn test-only |
| Compute-integrity (SPEC-036) | spec only | Would compare served distributions against a coordinator-held reference | **Zero code** |
| Attestation (Pillar C) | `internal/tier2/pillar_c*.go`, `ws/server.go:1778` | SE P-256 = key custody + session binding; `AttestationTierHardware` never emitted | Live, non-load-bearing |

### 2.2 Production posture

| Control | Live value | Evidence |
|---|---|---|
| `tier2.require_hash_verified` | **true** (since 2026-07-23) | `dist/coordinator.yaml:288` [E-spec] |
| `proof_of_weights.require_autotune_hello_gate` | **false** | `ops/exceptions/production-exceptions.json:20`; SPEC-032:553 wrongly says true [E-spec] |
| `pool.canary_enabled` | **false** | `exc-canary-disabled-enable-gate` active [E-spec] |
| `proof_of_weights.telemetry_drift.enabled` | false (default) | `internal/config/config.go` (`TelemetryDrift.Enabled`) [E-code] |
| `pool.losslessness_probe.enabled` | false | `config.go:994` [E-code] |
| `tier2.require_attestation` | false | `config.go:1078` [E-code] |
| `settlement.verified_model_settlement_mode` | `observe` (default; overlay unknown) | `config.go:1120` [E-code, I] |
| `referrals.require_for_registration` | **false** | `dist/coordinator.yaml:108-112` — referral gating is **not** today's admission control, and registration is open (§9.3, R7) [E-code] |

### 2.3 The Pearl-DB facts from the triggering session, reconciled

- *"Providers serve traffic daily while jobs sit in `waiting_trust`."* Consistent with code: with the hello gate off, hardware verification has **zero** influence on admission or routing. Serving and verification are decoupled. [E-code; observation E-session]
- *"`waiting_trust` means the trust tuple is missing, not that the provider never served."* Confirmed: set only when every other gate passed and the reason is `missing_trusted_hardware_identity`/`missing_trusted_chip_profile` (`verify.go:240-246`); self-promotes once operator rows appear. Entry 198 is the documented live instance. [E-code, E-spec]

---

## 3. Evidence And Trust Boundaries

### 3.1 Evidence classes

| Class | Definition | Forgeable by one malicious provider? | Anchors |
|---|---|---|---|
| `provider_self_reported` | Anything computed and sent by provider code: benchmarks, model hash, weights manifest, RAM, context, concurrency, TPS estimate, model-load-time, hardware summary | **Yes, trivially** | `messages.go:19-47, 298-320`; `hardware_evidence.go` |
| `operator_approved_identity` | Operator vouches that an identity maps to a hardware class (SPEC-033 tuple + chip profile, dual-control) | No — but the anchored value is provider-controlled and rotatable, and so is `provider_id` itself (§3.4) | migration 019; `admin_hardware_trust.go` |
| `operator_single_host_benchmark` | Operator-run measurement on operator hardware (`measured_single_host`) | No — but generalizes poorly; staled by #745 | `AutotuneRecommend.swift:799-840` |
| `trusted_provider_matrix` | Convergent measurements from ≥N verified providers on ≥M hardware classes — **does not exist and is unreachable at current fleet size** | Only by collusion | #687 Stage 4 [E-issue] |
| `coordinator_observed` | Coordinator/gateway-measured on the buyer path: per-request TTFT, decode wall-time, token counts, error/fault rates, breaker trips | **Bounded three ways — §3.3** | `phase_timing.go:20-29, 204-224`; `settlement_output.go:22,49-50`; `pool/provider.go:1580-1621` |
| `community_unattested` | oMLX board data; advisory prior only | Yes | RESEARCH_231; #687 [E-issue] |

### 3.2 Trust domains, mapped to what actually backs them

| Trust domain | What backs it today | Class | Gap |
|---|---|---|---|
| Catalog artifact identity | Ed25519-signed feed + append-only ledger | operator-authored, cryptographically bound | Sound — strongest domain |
| Catalog `bench_gate` numbers | 4× single-host (pre-#745-fix), 5× no measurement | `operator_single_host_benchmark` at best | Advisory-only is correct; the gap is re-deriving authority from them |
| Provider identity/auth | Bearer token + (v2) proof handshake; `provider_id` bound to `identity_pubkey` (`apptrack.go:313`); PoO is a skeleton + 501 stub | operator-issued credential | **Registration is open; a new keypair mints a clean identity** (§3.4) |
| Hardware identity | HMAC(local random file, providerID\|ramGB\|chip) (`AutotuneRecommend.swift:183-266`) | `provider_self_reported`, then operator-anchored | Not device-rooted; rotatable |
| Model artifact → served tokens | Preflight dir hash (self-enforced) → config value adopted as reported hash (`ModelRuntime.swift:610`, **not re-derived from loaded tensors**) → consistency at hello/heartbeat/receipt | `provider_self_reported`, consistency-chained | Complete vs misconfiguration; empty vs an adversary |
| Benchmark claims | Bearer-auth evidence blob, shape-checked | `provider_self_reported` | SPEC-033 §10.2 self-fabrication; feeds `ResolveMaxAdmission` |
| Buyer-path performance | Timings measured, **not persisted**; token counts persisted | `coordinator_observed` (bounded) | Foundation discarded (§4.7) |
| Routing "fast" objective | `EffectiveThroughput = ThroughputTPSEstimate × tier_weight` | `provider_self_reported` | **An inflated self-report directly buys traffic** (§4.12) |
| Operator approval | Dual-control tuple grants; catalog publish authority | `operator_approved_identity` | Becomes an oracle if it starts approving *performance* (§4.8) |
| Buyer-facing confidence | `tier1_disclosure` (good) vs README:22 / stats overview (overstating) | mixed | §4.9, §8 |

### 3.3 What `coordinator_observed` can and cannot prove (load-bearing)

An early draft asserted this class is unforgeable. That is **false**, in three distinct ways, and the corrections propagate through §5 and §6.

**Cannot be inflated:** wall-clock latency for work actually performed; error rates, breaker trips, timeouts are coordinator-side facts.

**Limit 1 — substitution.** Decode rate is `providerFirstByte → providerDone` over provider-emitted chunks (`phase_timing.go:213`); token counts come from the provider's own stream (`settlement_output.go:46-52`). A provider serving `qwen3-8b` while advertising `qwen3-32b`'s `model_id` and hash string **scores strictly better** on every latency metric than one honestly serving the larger model. The hash predicate does not stop it: `ws/server.go:906-910` is a case-insensitive string compare of a **provider-reported** hash.

**Limit 2 — buffering.** A provider can buffer generation and flush quickly, shifting work into TTFT and making decode throughput look better without better service. Ranking on decode throughput alone is therefore gameable; any floor or ranking must combine TTFT with decode, or use end-to-end latency and streaming cadence.

**Limit 3 — sample volume.** Per-bucket percentiles need samples. Whether prebeta demand produces them is **unmeasured** (§0, R0). Until it is, every design resting on per-bucket observation is provisional.

**Design consequence:** observed data is valid authority for *demotion* and for capacity decisions *within an already-proven model class*. It is **not** valid authority for a cross-model-class ceiling raise.

### 3.4 What `operator_approved_identity` actually anchors

1. **The hardware anchor is rotatable — but rotation is not an escape.** `hardware_identity_hash` derives from `~/.config/macprovider/autotune-hmac-secret` (`AutotuneRecommend.swift:213-266`, constant `:1599`). Deleting it mints a *fresh, unapproved* tuple. Because the only enforcement path keyed to that hash is `trust_revalidation.go:92-102, 235, 241`, which **evicts** a session whose admitted tuple lost its trust root, rotation costs the provider its admission rather than buying a clean slate. An earlier revision of this document claimed HMAC rotation washes sanctions; that claim was **wrong** and is withdrawn (§4.11).
2. **Provider-account rotation is the real wash.** `provider_id` is bound to `identity_pubkey` (`internal/onboarding/apptrack.go:313`) and to the validated credential at hello (`internal/ws/server.go:2162`). Sanctions are keyed to `provider_id` alone and durably persisted (`pool/provider.go:558, 665, 696, 1359`; `internal/ws/canary_store.go:14-18`) — correct design. But a **new keypair yields a new `provider_id`**, and `referrals.require_for_registration: false` leaves registration open, so a sanctioned operator can re-register clean. The gap is registration policy, not sanction keying (§4.11, R7).
3. **The memory value is provider-submitted.** Migration 019 derives the tuple server-side from the job row (`019:17`), but that row's `unified_memory_gb` came from the provider's own evidence (`hardware_evidence.go:69`). The tuple's strength equals **whatever the operator physically verified at first approval** — fine while the operator installs each Mac, and precisely what fails when the cohort opens.

---

## 4. What Is Broken Or Weak Today

### 4.1 F1 — Catalog gate numbers are unfounded; the mechanism producing them was broken until 2026-07-25

The #744 audit [E-issue], corroborated by the shipped backfill table `AutotuneRecommend.swift:799-840` [E-code]: 4/9 rows measured, all on one M5 32 GB; 3 rows needing >32 GB unmeasurable on the only executor; 2 re-measured rows diverging 1.7–1.8× in *opposite* directions. #745 explains it: until PR #751, `serve --model` overrode identity but not `model_artifact_path`, so **every candidate benchmark loaded the incumbent and recorded it under the candidate's name**, silently. Fix verified end-to-end [E-code: `Config.swift:489-526`; chain `AutotuneRecommend.swift:3040-3063` → `CandidateProviderRunner.swift:289-295` → `MacProviderCLI.swift:1024-1026` → `ModelRuntime.swift:601`]. **No gate value predating #751 is trustworthy, and no trusted post-#745 matrix exists** — Entry 196 correctly rejected wholesale re-derivation.

The probe now feeding first-order ranking and the buyer-TTFT veto is **single-replicate** by default (`AutotuneCommand.swift:37`) — "p95 TTFT" is one sample. [E-code]

### 4.2 F2 — Signing is conflated with truth

The signature proves bytes came from a keyring holder. The repo's own statements agree (`keys/README.md:59-66`; SPEC-032:653-655; Entry 134). But surfaces invite more: `catalog_trust_blocked` (`AutotuneCommand.swift:1206`), `paidTrustBlockingWarnings` (`AutotuneRecommend.swift:1604`), `"status": "live_verified"` (`autotune_feeds.go:840`), SPEC-023:127 "a trustworthy catalog". SPEC-023 has no "what the signature does not prove" section, unlike SPEC-015 (`:2473-2495`). Meanwhile `/v1/rate-card` — the money input — is **unsigned** with an unlabeled baked fallback (`AutotuneRecommend.swift:1330-1340`), while advisory TPS numbers get full Ed25519 protection. [E-code, E-spec]

### 4.3 F3 — Shipped provenance is unsigned client-side state; two vocabularies coexist

Every live row omits `bench_gate.provenance`; values come from a hardcoded backfill keyed to the release SHA (`AutotuneRecommend.swift:757-840`); the signature covers zero provenance bytes. The coordinator accepts nil and substitutes nothing (`autotune_feeds.go:500-507`). `validate_candidate` runs **without** `require_provenance` at `catalog-release.py:1324, 1589, 1649, 1697, 1721` — only `generate` enforces it. The #687 draft defines a different enum with zero overlap; its §1 invariant is violated in spirit today. [E-code, E-spec, E-issue]

### 4.4 F4 — The verifier's anchor is provider-controlled

`hardware_identity_hash` = HMAC over a local random file plus sysctl strings; evidence is bearer-authenticated with **no signature** (`hardware_evidence.go:243-252`). Where verified evidence becomes authority: `ResolveMaxAdmission` (`gate.go:18-58`) derives the ceiling from the provider's **own** benchmarks — a fabricated row buys a higher tier. `benchmarkPassesGate` checks thermal, identity binding, and artifact-hash *string* equality; deliberately never TPS/TTFT (`gate.go:104-106`) and **never `swap_detected`** despite decoding it (`evidence.go:13`). [E-code, E-spec]

### 4.5 F5 — Admission is one-shot with a documented CRITICAL bypass, and it is off

- `require_autotune_hello_gate: false` (verified 2026-07-22); SPEC-032:553 claims the opposite. [E-spec]
- **FR-HG7**: `MaxAdmittedModelKey/ID` is consumed only by `providerProbeModelID` (`ws/server.go:3442-3447`), which has **two** callers — the warm-up gate (`:3423`, **live**) and the canary (`:3734`, disabled). It appears nowhere in `RoutingEligible()` or buyer matching. `applyHeartbeatLocked` overwrites `ModelID` unconditionally (`pool/provider.go:1851`); a switch without a loading transition emits no `SwapEvent` (`:1899-1916`). **Note also that `HelloGateDecision.MaxAdmittedMinRAMGB` (`gate.go:13`) is computed and then dropped — `pool.Provider` stores only key/id (`provider.go:200-201`)**, so the RAM value R3 needs does not currently survive admission. [E-code, E-spec]
- **FR-HG6**: no mid-session *evidence-TTL* recheck. Trust-root revocation **is** covered (`trust_revalidation.go:12-23, 121, 149-159`). [E-code]

### 4.6 F6 — Every capability input to routing is self-reported

`RAMGB`, `MaxContextTokens`, `MaxConcurrency`, `ThroughputTPSEstimate`, `ModelParamsB`, `ModelLoadTimeMs` trusted as-is and re-trusted every heartbeat. Aggravations: self-reported `RAMGB` is never compared to the verified `unified_memory_gb` in the same DB; `ModelLoadTimeMs` is the Pillar D anomaly baseline (`pillar_d.go:167-197`) — the provider sets its own threshold (that path is **observe/WARN-only and config-gated**, `:193`). [E-code]

### 4.7 F7 — The observability mechanisms observe self-report; the real observations are discarded

`pow/drift.go` compares heartbeat claim against benchmark claim — self vs self, WARN-only, dormant. OPoI is byte-identical to the liveness nonce echo (SPEC-032:38), zero routing readers, cannot fire while canary is off. Meanwhile true TTFT and decode wall-time are measured on all 8 relay paths (`markProviderFirstByte` at `internal/buyer/server.go:2439, 2530, 2880, 3086, 3369, 3540, 3646, 3901`) and emitted as **headers only**; `request_log` has no TTFT/decode column (`internal/requestlog/store.go:43-100, 464-489`); no per-provider aggregate carries latency or throughput — the leaderboard tables (`001_stats_tables.up.sql:39-62`) carry earnings/tokens/jobs only, and no other stats table adds them. [E-code]

### 4.8 F8 — Operator approval is drifting toward a performance oracle

Verified evidence feeds `ResolveMaxAdmission` and (per #687 Stage 4) future gate re-derivation, so identity approval transitively **launders self-reported benchmarks into admission authority**. Boundary: operators approve *identity mappings*; performance authority comes only from observation. **§6.3 Step 4's interim cross-class path knowingly violates this boundary and is flagged there as a carried exception, not a design.** [I, grounded in E-code]

### 4.9 F9 — UX and docs overstate in specific, fixable places

| Surface | Problem | Ref |
|---|---|---|
| `README.md:22` | "the **verified model hash** … **Verifiable inference**" — unqualified; violates SPEC-006:343 | [E-spec] |
| `docs/using-macprovider-with-openai-sdk.md:202` | "what makes MacProvider verifiable inference" | [E-spec] |
| `autotune --recommend` transcript | "Benchmarked N" prints the *eligible* count (`AutotuneRecommend.swift:2057`); zero confidence/provenance/drift — #772's additions are JSON-only; warnings are bare stderr enums | [E-code] |
| `AutotuneCommand.swift:958` | Asserts the `$0.0050/hr` gate SPEC-023 v0.4 deleted | [E-code] |
| `/v1/stats/overview` | `bandwidth_gb_per_s`, `network_power_kw`, `gpu_cores_total` are chip-name lookup constants (`ProviderHardwareSummary.swift:48-105`), unlabeled; no provenance field on the wire | [E-code] |
| `nodes_hardware_attested` | Structurally always 0 (`ws/server.go:1778` only writes `self_signed`); `0` is ambiguous | [E-code] |
| `/v1/models` `hash_verified` | Scalar, no in-band caveat | [E-code] |
| CLI `status` | "Pending hardware verification" overstates per SPEC-033 §10.2 | [E-code] |
| Console arm64golf | Headline outruns its caveat; hardcoded 2026-06-05 literal with a `last_update` reading as live | [E-code] |

### 4.10 F10 — Spec/doc drift

SPEC-032 posture inverted (`:553`). SPEC-033 roster omits migration 019 and `promoteJob` behavior; §3 schema omits `model_artifact_path`. SPEC-008:97-102 stale post-#759. SPEC-013 NFR-4 (`:1273-1292`) contradicted by **three** egress paths: evidence POST, `/v1/rate-card` (`AutotuneRecommend.swift:1334`), signed static feeds. SPEC-023 §3.4/§3.5 URLs stale. `ops/runbooks/spec-drift-remediation.md:130` contradicts the 2026-07-22 read (r3 corrected the path but not the line; `:132` is an unrelated 2026-07-12 SPEC-024 row). [E-spec, E-code]

### 4.11 F11 — Sanction durability is bounded by open registration, not by sanction keying

**Correction (r4).** Earlier revisions claimed sanction state is erasable by rotating the HMAC secret. That is false: `canarySanctions` is keyed by `providerID` alone (`pool/provider.go:558`, written `:665, :1359`, read `:696, :1313, :1569`) and durably persisted through `CanarySanctionStore` (`internal/ws/canary_store.go:14-18`), and rotating the HMAC secret only invalidates the *admitted tuple*, which triggers eviction (`trust_revalidation.go:92-102`). Existing sanction keying is correct and needs no repair.

The real, narrower gap: `provider_id` derives from `identity_pubkey` (`apptrack.go:313`), and registration is open (`dist/coordinator.yaml:108-112`), so re-registering with a fresh keypair yields an unsanctioned identity. **Sanctions are durable against everything except identity re-registration** — which is a registration-policy question, not a sanction-storage one (R7, §11 Q5). Any new probation state must be keyed the same way `canarySanctions` already is; that is a design note for R5, not a work item. [E-code]

### 4.13 F13 — A LOCKED spec contradicts the live signed catalog on the fields this document is about

`specs/SPEC-023-installer-autotune-recommend.md` is `version: v0.8`, `status: LOCKED`, `last-locked: 2026-07-26`. Its §"the v0.1 baked catalog MUST contain at least these rows" table (`:259-267`) disagrees with the shipped, signed `phase3-binary/dist/static/autotune-candidates.json` on **6 of the 7 shared rows**:

| row | SPEC-023 (ram / tps / ttft / status) | live signed catalog |
|---|---|---|
| `meta-llama/llama-3.1-8b-instruct` | 16 / 20 / 2500 / recommendable | **12 / 15** / 2500 / recommendable |
| `openai/gpt-oss-20b` | 24 / **30** / 2500 | 24 / **15** / 2500 |
| `qwen3-32b` | **32 / 30 / 3000 / listed** | **48 / 15 / 4000 / recommendable** |
| `qwen3-coder-30b-a3b-instruct` | **32 / 25 / 3000** | **28 / 20 / 3500** |
| `qwen2.5-coder-32b-instruct` | **64 / 30 / 3500 / listed** | **48 / 20 / 3500 / recommendable** |
| `google-gemma-4-26b-a4b-it` | **32 / 30 / 3000 / `blocked`** | **28 / 10 / 3000 / `recommendable`** |
| `nvidia/nemotron-3-nano-30b-a3b` | 32 / 30 / 3000 | 32 / 30 / 3000 ✓ |

The gemma row is the sharpest: SPEC-023:269 states blocked rows "are never downloaded, benchmarked, or recommended by default," while the live catalog serves it as `recommendable`. §7 rule 2 ("no gate value changes without a post-#745 measurement") is therefore already violated *against the normative spec*, and §4.3's "all 9 rows `recommendable`" understates the problem as a soft #687 "in spirit" issue when it is a hard contradiction of a LOCKED spec. [E-code, E-spec]

### 4.12 F12 — Routing's "fast" objective ranks on self-reported throughput

`EffectiveThroughput = ThroughputTPSEstimate × tier_weight` (`internal/routing/candidate.go:80-92`) drives SPEC-004 FR-SR-8. `ThroughputTPSEstimate` is self-reported and re-trusted per heartbeat. **The one place an inflated self-report directly buys traffic and revenue** — untouched by any provenance or signing work. [E-code]

---

## 5. Correct Target Model

### 5.1 One sentence

**Trust artifacts and identity; treat every provider-supplied number as a claim; let coordinator-observed measurement govern privileges — as demotion authority always, and as promotion authority only within a proven model class, and only where sample volume exists.**

### 5.2 Trusted / Claimed / Observed

| Layer | Contents | Authority granted |
|---|---|---|
| **Trusted** | Signed catalog bytes; release ledger/tombstones; operator trust tuples (identity only, §3.4 limits); provider credentials | Defines the *universe* of servable models and who may connect. Never asserts performance — **with one named, bounded exception**: until R12 ships a model-discriminating signal, an operator MAY grant a cross-model-class ceiling raise that observation cannot authorize (§3.3 Limit 1). Each such grant must be individually logged, revocable, counted against a hard cap, and reported in the §8 provenance surface as `operator_granted`. This is a deliberate carve-out from §4.8's boundary, not an oversight; R12 retires it. |
| **Claimed** | Benchmarks, model hash, weights manifest, RAM/context/concurrency/TPS estimate, hardware summary, `bench_gate` values | May *lower* the provider's own privileges immediately. May grant **only capped, revocable, probationary serving** (§6). May never grant unrestricted paid serving, set enforced thresholds, or rank the routing objective. |
| **Observed** | Per-request TTFT, decode time, tokens, error/fault/breaker events; canary results when enabled | **Demotion**: always authoritative. **Promotion**: within an already-proven model class only, and only above a sample floor. **Ranking**: the correct input, replacing F12's self-report. |

### 5.3 What the coordinator should enforce continuously

1. **Catalog membership + artifact hash predicate** on the *currently served* model — already live. Keep.
2. **Capacity ceiling on every routing decision and every heartbeat model change** (closes FR-HG7): serving model's `min_ram_gb` ≤ admitted ceiling, else routing-ineligible **for that model**. Implementation note: this requires persisting `MaxAdmittedMinRAMGB` on `pool.Provider` (it is currently dropped, §4.5) and comparing **in memory**; do not read Postgres under `Registry.mu`.
3. **Evidence-TTL freshness** on the existing 30 s sweep (closes FR-HG6).
4. **Observed-performance floors**, bucketed by workload shape (§5.4), combining TTFT with decode rather than decode alone (§3.3 Limit 2), as a **demotion** authority.
5. **Self-consistency tripwires** as WARN→sanction escalators: self-reported `RAMGB` vs verified `unified_memory_gb`; heartbeat TPS claim vs observed.
6. **Sole-provider floors apply to health/liveness uncertainty only — never to integrity violations, and never as a no-op.** This is the r3 correction to a genuinely dangerous r2 rule. A floor that spares the last provider from a *capacity, catalog-membership, hash, or admission* violation creates the attacker's ideal case: be the only provider for a model, then switch to an unadmitted model and remain buyer-serving as alert-only. Integrity violations **fail closed even if that empties the pool** — a 503 is the correct outcome when the alternative is knowingly routing buyers to an unadmitted model. FR-CAN22's floor (`pool/provider.go:1348`) stays scoped to canary/health uncertainty, where "we are unsure this provider is healthy" genuinely does not warrant destroying the only supply.

   Two further constraints, both added in r4:

   - **A held floor must degrade, not no-op.** Holding the floor means routing to the *smallest model the provider is admitted for*, plus an alert — never continuing to serve the unadmitted model unchanged. A floor that takes no action is indistinguishable from no enforcement.
   - **The floor predicate is self-selectable and must be hardened.** `hasOtherBuyerServingForModelLocked(providerID, p.ModelID)` (`pool/provider.go:1348`) keys on the case-folded `ModelID` that F5 shows a heartbeat can set to any string. A provider can therefore *choose* floor immunity by advertising a model no peer serves, and at `pool_size: 1` every provider has it for free. Any floor evaluated after R3a must key on the **admitted** model identity, not the self-reported one.

   This resolves what earlier revisions left as an open question.

### 5.4 Workload normalization

Floors must be evaluated **within matched buckets** (prompt-token range × concurrency), never against a raw global p95, and never against a catalog `max_4k_ttft_ms` derived from a fixed 4k single-replicate probe. An absolute network-wide TTFT ceiling systematically penalizes large models — the supply the network most lacks.

SPEC-029 supplies the workload-class *vocabulary* (`short_chat`, `medium_with_system`, `long_context`, `code_completion`, `agent_style` — `scripts/catalog-release.py:163`). **It is not a drop-in**: SPEC-029 is explicitly a sweep-output partition that "does not introduce runtime request classification," its keys are workload-name × RAM-tier, and `workload_profiles` is intentionally absent from the live catalog. Runtime bucketing is **new work with an undecided shape** (§11 Q4), which is why R1 splits into columns-now (R1a) and classifier-later (R1b). [E-spec]

### 5.5 What stays advisory

`bench_gate` TPS/TTFT (until re-derived per §7 and promoted per-row), autotune recommendation and ranking, oMLX priors, drift warnings, OPoI pass-rate, provenance labels. The client-side buyer-TTFT ceiling stays an operator policy knob per Entry 196.

### 5.6 Before any catalog numeric gate changes again

A post-#745 measurement, in-band signed provenance, and — for any gate *gaining enforcement power* — corroboration from observed data or a `trusted_provider_matrix` quorum (§7).

---

## 6. Provider Model Upgrade Flow

> **Status: conditional analysis, not approved work.** Everything past §6.2 depends on R0's volume answer and on unresolved money-path design (§6.3 Step 3). §6.1–§6.2 stand on their own; the flow below should be read as "the shape a solution must have," not as a specification ready to implement.

### 6.1 The requirement (and the anti-requirement)

Two real scenarios must work:

- **Same Mac, larger catalog row.** A 64 GB Mac first benchmarked on `qwen3-8b` wants `qwen3-32b`. No hardware event; the existing tuple applies. **This must need no operator involvement.**
- **A catalog row published after the provider's last verification.** Same tuple, new row.

A provider does **not** "buy more RAM" — Apple Silicon memory is on-package. More memory means a *different Mac*, a new `(chip, memory)` tuple, `verified` cleared by the migration-016 guard, and correct re-entry into operator approval. New hardware always re-enters approval; that is intended.

Freezing providers to the first hello model is rejected: it punishes honest upgrades, invites identity churn, and confuses "what you first claimed" with "what you can do."

### 6.2 Capacity and performance are two different questions

- **"May this Mac physically host this row?"** — `min_ram_gb` vs the operator-verified `unified_memory_gb` (§6.3 Step 2). Static, needs no traffic, closes the pure-fabrication ceiling raise **to the strength of the operator's first-approval physical verification** (§3.4 limit 3).
- **"Does this Mac serve this row acceptably?"** — continuous observed floors (§5.3.4), which apply to *every* provider on *every* model.

Probation therefore buys exactly one thing: **bounded exposure between a capacity claim and the first observed data point.** **Falsification test, to be run before R5 is scheduled:** if R0 shows that window is not measurably shorter than the maximum probation window — i.e. if observed data does not arrive fast enough to end probation on evidence rather than on a timer — then probation collapses into §5.3.4 and this section reduces to Steps 0–2. r3 does not claim to have passed this test; R0 supplies the input.

### 6.3 The flow (conditional)

**Step 0 — baseline.** Ceiling = `ResolveMaxAdmission(verified evidence)`. Re-running autotune on the **same tuple** auto-promotes through the verifier with no operator action; only hardware change needs re-approval. Preserve this asymmetry.

**Step 0b — cold start.** A provider's **first** model uses identical entry rules. Exempting first-hello would give an unknown stranger full share on day one while taxing a known provider for upgrading on the same Mac.

**Step 1 — claim.** Fresh evidence submitted. Grants nothing.

**Step 2 — mechanical pre-checks.** Evidence passes SPEC-033 against the existing tuple; **`min_ram_gb + safety_margin_gb ≤` verified `unified_memory_gb`**; swap/thermal flags disqualify (bringing #742's rule coordinator-side).

The safety margin is not optional: the shipped client already enforces `model.min_ram_gb <= mac.ram_gb - 4` (SPEC-023:447, AC-11 at `:697`; `AutotuneRecommend.swift:1599, 1824`). Omitting it — as an earlier revision did — would make the coordinator check *looser* than the provider binary it is meant to backstop: a 48 GB Mac would pass Step 2 for a 48 GB row that its own CLI rejects. Source the constant from the same place as AC-11 rather than restating it.

**Step 3 — probationary serving.** Two design constraints the review process settled, and one it did not:

- **Not `pool.TierProvisional`.** r2 proposed extending it; that is wrong twice over. `Tier` is a **per-provider scalar** (`pool/provider.go:119`), so it cannot express per-(provider, model) state; and `TierProvisional` already *means* "canary-sanctioned — escalate to ban on next trip" (`pool/provider.go:1352-1355` sets `StateUnavailable`, where pinned providers only degrade). Overloading it would make every probationary provider strictly harsher-treated than an established one. (A third, unrelated `TierProvisional` exists in `internal/rewards/rewards.go:25` governing withdrawal cooldown — any spec text must say which namespace it means.) Probation needs a **new per-(provider, model) state** with its own persistence across reconnect. This is a `pool.Provider` schema change, not an extension.
- **Absolute exposure budget, not relative share.** Relative downweighting gives zero dilution when the provider is the only holder of that model — the live condition. The budget must be absolute and numeric: max concurrent slots, max requests before first floor evaluation, and — once pricing is settled — max cumulative billed value (a dimension that only exists if probation traffic is billed at all, which Step 3 leaves open).
- **Pricing is UNRESOLVED and is the item's largest risk.** r2 said "discounted or unbilled." That is wrong as stated: provider payout derives from `provider_credits`, and `payout.go:118-128` **voids a payout row when `payableProvider < minPayoutCredits`** — so unbilled probation makes the provider serve for free and can void the payout outright, on a network whose scarce resource is providers. No discount mechanism exists (the only `discount` in billing is the cached-prompt-token one; the only unbilled path is the SPEC-022 `model_hash: null` *error* path). The candidate direction is **bill the buyer at full rate, escrow the provider's share, release on promotion and forfeit on demotion** — but that is new money-path work spanning `internal/billing/`, `phase5-gateway/` (`usage_events`, `ReservationSettlement`), and a SPEC-022/SPEC-005/SPEC-006 amendment. **Until that design exists, R5 cannot be scoped.** Also invariant: probation pricing must never be buyer-selectable or buyer-visible pre-request, or a discount would attract buyers *to* unproven providers and distort the very data used to promote them.
- **No buyer opt-out claim.** Tier-2 knobs are coordinator-global config; the only per-request surface is a 503.

**Step 4 — promotion, scoped by class.**

- **Within a proven class**: observed floors suffice, above a **minimum sample floor**. Promote after N observed requests in matched buckets over ≥T elapsed time with no breaker trips.
- **Never promote on absence of evidence.** If the maximum window expires without meeting the sample floor, the outcome is **"remains probationary, operator notified"** — for both first-model and upgrade cases. A time-only path would void every other control at thin traffic, which is precisely the expected condition.
- **Anti-self-dealing is weak and must be labeled so.** A "≥2 distinct payer accounts" rule is a two-account speed bump: nothing gates buyer-account creation, and `request_log.account_id` is explicitly nullable — "empty for direct legacy buyer calls without the header" (`internal/requestlog/store.go:60-66`) — so the rule is simply unevaluable on that path unless those requests are excluded from the promotion count. It is worth having as friction, not as a control. (r2 cited `internal/canarycorr/` FR-CAN23 as prior art; that citation is **withdrawn** — that package is provider-side Sybil containment via observed-serving capacity residual and contains no payer or account concept.) Real anti-Sybil requires independent payment instruments, which is its own item.
- **Across model classes**: observed latency is **not** sufficient (§3.3 Limit 1). Until R12 supplies a model-discriminating signal, a cross-class raise rests on Step 2 capacity **plus an operator grant under the named §5.2 carve-out** — logged per grant, revocable, hard-capped in number, and surfaced to buyers as `operator_granted`. r4 resolves this in §5.2 rather than leaving it as a standing contradiction between the target model and the flow; the residual judgment (cap value, or refusing cross-class raises entirely until R12) is §11 Q6.
- **Floors are per-(model, RAM-tier) and bucketed**, combining TTFT with decode.

**Step 5 — demotion symmetry**, subject to §5.3.6 (health floors only; integrity violations fail closed). Promotion is durable until demoted.

**Step 6 — sanction durability.** Probation/demotion state must be keyed to `provider_id`, as `canarySanctions` already is (`pool/provider.go:558`); so keyed, it survives reconnects, HMAC-secret rotation, and hardware re-approval. The one bypass is **re-registration under a fresh keypair** while registration is open (R7). Earlier revisions overstated this as general erasability; see §4.11.

**Settlement non-retroactivity.** Ceiling and probation state are **non-retroactive for settlement**: requests served before an enforcement change are not retroactively repriced or clawed back, and in-flight requests at demotion complete and settle normally. This must be stated in the SPEC amendment so two implementers do not build opposite behaviors.

### 6.4 Why this answers the design question

Self-report becomes a *trigger* (Steps 1–2 gate on consistency and operator-verified capacity, not claimed speed). Legitimate same-class upgrades clear on observed traffic with no operator involvement — **when volume exists**. Cross-class upgrades are honestly labeled as resting on capacity + a carried operator exception, rather than dressed up as observation-backed. Fabricators face a numerically bounded exposure budget — with the three caveats stated plainly (substitution beats latency checks; sanctions survive everything but identity re-registration; promotion may stall at thin traffic) rather than assumed away.

---

## 7. Catalog Gate Promotion Rules

```
never_benched / no_throughput_bench / policy / legacy_unverified   (no measurement)
runtime_validated_only                        (loads and serves; no throughput gate)
        ↓ seed (advisory only)
omlx_seeded                                                        (community prior, #687)
        ↓ operator measures post-#745
measured_single_host                                               (one machine, one operator)
        ↓ N verified providers × M hardware classes converge,
          corroborated by coordinator_observed serving data
trusted_provider_matrix                                            (promotable to enforcement)
```

1. **Provenance lives in the signed bytes.** Next release carries `bench_gate.provenance` in-band; backfill and nil-acceptance retire with it. `require_provenance` added to **every** `validate_candidate` call site (`catalog-release.py:1324, 1589, 1649, 1697, 1721`).
2. **No gate value changes without a post-#745 measurement** of that row (Entry 196).
3. **Advisory by default, per row.** A gate gains enforcement power only at `trusted_provider_matrix`, and then under a **new field name** (`hard_min_sustained_tps`, per SPEC-023:71-74), so the advisory wire field never silently changes meaning.
4. **Promotion arithmetic** (#687 Stage 4): recompute from ≥N verified providers' post-#745 measurements on ≥M hardware classes, cross-checked against observed serving data; drop the oMLX seed. N ≥ 3, M ≥ 2 as floors. **Unbuildable at current fleet size**, and the >32 GB rows remain unmeasurable pending #584 — hence R8's split.
5. **`recommendable` is orthogonal to measurement, but never to disclosure.** (Note there are two distinct fields with this name: the `runtime_status` enum on a candidate row (`catalog-release.py:264`) and the boolean on a demand-rank row (`:362-375`). Eligibility requires both; this rule concerns the candidate-row status.) A row may be `recommendable` at any provenance class **provided its class is rendered at the point of choice** (§8). This is a deliberate **narrowing** of #687's invariant, justified by gates being advisory; if gates ever become enforcing under rule 3, #687's stricter form applies.
6. **Unsigned inputs off the money path**: sign the rate card or fold it into the signed release unit.

---

## 8. Buyer/Provider UX Requirements

**Framing:** at 1–2 providers with one model each, a buyer has no provider to choose *between* — this section is **overclaim remediation and expectation-setting**, not decision support. Decision-support surfaces are scale-triggered.

1. **Fix the two normative violations first** — `README.md:22` and `docs/using-macprovider-with-openai-sdk.md:202`, using the `phase7-verify/README.md:129` pattern. The only §8 items unacceptable *today*.
2. **Every performance/verification claim carries its evidence class**, copying `catalog_evidence_source` (`buyer/server.go:1096`), gateway `tier1_disclosure`, leaderboard `rewards_populated`.
3. **Transcript parity with JSON** in `autotune --recommend`: render confidence, provenance class, drift; fix "Benchmarked N"; replace bare stderr enums. `RecommendationEmitter.swift:169-177` is the house standard.
4. **Delete stale claims**: `$0.0050/hr`; Entry-109-derived `nodes_hardware_attested` prose.
5. **Stats overview honesty** (label immediate, `source` object scale-triggered): mark chip-table constants as estimates; report `hardware_attestation` consistently with the gateway's `"none"`.
6. **Provider-side visibility**: s/"Pending hardware verification"/"Pending operator identity approval (hardware class)"/. CLI `status` is the **required** surface for probation state and progress, since SPEC-014 defers all such portal fields behind Open Q5.
7. **Probation visibility is asymmetric.** Provider-side always visible with criteria and progress. Buyer-side **gated on a minimum provider count** — at pool size 1 a `probation_provider_count` is a public sanction disclosure about one identifiable machine, contradicting the anonymity constraint that keeps observed aggregates internal.

---

## 9. Prebeta Minimum Viable Trust Model

### 9.1 What is acceptable now (small, personally-known cohort)

- **Operator-approved identity** as the admission root — the operator installs each Mac personally, which is exactly what §3.4 says the tuple's strength depends on.
- **Signed catalog pinning + Tier-2 Pillar A + `require_hash_verified`** — closes misconfiguration/drift, the *actual* observed failure mode. Every incident in the log (#742 swap selection, #745 mislabeled benchmarks, Entry 198 chip-profile gap) was honest-system error.
- **SPEC-022 observe mode**, **advisory gates + client-side vetoes**, **manual operator response** in place of the disabled canary (Entry 195's posture).

### 9.2 Three tiers

- **Tier N — supply-neutral, do now, no trigger**: R0, R1a, R8a, R10. None slows onboarding; all are cheap; R1a's value increases with earlier start.
- **Tier 0 — blocks continued operation**: R2 (the two normative overclaim violations) and R3a (ceiling-drift **detection** — a silent heartbeat switch invalidates the one integrity chain that is live). Tier 0 items are also do-now; the distinction from Tier N is that these are *unacceptable to leave undone*, not merely cheap.
- **Tier 1 — must complete before the first non-personally-installed provider connects**: R3b (enforcement), R1b, R4, R5 (if R0 justifies it), R7. **This is a lead-time requirement, not an event trigger**: Tier 1 is multi-week work, so it must be *started* when the operator forecasts a stranger within a quarter and *completed* before that provider connects. r2's "N=5 providers" is withdrawn — provider count is unrelated to what any Tier-1 item needs, and it conflicted with §9.3's own qualitative trigger.
- **Tier 2 — follows**: R8b, R9, R11, R12.

Every R item carries exactly one tier; R3 and R1 are tiered per half (R3a/R3b, R1a/R1b), which is why they appear split throughout §10.

### 9.3 The trigger is a qualitative event, not a flag

`referrals.require_for_registration: false` and SPEC-034 prohibits production activation outside a one-time §8 exception — referral gating is not today's admission control. The observable trigger is **the first provider the operator has not personally installed**, with the lead-time rule above.

### 9.4 Explicitly not blocking, with the tension named

SPEC-036, MDA device rooting, losslessness enforcement. The one genuine carried risk is §5.2's named cross-class operator carve-out, which R12 retires. r3's broader "sanctions are deterrents, not controls" acceptance is **withdrawn** — it rested on the F11 error corrected in r4; sanctions are durable against everything except identity re-registration, which R7 addresses as a registration-policy question.

---

## 10. Roadmap / Issue Breakdown

**Effort calibration.** Sizes below are re-baselined after review flagged r2's estimates as 2–4× optimistic. Reference points from this repo: SPEC-037's IMPL landed at 16,536 insertions across 75 files (`d53e8650`) for one flag-gated, default-off feature; house rules require three-lane codex audits to 0 C/H/M per slice; SPEC-036 took 14 rounds; items needing a SPEC amendment require **two** audit loops (spec, then IMPL) plus a governance declaration plus the antfleet-ops-approves → Augustas11-merges sequence. "Operator hours" includes reading and re-firing audit lanes, which dominates. Items whose parameters are unknown are marked **unsizeable** rather than given a placeholder.

---

### R0 — Measure buyer demand per (provider, model, bucket) · **Tier N** · Size XS (~2-4 operator hours)

- **Problem**: The entire coordinator-observed thesis assumes sample volume nobody has measured. R4, R5, and R9 all consume per-bucket aggregates; at prebeta demand those buckets may be empty.
- **Impact**: Decides whether R4/R5/R9 are executable or are a bet on demand that has not arrived. Also supplies the §6.2 falsification input.
- **Change**: one read-only SQL pass over the existing coordinator `request_log`: requests/day per `(provider_assigned_id, model)`, and the same split by prompt-token range and concurrency proxy. Report median and p10 days.
- **Files**: none (operator query); optionally a `scripts/` helper.
- **Evidence required**: a number, in the issue, before R4/R5 are scheduled.
- **Blocks**: R1b, R4's threshold choice, R5 entirely.

### R1a — Persist per-request TTFT and decode time · **Tier N** · Size S-M (~6-10 operator hours)

- **Problem**: True TTFT/decode measured on every request and discarded (F7).
- **Change**: nullable `ttft_ms` and `decode_ms` columns on `request_log`, populated from `requestPhaseTiming` across all 8 relay paths. **Columns only — no classifier, no aggregate.**
- **Contract note (missed in r2)**: this is a **governed schema change**, not an internal detail. SPEC-002 owns the `request_log` column table (`specs/SPEC-002-coordinator.md:1666-1690`) and SPEC-005 declares it read-only to billing (`specs/SPEC-005-billing.md:526-534`). Requires a SPEC-002 amendment + migration entry and consumer notes for SPEC-005/SPEC-007.
- **Files**: `internal/requestlog/store.go` (+ migration), `internal/buyer/phase_timing.go`, `internal/buyer/server.go`, `specs/SPEC-002-coordinator.md`.
- **Tests**: population across streaming/non-streaming/WS-tunnel; null-when-unmeasured; migration up/down.
- **Blocks**: Tier N — do first regardless; its value strictly increases with earlier start.

### R1b — Runtime workload bucketing + aggregate · **Tier 1** · Size M, **gated on R0**

- **Problem**: Unbucketed floors are unfair and gameable (§5.4).
- **Change**: runtime classifier (prompt-token range × concurrency) borrowing SPEC-029 vocabulary — **new work**, since SPEC-029 explicitly excludes runtime classification — plus the per-(provider, model, bucket) aggregate.
- **Open**: the classifier's shape is undecided (§11 Q4); R0 decides whether buckets can be populated at all.

### R2 — Overclaim remediation · **Tier 0** · Size S (~2-3 operator hours)

- **Problem**: `README.md:22` and `docs/using-macprovider-with-openai-sdk.md:202` promise verified model identity as shipping, violating SPEC-006:343.
- **Change**: apply the `phase7-verify/README.md:129` pattern.
- **Tests**: SPEC-006:3659's audit-cycle language check over the diff.
- **Blocks**: Tier 0. Unconditional, no dependencies.

### R3a — Ceiling-drift detection · **Tier 0** · Size M (~8-12 operator hours)

- **Problem**: FR-HG7's silent half — a heartbeat model switch is applied unconditionally and emits no event when it skips the loading transition.
- **Change**: persist `MaxAdmittedMinRAMGB` on `pool.Provider` — the field does **not** exist today (only `MaxAdmittedModelKey` `:200` and `MaxAdmittedModelID` `:201`), and `HelloGateDecision` computes the value then drops it (§4.5). On `modelIDChanged`, compare **in memory** against that ceiling; emit a provider event + operator alert. **No routing exclusion, no eviction.**
- **Plumbing note**: resolving the new model's `min_ram_gb` needs the `autotune.Catalog`, which lives on `ws.Server` (`s.autotuneCatalog`, `server.go:912`), not in `pool`. Either resolve the row on the `ws` side and pass the resolved integer into the pool, or mirror a minimal model→`min_ram_gb` map into the registry. Removing the Postgres read from under `Registry.mu` (an earlier fix) does not by itself make the comparison buildable where r3 placed it.
- **Why split from R3b**: detection alone closes the Tier-0 hazard without touching sole-provider semantics, so nothing in §11 blocks it.
- **Files**: `internal/pool/provider.go`, `internal/ws/server.go`.
- **Tests**: heartbeat-switch emits the event; no routing behavior change.

### R3b — Ceiling enforcement · **Tier 1** · Size L (~20-30 operator hours)

- **Change**: over-ceiling/uncatalogued → routing-ineligible for that model; add evidence-TTL to the 30 s `trust_revalidation.go` sweep; enforce `swap_detected` in `benchmarkPassesGate`. **Integrity violations fail closed even when that empties the pool** (§5.3.6) — the sole-provider floor stays scoped to canary/health.
- **Files**: `internal/pool/provider.go`, `internal/ws/trust_revalidation.go`, `internal/autotune/gate.go`, `internal/routing/filter.go`, SPEC-032 amendment.
- **Tests**: SPEC-032 AC-F1/AC-F2 flipped to pass; fail-closed-on-empty-pool test; sweep TTL-expiry.
- **Open**: warm-up probe-target behavior when the ceiling changes (`providerProbeModelID` is the live consumer).

### R4 — Rank routing on observed throughput · **Tier 1** · Size M, **gated on R0**

- **Problem**: F12 — the "fast" objective ranks on a provider-authored number.
- **Change**: substitute R1a/R1b's observed aggregate for `ThroughputTPSEstimate` in `EffectiveThroughput`. **Below the sample threshold, use a conservative constant or randomized placement — never the provider's claimed throughput**, which would preserve the cold-start ranking attack for exactly the new or rotated providers that most warrant caution. Combine TTFT with decode rather than ranking on decode alone (§3.3 Limit 2).
- **Files**: `internal/routing/candidate.go`, `internal/routing/objective.go`, wiring in `internal/buyer/server.go`; SPEC-002/SPEC-004 amendment.
- **Tests**: inflated self-report gains no rank; cold-start fallback is conservative.

### R5 — Probationary admission · **Tier 1** · **UNSIZEABLE — do not schedule yet**

- **Blocked on three inputs**: (1) R0's volume answer and the §6.2 falsification test; (2) a probation **pricing and settlement design** (§6.3 Step 3) — the escrow direction spans `internal/billing/`, `phase5-gateway/` (`usage_events`, `ReservationSettlement`), and a SPEC-022/SPEC-005/SPEC-006 amendment, and no discount mechanism exists today; (3) the numeric exposure budget (§11 Q1), without which the item's own adversarial test cannot be written.
- **Scope corrections already settled**: a **new per-(provider, model) probation state** — not `pool.TierProvisional`, which is a per-provider scalar *and* already the canary sanction state; absolute rather than relative exposure caps; never promote on absence of evidence; withdraw the canarycorr anti-Sybil citation; fold the former R6's `admitted_but_unapproved` here **only in a no-buyer-traffic form** (see below).
- **Thin-traffic path — resolved, not open.** §6.3 Steps 0b/4 adopt the canary-free path: elapsed-time bootstrap **conditioned on a minimum observed-sample floor**, never auto-promotion on absence of evidence. R5 therefore carries **no** dependency on SPEC-031 canary re-enable. Earlier revisions left this as an either/or in R5 while §6 had already chosen; the choice stands and the either/or is withdrawn.
- **Grandfathering.** Providers already serving when R5 lands are **not** retroactively placed in probation (consistent with the settlement non-retroactivity rule in §6.3). Step 0b's "no exemption" governs providers admitted after R5, not the existing pool — otherwise at `pool_size: 1` the network's only provider would enter capped, repriced serving on the day the feature ships.
- **Recommended next action**: a time-boxed spike whose deliverable is the pricing design and the budget numbers, not an implementation.

### R6 — **CUT.** Hello-gate flip folded into R3b + R5

r2 proposed `admitted_but_unapproved` as a routable pre-approval state. Two independent findings killed it: it **reintroduces the admission bypass the hello gate exists to close** (a provider without active trusted hardware identity becomes routable), and it conflicts with the existing evidence model — `LatestVerified` returns only `status='verified'` rows with active trust (`internal/autotune/evidence_pg.go:70-92`), while `waiting_trust` is parked by design (`hardwareverify/verify.go:240-245`). It also would not clear its own registered exception, whose `removal_condition` requires admitting providers "through durable hardware-trust approval … without global gate disabling" and whose `expiry_unknown_reason` names #582 stranger onboarding.

What survives: unapproved providers may connect and receive **synthetic/internal probes only, never buyer traffic**, as a sandbox contract inside R5. The flag flip itself is a one-line ops task gated on R3b + config-reload-without-restart (a coordinator restart on a single-provider pool is a documented multi-hour outage — incident 2026-07-10). The exception's removal condition should be **amended before** designing to it.

### R7 — Close the identity re-registration wash · **Tier 1** · Size S-M (re-scoped in r4)

- **Problem** (narrowed): F11's earlier framing was wrong — sanction keying is already correct (`provider_id`-keyed, durably persisted). The remaining gap is that a sanctioned operator can **re-register with a fresh keypair** for a new `provider_id`, because `referrals.require_for_registration: false` leaves registration open.
- **Change**: gate registration (invite/referral or operator approval) so a new `provider_id` cannot be minted anonymously, **or** bind sanctions to a durable admission root above the credential (invite code, payment-account identity). No sanction-storage rework is needed.
- **Design note for R5, not a work item**: key any new probation state to `provider_id` exactly as `canarySanctions` already does (`pool/provider.go:558`); do **not** key it to the hardware tuple.
- **Honest framing**: absent a registration gate this item does not exist — there is nothing to harden on the storage side. The question is a policy one (§11 Q5): does closing registration cost more supply than the wash costs in abuse?

### R8a — In-band signed provenance · **Tier 2** · Size S

Next release ships in-band provenance; `require_provenance` at all five `validate_candidate` call sites; adopt §7's ladder including `omlx_seeded`.

### R8b — Gate re-derivation tooling · **Tier 2** · Size L, **unbuildable until ≥3 verified providers exist**

Stage-4 promotion arithmetic; >32 GB rows remain unmeasurable pending #584.

### R9 — Observed data into drift · **Tier 2** · Size M, gated on R0/R1b

Feed aggregates in as the drift baseline; replace `ModelLoadTimeMs`-derived Pillar D thresholds; add the RAM self-report vs verified-tuple tripwire.

### R10 — Spec/doc drift · **Tier N** · Size S

Fix §4.10's list; add a "what the catalog signature does not prove" section to SPEC-023; amend SPEC-013 NFR-4 to enumerate the egress paths it currently omits — the hardware-evidence POST, `/v1/rate-card`, and signed static-feed fetches (the HF pre-warm carve-out is already present at `SPEC-013:1280-1281`).

### R11 — Low-cost hash-chain hardening · **Tier 2** · Size M

Compare the SE-signed `claimed.model_hash` against the catalog in `pillar_c.go` (already signed, currently discarded); define an expected source for `weights_manifest_sha256` or stop collecting it; sign the rate card.

### R12 — SPEC-036 compute-integrity (observe) · **Tier 2, post-beta** · Size XL

The named closure for §6.3 Step 4's carried operator exception. Enforce is unreachable at current supply (SPEC-036 §6.1).

**Sequencing**: Tier 0 and Tier N run together first — `R2 ∥ R3a` (Tier 0) alongside `R0 ∥ R1a ∥ R8a ∥ R10` (Tier N). Then Tier 1: `R3b`, and — **only if R0 justifies them** — `R1b → R4 → R5`; `R7` joins when a non-personally-installed provider is forecast. Tier 2 (`R8b`, `R9`, `R11`, `R12`) follows. No Tier-1 item precedes a Tier-0 item.

---

## 11. Open Questions

1. **Probation exposure budget and pricing** (R5): numeric caps; and the escrow-vs-discount settlement design, without which R5 is unsizeable. Largest single unknown in the document.
2. **Quorum for `trusted_provider_matrix`** (R8b): N providers, M hardware classes; rows only one provider ever serves; whether #584's unblock changes the answer.
3. **Lead-time forecasting** (§9.2): how far ahead can the operator actually forecast the first non-personally-installed provider? If the answer is "no warning," Tier 1 must start unconditionally.
4. **Runtime bucketing shape** (R1b): prompt-token ranges alone, or is concurrency a day-one dimension? Gated on R0.
5. **Registration gating** (R7): closing registration is the only thing that stops a sanctioned operator re-registering a fresh `provider_id`. Does that cost more supply than the wash costs in abuse? This is the whole of R7.
6. **Cross-class raise cap** (§5.2 carve-out, §6.3 Step 4): what is the hard cap on outstanding operator-granted cross-class raises — or should cross-class upgrades simply be refused until R12?
7. **Sample floor vs stalled providers** (R5): if R0 shows buckets cannot fill, "never promote on absence of evidence" means honest providers stall on upgrades. Operator-granted promotion under the §5.2 carve-out, or the upgrade path stays closed until demand grows?
8. **SPEC-022 enforce timing**: interacts with R5's settlement story.
9. **Rate-card signing mechanics** (R11): sidecar vs folded into the release unit.

---

## 12. Evidence Appendix

### 12.1 Primary code references

**Catalog signing/release**: `scripts/resign-autotune-static.sh:10-128`; `scripts/catalog-release.py:242-336, 410-541, 810-855, 1324, 1499-1649, 1697, 1721`; `scripts/sign-catalog.go:143-147, 309-318, 361-364`; `phase3-binary/catalog/autotune/trusted-keys.json`; `phase3-binary/dist/static/keys/README.md:59-129`; `AutotuneRecommend.swift:1260-1488, 1604-1616`; `AutotuneCatalog.generated.swift:10-19`; `internal/buyer/autotune_feeds.go:29-30, 144-237, 482-541, 840`; `dist/coordinator.yaml:108-112, 211-217, 288`; `internal/buyer/server.go:673-678`.

**bench_gate/autotune**: `specs/SPEC-023-installer-autotune-recommend.md:9-34, 71-74, 226-252, 380-461, 498-533, 551, 670-737, 791`; `AutotuneRecommend.swift:60-116, 183-266, 471-544, 746-849, 1330-1340, 1678-1696, 1811-1886, 1927-1977, 1998-2084, 2377-2400, 3028-3129, 3133-3178`; `AutotuneCommand.swift:7, 37, 47-51, 80-81, 608-611, 719-724, 872-921, 950-984, 1045-1073, 1206`; `Stage1Iterator.swift:380-624`; `ConfigApplier.swift:172-184`; `specs/SPEC-013-cli-autotune.md:435-586, 1043-1300`; `specs/SPEC-029-sweep-workload-class-stratification.md:8, 198-204, 311`.

**#745 fix chain**: `Config.swift:489-526, 592-616`; `CandidateProviderRunner.swift:269-305`; `MacProviderCLI.swift:373-378, 559-736, 945, 1024-1026, 2012-2017`; `ModelRuntime.swift:601, 610, 822-829`; `AutotuneHardwareEvidence.swift:210-213, 340-365`; `hardware_evidence.go:64-66`.

**Hardware verifier / identity**: `specs/SPEC-033-hardware-verifier.md:76-78, 91-123, 183-222, 266-273, 298-362, 367-388, 419, 448-534, 571-574`; `internal/onboarding/hardware_evidence.go:69, 89-210, 233-359, 372-476, 527-544`; `internal/onboarding/apptrack.go:267, 313, 340, 587, 748`; `internal/stats/hardwareverify/verify.go:16-30, 126-256, 240-245, 262-368, 394-485`; `internal/ws/admin_hardware_trust.go:42-608`; migrations `007, 008, 015, 016, 017, 019` (019 `:9-12, :17, :505-507`); `cmd/stats-hardware-verifier/main.go:17-41`; `AutotuneHardwareEvidence.swift:12-13, 27-51, 70, 136-168, 264-374`; `AutotuneRuntimeSupport.swift:118-141`; `SEAttestationBuilder.swift:170-174`.

**Hello/heartbeat/routing/tiering**: `internal/ws/messages.go:19-47, 94-136, 298-320, 361-367, 403-446, 528-540, 938, 1149-1253`; `internal/ws/server.go:891-916, 906-910, 1778, 1826-1831, 2116-2464, 2277-2282, 2320, 2332, 2393, 3416, 3423, 3442-3447, 3525-3681, 3734, 4261-4400, 4852-4875`; `internal/pool/provider.go:39, 62-66, 119, 187-201, 216-225, 409-443, 788-862, 1254-1277, 1284-1366 (floor `:1348`, tier-ban `:1352-1355`), 1552-1621, 1811-1923`; `internal/routing/candidate.go:65-92`; `internal/routing/objective.go:55`; `internal/rewards/rewards.go:25`; `internal/autotune/gate.go:8-16, 18-108`; `internal/autotune/evidence_pg.go:24-108, 70-92`; `internal/routing/filter.go:118-188`; `internal/buyer/server.go:901-931, 1092-1096, 1564-1585, 5447, 5637-5647, 6140-6162, 6283-6309, 6385-6450`; `internal/ws/trust_revalidation.go:12-23, 121, 149-210`; `internal/ws/canary_probe.go:27-120`; `internal/canarycorr/epoch.go:1-26, 76, 102, 134, 259, 314, 356`; `internal/ws/admission.go:239`; `CoordinatorClient.swift:385, 2146, 4211, 4401-4423, 4478-4563`; `phase5-gateway/internal/router/server.go:307-312, 575-600, 671-678`.

**Observed-performance + settlement substrate**: `internal/buyer/phase_timing.go:20-29, 204-260`; `markProviderFirstByte` at `internal/buyer/server.go:2439, 2530, 2880, 3086, 3369, 3540, 3646, 3901`; `internal/requestlog/store.go:43-100, 464-489`; `internal/billing/settlement_output.go:22, 46-52, 96`; `internal/billing/payout.go:69, 76-150 (void at :118-128)`; `internal/billing/hotpath.go:13`; `internal/billing/route_snapshot.go:26, 37, 195`; `phase5-gateway/internal/storage/interfaces.go:67-70`; `phase5-gateway/internal/storage/types.go:147-156`; `phase5-gateway/internal/storage/sqlite/migrate.go:3-30`; `phase5-gateway/internal/storage/sqlite/store.go:1291-1320`; `internal/stats/migrations/001_stats_tables.up.sql:18-62`; `internal/providerevents/store.go:35-52, 155-174, 341-343`.

**Tier2/attestation/OPoI**: `specs/SPEC-008-tier2.md:97-102, 841, 941-957, 1229-1247, 1758-1874, 2437`; `internal/tier2/pillar_c.go:65, 156, 295-297, 433-437`; `internal/tier2/pillar_c_se.go:17, 43`; `internal/tier2/pillar_d.go:167-197`; `internal/tier2/catalog.go:331-372, 529-533, 751-757`; `Tier2Attestation.swift:93-96`; `specs/SPEC-022-verified-model-settlement.md:145-149, 421-451, 446`; `internal/billing/settlement_receipts.go:616-622, 700-706, 884-899`; `internal/billing/store.go:202, 294, 909-925`; `internal/config/config.go:505-533, 908, 994, 1047, 1074-1081, 1120, 1836, 2082`; `cmd/coordinator/main.go:601-624, 1622`; `internal/pow/drift.go:15, 112, 127-212`; `specs/SPEC-030-losslessness-probe.md:20, 41, 82`; `internal/ws/losslessness.go:261-1099`; `specs/SPEC-032-proof-of-weights-hello-gate.md:29-52 (quote :38), 99, 137-144, 282-331, 445-462, 516-519, 553-555, 653-655`; `specs/SPEC-036-compute-integrity-receipt.md:41-92, 262-274, 2051-2094, 2323-2331`.

**Governance/contract surfaces**: `specs/AUTHORITY.json` (domains `coordinator-admission-routing`, `billing-settlement-formula`, `hardware-evidence-admission`, `autotune-recommendation`, `installer-autotune-policy`, `sticky-routing-identity`); `specs/CONFORMANCE.json`; `specs/SPEC-002-coordinator.md:934-956, 1666-1690, 1707, 3126-3138`; `specs/SPEC-005-billing.md:526-534, 741-750`; `specs/SPEC-006-buyer-api.md:179, 343, 1007-1011, 3659`.

**UX surfaces**: `internal/stats/handlers.go:77-131`; `internal/stats/poolsnapshot/poolsnapshot.go:66-108, 143-160`; `ProviderHardwareSummary.swift:18, 48-105`; `phase5-gateway/internal/router/disclosure.go:59, 215-227, 300-313`; `phase5-gateway/internal/router/pages.go:27-64`; `internal/buyer/rate_card.go:17-51`; `frontdoor/console/index.html:511-525, 856-874, 1219-1220, 1359-1447`; `frontdoor/provider-portal/index.html:1380, 1399-1419, 1590`; `SelfUpdate.swift:2589-2718`; `RecommendationEmitter.swift:169-177`; `README.md:22, 67, 104, 142`; `docs/using-macprovider-with-openai-sdk.md:202`; `phase7-verify/README.md:129`; `specs/SPEC-007-explorer.md:6-9, 28-57, 675-688`; `specs/SPEC-014-provider-portal.md:925-1013, 1295-1363, 1531`; `specs/SPEC-017-network-stats-api.md:362, 594-661, 730-746`; `specs/SPEC-034-referral-gated-prebeta.md` (header, §8).

### 12.2 Decision-log and issue anchors [E-issue unless noted]

**#744** (open) provenance audit + floor-vs-fit; **#745** (closed) incumbent-benchmark bug; **#742** (closed) swap disqualifier, live prod data at `pool_size: 1`; **#687** (open) oMLX provisional gates + trust invariant; **#584** lab-Mac blocker + canary-induced collapse on the M1 8 GB provider; **#582** stranger-onboarding proof; **PR #772** (#744 partial), **PR #751** (#745 fix), **PR #748** (#742 fix), **PR #387** (SPEC-029), **`d53e8650`** (SPEC-037 IMPL — the effort-calibration reference).

`beta/DECISION_CRITERIA.md` [E-spec]: Entries 109, 134, 191, 195, 196, 198, 199 (Entry 199's blind + real-hardware verification is the methodology precedent this roadmap's IMPL items must follow).

`ops/exceptions/production-exceptions.json` + `ops/runbooks/pearl-exception-clearance-20260722.md` [E-spec] — live overlay truth; `exc-onboarding-autotune-hello-gate` removal condition and `expiry_unknown_reason`; `exc-canary-disabled-enable-gate`.

`docs/research/RESEARCH_231_OMLX_BENCHMARK_CATALOG_MEMO.md` [E-spec] — calibration bands; PP-derived TTFT 1.3–2.5× underestimate; gate-slack policy.

### 12.3 Claims deliberately left unverified

- `[E-session]` Pearl-DB claims in §2.3 — read-only SSH re-verification attempted and blocked by session policy; semantics are code-verified and Entry 198 documents one live instance.
- Live overlay values are from committed 2026-07-22/23 artifacts, not a fresh read.
- `[E-issue]` contents are not in-repo and are not version-pinned by this document.
- **R0's demand numbers do not exist yet.** Every claim in this document about whether observed-evidence machinery is *executable* (as distinct from *correct*) is provisional until R0 runs.

### 12.4 Review history

- **r1** (2026-07-27) — initial six-lane audit.
- **r2** — after adversarial verification (C=1 H=7 M=10 L=7) and product-design critique (C=4 H=11 M=10 L=3). Corrected the `coordinator_observed` unforgeability claim; documented tuple rotatability; split capacity from performance; defined cold start; made the sole-provider floor normative; fixed the §7 ladder inversion; replaced one blocking flag with three tiers; added R4 and R7.
**R-number crosswalk** (numbering changed between revisions; any issue or note referencing an r1/r2 number must be re-read against this table):

| r1 | r2 | r3/r4 | Item |
|---|---|---|---|
| R2 | R1 | **R0 / R1a / R1b** | demand measurement (new in r3) + observed-timing persistence, split |
| R5 | R2 | **R2** | overclaim remediation |
| R1 | R3 | **R3a / R3b** | ceiling detection / enforcement, split |
| — | R4 | **R4** | rank routing on observed throughput (new in r2) |
| R4 | R5 | **R5** | probationary admission |
| R3 | R6 | **CUT** | hello-gate flip (folded into R3b + R5 in r3) |
| — | R7 | **R7** | identity durability (new in r2; re-scoped in r4) |
| R6 | R8 | **R8a / R8b** | provenance in-band / gate re-derivation, split |
| R7 | R9 | **R9** | observed data into drift |
| R8 | R10 | **R10** | spec/doc drift |
| R9 | R11 | **R11** | hash-chain hardening |
| R10 | R12 | **R12** | SPEC-036 compute integrity |

- **r3** — after a second adversarial round (C=2 H=6 M=6 L=3), a second product-design round, and codex security (C=0 H=4 M=2) and architect (C=0 H=4 M=3) audits. Material changes:
  - **§0 added** — minimum path promoted above the executive summary; **R0 (demand measurement) added as the gate** on the whole observed-evidence block, after review found no one had checked that buyer volume can populate the buckets every downstream item consumes.
  - **§5.3.6 reversed** — sole-provider floors now apply to health/liveness uncertainty **only**; capacity/catalog/hash/admission violations fail closed even when that empties the pool. r2's rule created the attacker's ideal case (be the only provider, then switch to an unadmitted model).
  - **§6.3 Step 3 corrected** — `pool.TierProvisional` reuse withdrawn: `Tier` is a per-provider scalar (`pool/provider.go:119`) that cannot express per-(provider, model) state, *and* it already means "canary-sanctioned, ban on next trip" (`:1352-1355`); a third unrelated `TierProvisional` exists in `internal/rewards/`. Probation pricing reopened as **unresolved** after review showed unbilled traffic makes providers serve free and can void payout entirely (`payout.go:118-128`), no discount mechanism exists, and `internal/billing/`+`phase5-gateway/` were missing from the work item.
  - **§6.3 Step 4 corrected** — never promote on absence of evidence; the canarycorr anti-Sybil citation **withdrawn** (that package has no payer concept); the ≥2-payer rule relabeled as friction, not a control; the cross-class operator path relabeled as a **knowing carried exception** to §5.2/§4.8 rather than a design.
  - **Former R6 CUT** — `admitted_but_unapproved` reintroduced the admission bypass the hello gate exists to close and would not clear its own registered exception; what survives is a no-buyer-traffic sandbox inside R5.
  - **R5 marked UNSIZEABLE**, R1 split into R1a/R1b, R3 split into R3a (Tier 0 detection) / R3b (Tier 1 enforcement), effort estimates re-baselined against `d53e8650`, "N=5 providers" withdrawn in favor of a lead-time rule.
  - **New findings**: F11 extended to provider-account rotation (`apptrack.go:313` + open registration); §3.3 Limit 2 (output buffering) and Limit 3 (sample volume) added; §4.5 notes `MaxAdmittedMinRAMGB` is computed then dropped; gateway quota/usage/settlement added to §2.1; R1a flagged as a **governed** SPEC-002/SPEC-005 contract change; settlement non-retroactivity restored (silently dropped in r2); R4's cold-start fallback made conservative instead of self-report; R7 relabeled "raises rotation cost" pending a registration gate.

- **r4** — after a third adversarial round (C=1 H=6 M=11 L=7) on r2, applied together with the codex findings. Material changes:
  - **F11 REVERSED.** r2/r3 claimed sanction state is erasable by rotating the HMAC secret, tagged `[E-code]`. It is false: `canarySanctions` is keyed by `provider_id` alone (`pool/provider.go:558`) and durably persisted (`internal/ws/canary_store.go:14-18`), and HMAC rotation only invalidates the admitted tuple, causing *eviction* (`trust_revalidation.go:92-102`). The error had propagated into §3.4, §6.3 Step 6, §9.4 and a scheduled work item. R7 is re-scoped from "make sanctions durable" (Size M-L) to "close the identity re-registration wash" (Size S-M, a registration-policy question); §9.4's accepted risk is withdrawn.
  - **F13 ADDED** — SPEC-023 v0.8, `status: LOCKED`, disagrees with the live signed catalog on **6 of 7** shared rows, including `google-gemma-4-26b-a4b-it` shipping `recommendable` where the spec says `blocked` and blocked rows are "never … recommended by default." §7 rule 2 is already violated against the normative spec.
  - **§5.2 contradiction resolved, not restated** — the cross-class operator grant is now a *named, logged, capped, buyer-visible* carve-out in the Trusted row, retired by R12, rather than a standing conflict between §5.2/§4.8 and §6.3 Step 4.
  - **§6.3 Step 2 corrected** — the capacity check now includes the 4 GB safety margin the shipped client already enforces (SPEC-023:447, AC-11 `:697`, `AutotuneRecommend.swift:1599, 1824`); without it the coordinator check was looser than the provider binary it backstops.
  - **§5.3.6 hardened** — a held sole-provider floor must degrade to the smallest admitted model, never no-op; and the floor predicate keys on a self-reported `ModelID` a provider can set to gain immunity, so post-R3a floors must key on the admitted identity.
  - **Consistency and citation fixes** — R-number crosswalk added; tier labels reconciled across §9.2 and §10 (every item has exactly one tier; no Tier-1 item precedes a Tier-0 item); canary thin-traffic either/or withdrawn (§6 had already chosen); R5 grandfathering rule added; `runtime_validated_only` given a ladder rung; SPEC-029 class names corrected to their actual identifiers; `spec-drift-remediation.md` line corrected to `:130`; R3a plumbing note added (`autotune.Catalog` lives on `ws.Server`, not `pool`); `account_id` nullability noted as making the ≥2-payer rule unevaluable on legacy paths; NFR-4 remedy narrowed to the three paths it actually omits.
