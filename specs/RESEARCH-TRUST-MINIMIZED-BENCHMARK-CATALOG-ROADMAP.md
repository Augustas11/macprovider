# RESEARCH — Trust-Minimized Benchmark & Catalog Roadmap

Date: 2026-07-27
Status: research document (non-normative; basis for GitHub issues and implementation tracking)
Scope: catalog, benchmark, hardware verification, provider admission, routing, buyer/provider UX trust model
Related: #744, #745 (closed, fixed by #751), #742 (closed, fixed by #748), #687, PR #772, SPEC-008, SPEC-010, SPEC-013, SPEC-017, SPEC-022, SPEC-023 (v0.8), SPEC-027, SPEC-030, SPEC-031, SPEC-032, SPEC-033, SPEC-036

Evidence tags used throughout:

- **[E-code]** — verified by reading code in this repo at `origin/main` (`8a39c636`, 2026-07-27)
- **[E-spec]** — verified by reading a spec/runbook/decision-log document in this repo
- **[E-session]** — reported in a prior operator session (Pearl DB output, live-overlay reads); not re-verified against production during this research pass (a read-only DB query was attempted and blocked by session policy), but corroborated where noted
- **[I]** — inference from the above; clearly a judgment, not an observation

---

## 1. Executive Summary

MacProvider today has a **strong integrity chain over the wrong root**. The catalog signing pipeline, the append-only release ledger, the model-hash consistency checks, the route snapshots, and the settlement receipts are all real and mostly well built — but every performance claim and almost every identity claim they protect originates as **provider self-report**. Signing, verifying, and receipting a self-reported number does not make it true; it makes it *tamper-evidently* self-reported.

Concretely:

1. **Catalog `bench_gate` numbers are not evidence.** Of the 9 live rows, 5 have no throughput benchmark behind their gate at all (`policy`, `never_benched`, `no_throughput_bench`, `runtime_validated_only`), and the 4 "measured" rows were measured on a single M5 32 GB machine — some while the #745 bug meant the benchmark loaded a *different model* than the one it was recorded under (§4.1). Both client and coordinator correctly treat these gates as advisory-only. [E-code, E-spec]
2. **The hardware verifier proves identity anchoring, not benchmark truth.** SPEC-033 §10.2 says so itself: the guarantee is "string-level self-consistency + an operator trust anchor, not proof the benchmarks ran on that hardware," and "cross-provider borrow is blocked, self-fabrication is not." The `hardware_identity_hash` the operator anchors to is an HMAC over a locally generated random file plus two sysctl strings — it is not device-rooted (§4.4). [E-spec, E-code]
3. **Nothing in production ties serving to verification.** The SPEC-032 hello gate is off in the live Pearl overlay (verified 2026-07-22), the canary is off, telemetry drift is off, the losslessness probe is off, and SPEC-036 has zero lines of code. The only enforcing integrity mechanism is Tier-2 Pillar A hash verification — a consistency check on a value the provider computes about itself (§4.6). [E-code, E-spec]
4. **Even with the hello gate on, the capacity ceiling has no routing consumer.** SPEC-032 FR-HG7 is a spec-acknowledged CRITICAL gap: a provider admitted on a small model can heartbeat-switch to a larger or uncatalogued model and the pool applies it unconditionally (§4.5). [E-code, E-spec]
5. **The single most valuable unexploited asset is coordinator-observed performance.** The coordinator already measures true per-request TTFT (`providerFirstByte`) and decode wall-time on every buyer request — and throws them away, because `request_log` has no columns for them (§5.3). This is the only performance signal in the system the provider does not author.

**Why the #744 provenance/signing work is not enough by itself** (required finding): PR #772 was the right *labeling* move — `bench_gate.provenance`, drift surfacing, a buyer TTFT ceiling, a v5 bridge key — but it changes what we *say* about the numbers, not where the numbers *come from*. Three specifics: (a) the provenance values in production are a **hardcoded client-side backfill table**, not signed catalog bytes — the Ed25519 signature covers zero bytes of provenance, and the coordinator accepts nil and substitutes nothing; (b) provenance "does not by itself admit or reject cached benchmarks" (SPEC-023 §3.1) — it is metadata about an advisory field; (c) the enforcement pipeline (`ResolveMaxAdmission`, hash checks, settlement) never reads provenance at all. Signing the catalog harder, or labeling its rows better, cannot fix a system whose admission evidence is fabricatable by construction (§4.2, §4.3). The fix is to *change the evidence class* that admission and gates consume — from provider-claimed to coordinator-observed — which is what the roadmap in §10 sequences.

**The upgrade question** (required finding): the correct design is **not** "lock the provider to the first model selected at hello." An admitted-capacity ceiling frozen at first-hello would block every legitimate upgrade (bigger RAM Mac, better quant, a model added to the catalog later) and would push providers toward reconnect-churn workarounds. The correct mechanism — detailed in §6 — is a ceiling that is (a) enforced continuously (closing FR-HG7), and (b) **raisable through a defined, provider-initiated upgrade flow** whose promotion authority is fresh local evidence *plus coordinator-observed probationary serving*, never self-report alone and never an operator judgment call about performance.

For the small prebeta cohort, the honest position is workable: operator-anchored identity + signed artifact pinning + hash-consistency + observe-mode settlement is *sufficient* when every provider is personally known — provided the UX stops implying more (§8, §9). Before opening beyond personally-known providers, items R1–R5 of the roadmap are blocking.

---

## 2. Current System Map

### 2.1 Components and their real function

| Component | Where | What it actually does | Prod status |
|---|---|---|---|
| Catalog signing | `scripts/resign-autotune-static.sh`, `scripts/catalog-release.py`, `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:1342-1488`, `phase4-coordinator/internal/buyer/autotune_feeds.go:144-205` | Ed25519 over exact feed bytes; keyring v4 `active` / v5 `bridge`; append-only ledger + tombstones; freshness + policy-version + pairing checks | Live; feed is v4-signed `published-2026-07-10-catalog-recovery-v1` |
| Catalog rows | `phase3-binary/dist/static/autotune-candidates.json` (+ canonical + baked copies, byte-parity enforced `catalog-release.py:1594-1602`) | 9 rows: `model_id`, `model_revision`, `model_sha256`, `min_ram_gb`, `min_bandwidth_tier`, `bench_gate{min_sustained_tps,max_4k_ttft_ms}`, `notes` | Live; **no row carries `bench_gate.provenance`** |
| Autotune recommend (SPEC-023 v0.8) | `AutotuneRecommend.swift`, `AutotuneCommand.swift` | Local single-replicate 4k-context probe per candidate (prewarmed, streaming, generation-only TPS: `Stage1Iterator.swift:428-624`); ranks by `payout × measured_tps × demand × shortage` (`AutotuneRecommend.swift:1690-1696`); hard vetoes: thermal, swap, buyer TTFT ceiling, cached-benchmark admission (`:1833-1836`); bench_gate advisory-only (`:1874-1886`) | Live client-side |
| Hardware evidence submission | `AutotuneHardwareEvidence.swift`, `phase4-coordinator/internal/onboarding/hardware_evidence.go` | JCS-canonical evidence blob (chip, RAM, identity hash, 1–64 benchmarks) POSTed with **bearer token only — no signature over the evidence** (`hardware_evidence.go:243-252`); strict shape validation; dedupe by `evidence_sha256` | Live, default-on (`--submit-hardware-evidence` defaults true, `AutotuneCommand.swift:80-81`) |
| Hardware verifier (SPEC-033) | `internal/stats/hardwareverify/verify.go`, `cmd/stats-hardware-verifier/`, migrations 007/008/015/016/017/019 | Deterministic gate pipeline: shape/consistency checks + 4-tuple operator trust match `(provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)` + chip profile existence; `waiting_trust` = everything passed except the operator rows; dual-control operator approval API (migration 019, `internal/ws/admin_hardware_trust.go`) | Live worker on Pearl |
| Hello admission | `internal/ws/server.go:2116-2464` | Catalog-bound 5-field envelope check; model-hash vs signed catalog row (`verifyProviderModelIdentity:891-916`); SPEC-032 hello gate `checkAutotuneHelloGate:2332-2394` → `ResolveMaxAdmission` (`internal/autotune/gate.go:18-58`) computes a `MaxAdmittedModelKey` RAM-tier ceiling from the provider's own verified benchmarks | Envelope + hash checks live; **hello gate `require_autotune_hello_gate: false` in prod** [E-spec `ops/exceptions/production-exceptions.json:20`] |
| Heartbeat | `internal/ws/server.go:4261-4362`, `internal/pool/provider.go:1811-1923` | Re-sends *all* capability fields; pool overwrites `ModelID`, `RAMGB`, `MaxContextTokens`, `MaxConcurrency`, TPS estimate **unconditionally**; no ceiling re-check anywhere | Live |
| Routing | `internal/pool/provider.go:409-443` (`RoutingEligible`), `internal/routing/filter.go:134-188`, `internal/buyer/server.go:5637-5647, 6385-6450` | Eligibility = auth state + catalog-admission mode + no pending receipt key + ready + free slots; match = case-insensitive `ModelID` equality + self-reported context窗 sufficiency + Tier-2 hash predicate | Live; `require_hash_verified: true` since 2026-07-23 |
| Canary (SPEC-031) | `internal/ws/server.go:3525-3681`, `canary_probe.go` | Nonce-echo liveness probe + TTFT/TPS gates + sanction state machine | **Disabled in prod** (`pool.canary_enabled: false`) |
| Tier-2 Pillar A (SPEC-008) | `internal/tier2/catalog.go:331-372, 751-757` | Provider-reported boot-time hash vs signed catalog; `mismatch`/`invalid` always route-excluded; all statuses ≠ `verified` excluded under `require_hash_verified` | **Enforcing in prod** (the only one) |
| SPEC-022 settlement | `internal/billing/settlement_receipts.go`, `route_snapshot.go`, `payout.go` | Receipt binds request↔route-snapshot↔model_hash↔usage; `model_hash: null` → no debit/credit; coordinator-observed token counts cross-check | Shipped; mode default `observe`; no repo evidence of `enforce` on Pearl |
| OPoI / telemetry drift | `internal/pow/drift.go` | WARN-only; TPS drift compares provider heartbeat self-report against provider benchmark self-report; OPoI = same nonce echo as canary | **Dormant** (needs canary + `telemetry_drift.enabled`) |
| Losslessness probe (SPEC-030) | `internal/ws/losslessness.go` | TV-distance between plain/speculative arms of the same provider; cooperative-health only | Shipped code, disabled, verdict function has only test callers |
| Compute-integrity receipt (SPEC-036) | spec only | Would compare served next-token distributions against a coordinator-held trusted reference | **Zero code** [E-code: grep returns 0 hits] |
| Attestation (SPEC-008 Pillar C) | `internal/tier2/pillar_c*.go`, `internal/ws/server.go:1778` | SE P-256 = key custody + session binding; `AttestationTierHardware` **never emitted by any code path**; post-#759 public counters require the hardware tier → structurally 0 | Live but non-load-bearing (`require_attestation: false`) |

### 2.2 Production posture snapshot (as of the latest committed evidence)

| Control | Live value | Evidence |
|---|---|---|
| `tier2.require_hash_verified` | **true** (since 2026-07-23) | `dist/coordinator.yaml:288`; exception `exc-tier2-hash-mismatch-containment` → removed [E-spec] |
| `proof_of_weights.require_autotune_hello_gate` | **false** | `ops/exceptions/production-exceptions.json:20` (verified 2026-07-22); note SPEC-032:551 *incorrectly* still says true [E-spec] |
| `pool.canary_enabled` | **false** | exception `exc-canary-disabled-enable-gate` active [E-spec] |
| `proof_of_weights.telemetry_drift.enabled` | false (default) | `internal/config/config.go`; no committed overlay [E-code] |
| `pool.losslessness_probe.enabled` | false (default) | `config.go:994` [E-code] |
| `tier2.require_attestation` | false (default) | `config.go:1078` [E-code] |
| `settlement.verified_model_settlement_mode` | `observe` (default; unknown overlay) | `config.go:1120`; no `settlement:` block in `dist/coordinator.yaml` [E-code, I] |

### 2.3 The Pearl-DB facts from the triggering session, reconciled

- *"Providers serve traffic daily while hardware verification jobs sit in `waiting_trust`."* Consistent with code: with the hello gate off, hardware verification status has **zero** influence on admission or routing — the only routing-relevant checks are catalog envelope, hash predicate, and pool state (§2.1). Serving and verification are fully decoupled paths today. [E-code; DB observation itself E-session]
- *"`waiting_trust` means the exact provider/hardware trust tuple is missing, not that the provider never served."* Confirmed by semantics: `waiting_trust` is set only when every other gate passed and the reject reason is `missing_trusted_hardware_identity` or `missing_trusted_chip_profile` (`verify.go:240-246`); it self-promotes without resubmission once the operator rows appear, while evidence stays fresh (SPEC-033 AC-HV-3). Live corroboration: Entry 198 — Air5's job sat in `waiting_trust` purely because Pearl lacked an `apple m3` chip profile; once added and dual-control-approved, the same evidence promoted. [E-code, E-spec]

---

## 3. Evidence And Trust Boundaries

### 3.1 Evidence classes

Names chosen to match strings that already exist in the repo where possible (`"provider_reported"` in `internal/buyer/server.go:1096`; `UsageSourceCoordinatorObserved` in `internal/billing/settlement_output.go:22`; `measured_single_host` in the shipped provenance enum).

| Class | Definition | Forgeable by a single malicious provider? | Repo anchors |
|---|---|---|---|
| `provider_self_reported` | Any value computed and transmitted by provider-controlled code: benchmarks (TPS/TTFT/swap/thermal), model hash, weights manifest, RAM, context window, concurrency, TPS estimate, model-load-time, hardware summary | **Yes, trivially** | `messages.go:19-47, 298-320`; `hardware_evidence.go` (bearer-auth only) |
| `operator_approved_identity` | An operator vouches that a provider identity maps to a hardware class: the SPEC-033 trust tuple + chip profile, dual-control approved | No (needs operator), but the *anchored value* (`hardware_identity_hash`) is provider-controlled | migration 019; `admin_hardware_trust.go`; SPEC-033 §2.2/§5.5 |
| `operator_single_host_benchmark` | A measurement the operator personally ran on operator hardware (the M5 32 GB rows; provenance `measured_single_host`) | No, but generalizes poorly across hardware and staled by #745 | `AutotuneRecommend.swift:799-840`; issue #744 audit table |
| `trusted_provider_matrix` | Convergent measurements from ≥N distinct verified providers on ≥M hardware classes (the #687 Stage-4 promotion target) — **does not exist yet** | Only by collusion of N providers | #687 Stage 4; `beta/catalog-expansion/SPEC-023-omlx-provisional-gates-addendum-DRAFT.md` |
| `coordinator_observed` | Measured by coordinator/gateway code on the buyer path: per-request TTFT (`providerFirstByte`), decode wall-time, token counts, error/fault rates, breaker trips; canary results when enabled | **No** (provider can degrade itself but cannot inflate) | `internal/buyer/phase_timing.go:20-29, 204-224`; `settlement_output.go:22,49-50`; `pool/provider.go:1580-1621` |
| `community_unattested` | oMLX board data — self-reported by strangers; advisory prior only | Yes | RESEARCH_231; #687 invariant |

### 3.2 Trust domains, mapped to the class that actually backs them today

| Trust domain | What backs it today | Class | Gap |
|---|---|---|---|
| Catalog artifact identity (`model_sha256`, revision) | Ed25519-signed feed + append-only ledger | operator-authored, cryptographically bound | Sound. This is the strongest domain. |
| Catalog `bench_gate` numbers | 4× single-host measurement (pre-#745-fix, non-reproducing), 5× no measurement | `operator_single_host_benchmark` at best | Advisory-only is the *correct* current treatment; the gap is anything that re-derives authority from them |
| Provider identity/auth | Bearer token + (v2) proof handshake; PoO is a 41-line skeleton + 501 stub | operator-issued credential | Adequate for prebeta |
| Hardware identity | `hardware_identity_hash` = HMAC(local random file secret, providerID\|ramGB\|chip) (`AutotuneRecommend.swift:183-266`) | `provider_self_reported`, then operator-anchored | **Not device-rooted**: copyable, rotatable, forgeable by patched binary. The one real hardware root read anywhere (`IOPlatformSerialNumber`, `SEAttestationBuilder.swift:170-174`) feeds only the SE path and is never cross-checked |
| Model artifact → served tokens | Preflight dir hash (self-enforced) → config value adopted as reported hash (`ModelRuntime.swift:610` — **not re-derived from loaded tensors**) → hash consistency at hello/heartbeat/receipt | `provider_self_reported`, consistency-chained | Complete vs misconfiguration; empty vs an adversary. `weights_manifest_sha256` collected and never compared; SE-signed `claimed.model_hash` discarded (`pillar_c.go`) |
| Benchmark claims | Evidence blob, bearer-auth, shape-checked | `provider_self_reported` | SPEC-033 §10.2 self-fabrication gap; feeds `ResolveMaxAdmission` |
| Buyer-path performance | Phase timings measured, **not persisted**; token counts persisted | `coordinator_observed` | The foundation exists and is discarded (§5.3) |
| Operator approval | Dual-control trust tuple grants; catalog publish authority | `operator_approved_identity` | Structurally fine at cohort scale; becomes a centralized oracle if it starts approving *performance* rather than *identity* (§4.8) |
| Buyer-facing confidence | `tier1_disclosure` (excellent) vs README:22 / stats overview (overstating) | mixed | §4.9, §8 |

---

## 4. What Is Broken Or Weak Today

Ordered by severity for the prebeta trust model. Each finding cites its evidence.

### 4.1 F1 — Catalog gate numbers are unfounded, and the mechanism that produced them was broken until 2026-07-25

The #744 provenance audit (issue body, verified against the shipped backfill table `AutotuneRecommend.swift:799-840`): 4/9 rows measured, all on one M5 32 GB; the 3 rows needing >32 GB are unmeasurable by construction on the only executor; the 2 re-measured rows diverged 1.7–1.8× in *opposite directions*. #745 explains the divergence: until PR #751, `serve --model` overrode the model identity but not `model_artifact_path`, so **every candidate benchmark loaded the incumbent model and recorded the result under the candidate's name** — silently, because preflight validated the incumbent's path against the incumbent's hash. The fix is verified end-to-end [E-code: `Config.swift:489-526` clears the artifact binding on identity change; call chain `AutotuneRecommend.swift:3040-3063` → `CandidateProviderRunner.swift:289-295` → `MacProviderCLI.swift:1024-1026` → `ModelRuntime.swift:601` loads the candidate]. Consequence: **no gate value predating the #751 fix is trustworthy, and no trusted post-#745 matrix exists yet** — which Entry 196 correctly used to reject wholesale gate re-derivation. [E-spec, E-code]

Additional soft spot: the local probe that now feeds first-order ranking (`raw_score ∝ measured_tps`) and the buyer-TTFT hard veto is a **single-replicate** measurement by default (`stage1Replicates` default 1, `AutotuneCommand.swift:37`) — "p95 TTFT" is one sample. [E-code]

### 4.2 F2 — Signing is conflated with truth in naming and prose (and the #744 work does not close this)

The signature proves exact bytes came from a keyring holder. Nothing more. The repo's own strongest statements agree (`keys/README.md:59-66`; SPEC-032:653-655 dropped the false "signed autotune benchmark" claim; Entry 134). But the surfaces still invite the stronger reading: `catalog_trust_blocked` (`AutotuneCommand.swift:1206`), `paidTrustBlockingWarnings` (`AutotuneRecommend.swift:1604`), `"status": "live_verified"` (`autotune_feeds.go:840`), SPEC-023:127 "a trustworthy catalog". SPEC-023 has no "what the catalog signature does not prove" section, unlike SPEC-015's exemplary receipts negative-list (`SPEC-015-receipts.md:2473-2495`). Meanwhile the actual money input — `/v1/rate-card` — is fetched **unsigned** with silent baked fallback (`AutotuneRecommend.swift:1330-1340`), while the advisory TPS numbers get full Ed25519 protection. [E-code, E-spec]

### 4.3 F3 — The shipped provenance is unsigned client-side state, and two provenance vocabularies now coexist

- Every live row omits `bench_gate.provenance`; the values operators see come from the hardcoded backfill table keyed to the exact release SHA (`AutotuneRecommend.swift:757-840`). The signature covers zero provenance bytes. [E-code]
- The coordinator accepts nil for the pinned release and substitutes nothing (`autotune_feeds.go:500-507`) — coordinator-side consumers see no provenance at all. [E-code]
- `catalog-release.py verify` / `verify-directory` do **not** pass `require_provenance` (`:1589, :1649`) — only `generate` enforces it, so deploy/package-time gates would accept a provenance-free release matching the legacy pin. [E-code]
- The #687 oMLX addendum draft defines a *different* provenance enum (`verified_local | omlx_seeded | hand_set` + `gate_seed`) with zero overlap with the six shipped values, and its §1 invariant ("unattested data MUST NEVER hold the gate of a `recommendable` row") is violated in spirit today: all 9 live rows are `recommendable` and 5 of 9 have non-measured provenance. [E-spec]

### 4.4 F4 — The hardware verifier's anchor is a value the provider fully controls

SPEC-033 §10.2 discloses self-fabrication honestly, but frames `hardware_identity_hash` as a stable device anchor. Mechanically it is `HMAC-SHA256(key = 32 random bytes from ~/.config/macprovider/autotune-hmac-secret, msg = provider|ramGB|chip)` (`AutotuneRecommend.swift:183-266`) — chip and RAM are sysctl strings, the secret is a local file. It is copyable between machines, rotatable at will, and forgeable by a patched binary. Evidence submission itself is bearer-token-authenticated JSON with **no signature over the evidence** (`hardware_evidence.go:243-252`; `AutotuneHardwareEvidence.swift:70`). The verifier's guarantee is therefore precisely: *this provider account consistently tells the same story, and an operator vouched for the (chip, memory) class of that story.* [E-code, E-spec]

This matters most where verified evidence becomes authority: `ResolveMaxAdmission` (`internal/autotune/gate.go:18-58`) derives the admission ceiling from the provider's **own submitted benchmarks** — a fabricated benchmark row (right catalog SHA, right artifact hash string, plausible TPS) directly buys a higher serving tier. `benchmarkPassesGate` checks thermal, identity binding, and artifact-hash string equality; it deliberately never checks TPS/TTFT (`gate.go:104-107`) and **never checks `swap_detected`** even though it is decoded (`evidence.go:13`) — the #742 swap veto exists only client-side. [E-code]

### 4.5 F5 — Admission is a one-shot gate with a documented CRITICAL bypass, and it is off anyway

- Off: `require_autotune_hello_gate: false` live on Pearl (verified 2026-07-22; the registered exception keys re-enable to #582 stranger-onboarding proof). SPEC-032's own "production posture" section still claims the opposite — 11 days stale and inverted. [E-spec]
- Even when on: **FR-HG7** — `MaxAdmittedModelKey/ID` is computed at hello and consumed by exactly one reader, canary probe target selection (`ws/server.go:3442-3447`). It appears nowhere in `RoutingEligible()` or buyer matching. A heartbeat can replace `ModelID` with a larger or uncatalogued model and `applyHeartbeatLocked` applies it unconditionally (`pool/provider.go:1851`); a model switch without a loading transition emits no `SwapEvent` (`:1899-1916`). SPEC-032 marks this Gap (CRITICAL-class), with AC-F1/AC-F2 documented as expected-to-fail. [E-code, E-spec]
- **FR-HG6** — no mid-session evidence freshness re-check: a continuously connected provider serves indefinitely on expired evidence. [E-spec]
- Hello also carries a hardware-binding hole SPEC-032 admits: the hello frame has no chip descriptor, so a credential moved to weaker hardware reuses prior evidence until TTL. [E-spec SPEC-032:137-144]

### 4.6 F6 — Every capability input to routing is self-reported and unverified

`RAMGB`, `MaxContextTokens`, `MaxConcurrency`, `ThroughputTPSEstimate`, `ModelParamsB`, `ModelLoadTimeMs` are trusted as-is on hello and re-trusted on every heartbeat [E-code `messages.go:19-47, 298-320`; consumer table in §7 of the hello/routing audit]. Two aggravations: (a) self-reported `RAMGB` is never compared to the *verified* `unified_memory_gb` sitting in the same database; (b) `ModelLoadTimeMs` is the baseline for the Tier-2 Pillar D TTFT-anomaly check (`pillar_d.go:167-197`) — **the provider sets its own anomaly threshold**. [E-code]

### 4.7 F7 — The "observability" mechanisms observe self-report, and the real observations are discarded

- `internal/pow/drift.go` TPS drift compares the provider's live heartbeat TPS claim against the provider's earlier benchmark claim — self-report vs self-report, WARN-only, and dormant anyway. [E-code]
- OPoI is byte-identical to the liveness nonce echo ("aspirational names for a mechanism that does not yet prove what they imply," SPEC-032:307-318), has zero routing readers, and cannot fire while the canary is disabled. [E-code, E-spec]
- Meanwhile the coordinator measures true TTFT and decode wall-time on every buyer request across all 8 relay paths (`phase_timing.go`; `markProviderFirstByte` call sites) and emits them as **response headers only**. `request_log` persists `latency_ms`/`routing_ms`/`queue_wait_ms` and token counts but has **no TTFT or decode column** (`internal/requestlog/store.go:43-100, 464-489`), so per-provider throughput can only be derived as `completion_tokens / latency_ms`, conflating queue+routing+prefill+decode. No aggregate table carries latency or throughput per provider (`001_stats_tables.up.sql:39-62`). [E-code]

### 4.8 F8 — Operator approval is drifting toward a performance oracle

The dual-control trust tuple flow (migration 019) is well built *for identity*. But because verified evidence then feeds `ResolveMaxAdmission` and (per #687 Stage 4) future gate re-derivation, the operator's identity approval transitively **launders self-reported benchmarks into admission authority**. The system's design pressure is for the operator to approve more tuples faster (Entry 198's chip-profile scramble is the live example), which scales exactly as badly as any centralized oracle. The boundary must be: operators approve *identity mappings*; performance authority comes only from `coordinator_observed` evidence. [I, grounded in E-code above]

### 4.9 F9 — UX and docs overstate in a few specific, fixable places

The repo already contains the correct pattern three times (`catalog_evidence_source: "provider_reported"`; gateway `tier1_disclosure` with its caveat strings; leaderboard `rewards_populated`/`partial_history_since`). The violations are localized:

| Surface | Problem | Ref |
|---|---|---|
| `README.md:22` | "the **verified model hash** … **Verifiable inference**, without a datacenter" — unqualified; the hash is self-measured. Likely violates SPEC-006:343's normative no-overclaim rule | [E-spec] |
| `docs/using-macprovider-with-openai-sdk.md:203` | "This is what makes MacProvider verifiable inference" — same gap; contrast `phase7-verify/README.md:129` which gets it right | [E-spec] |
| `autotune --recommend` transcript | Prints "Benchmarked N" where N = *eligible* count, not benchmarked count (`AutotuneRecommend.swift:2057` vs spec slot `{benchmarked_count}`); surfaces **zero** confidence/provenance/drift — #772's additions are JSON-only; warnings reach stderr as bare enum rawValues | [E-code] |
| `AutotuneCommand.swift:958` | Donor message asserts the `$0.0050/hr` gate that SPEC-023 v0.4 deleted | [E-code, E-spec] |
| `/v1/stats/overview` | `bandwidth_gb_per_s`, `network_power_kw`, `gpu_cores_total` are chip-name lookup constants (`ProviderHardwareSummary.swift:48-105`) published unlabeled; `unified_ram_gb_total`/`models_serving` are self-reported; **no provenance field exists on the wire** (the Source column exists only in the spec document) | [E-code] |
| `nodes_hardware_attested` | Structurally always 0 — the only `AttestationTier` writer sets `self_signed` (`ws/server.go:1778`); a reader cannot distinguish "none today" from "unreachable by construction". Entry 109's description is now stale post-#759 | [E-code] |
| `/v1/models` `hash_verified: true` | Bare boolean; the "provider-reported hash" caveat lives only in the gateway disclosure | [E-code] |
| CLI `status` "Pending hardware verification" | Slight overstatement per SPEC-033 §10.2; "awaiting operator approval" in the same string is right | [E-code] |
| Console arm64golf panel | Headline "best verified 12" vs "AlphaDev 17" outruns its (excellent) methodology caveat; data is a hardcoded 2026-06-05 literal with a `last_update` that reads as live | [E-code] |

### 4.10 F10 — Spec/doc drift that will mislead the next implementer

SPEC-032 production-posture section inverted (says gate enabled; it is not). SPEC-033 roster omits migration 019 and the promoteJob re-park/advisory-lock behavior; its §3 schema omits `model_artifact_path`; its §10.4 R1 claim is partially superseded by `evidence_pg.go:80-89`. SPEC-008:97-102 still describes the pre-#759 attestation overstatement as unfixed. SPEC-013 NFR-4 ("nothing leaves the machine") contradicts the default-on evidence submission. SPEC-023 §3.4/§3.5 static-feed URLs are stale. `docs/runbooks/spec-drift-remediation.md:132` contradicts the 2026-07-22 overlay read. [E-spec, E-code]

---

## 5. Correct Target Model

### 5.1 The one-sentence version

**Trust artifacts and identity; treat every provider-supplied number as a claim; let the coordinator's own buyer-path measurements be the only authority that raises anyone's privileges.**

### 5.2 Trusted / Claimed / Observed assignment

| Layer | Contents | Authority granted |
|---|---|---|
| **Trusted** (cryptographic or operator-anchored) | Signed catalog bytes: `model_id`, `model_revision`, `model_sha256`, `min_ram_gb`, `min_bandwidth_tier`, `runtime_status`, provenance *once in-band*; release ledger/tombstones; operator trust tuples (identity only); provider credentials | Defines the *universe* of servable models and who may connect. Never asserts performance. |
| **Claimed** (provider self-report; consistency-checked, never authoritative) | Benchmarks (TPS/TTFT/swap/thermal), model hash, weights manifest, RAM/context/concurrency/TPS estimate, hardware summary, `bench_gate` values themselves until class ≥ `trusted_provider_matrix` | May *lower* the provider's own privileges (self-declared degrade honored immediately); may qualify a provider for **probation**; may never directly grant paid-serving privileges or set enforced thresholds. |
| **Observed** (coordinator/gateway measured) | Per-request TTFT, decode time, tokens, error/fault/breaker events; canary results (when re-enabled); coordinator-observed usage (SPEC-022 R-3.4.1) | The only evidence that promotes: probation → full eligibility, capacity-ceiling raises, catalog gate values, buyer-facing performance statements. Also the evidence that demotes. |

### 5.3 What the coordinator should enforce continuously (not just at hello)

1. **Catalog membership + artifact hash predicate** on the *currently served* model — already live (Tier-2 Pillar A + `require_hash_verified`). Keep.
2. **Capacity ceiling on every routing decision and every heartbeat model change** (closes FR-HG7): serving model's `min_ram_gb` ≤ admitted ceiling, else routing-ineligible for that model (not disconnected — see §6). New model ID on heartbeat triggers ceiling + catalog re-evaluation synchronously.
3. **Evidence freshness re-check on a sweep** (closes FR-HG6) — the 30 s trust-revalidation sweep (`trust_revalidation.go`) is the existing template; add evidence-TTL to its predicate.
4. **Observed-performance floors** (new, from R2 data): a provider whose observed TTFT p95 / decode throughput on a model degrades past operator-set floors for a sustained window moves to degraded/probation for that model. This is the honest replacement for canary latency gates (which SPEC-031 already admits are structurally unreliable non-streaming) — real buyer traffic is the probe.
5. **Self-consistency tripwires** as WARN→sanction escalators: self-reported `RAMGB` vs verified `unified_memory_gb`; heartbeat TPS claim vs *observed* TPS (replacing today's self-vs-self drift check).

### 5.4 What stays advisory

`bench_gate` TPS/TTFT (until re-derived under §7 rules and explicitly promoted per-row), autotune recommendation and ranking, oMLX-seeded priors, drift warnings, OPoI pass-rate, provenance labels themselves. The buyer-TTFT ceiling stays an operator policy knob on the client per Entry 196 — plus its coordinator twin as an observed-floor once R2 lands.

### 5.5 What must exist before any catalog numeric gate changes again

Per Entry 196's rejection rationale ("would turn known-corrupt or partial measurements into fresh authority") plus §7 below: a post-#745 measurement, in-band signed provenance, and — for any gate that *gains enforcement power* — corroboration from `coordinator_observed` data or a `trusted_provider_matrix` quorum.

---

## 6. Provider Model Upgrade Flow

### 6.1 The requirement (and the anti-requirement)

A provider verified on `qwen3-8b` (12 GB row) who buys RAM, or whose 64 GB Mac was simply first benchmarked on a small model, **must** have a path to serve `qwen3-32b` (48 GB row). Freezing providers to the first hello model is rejected: it punishes honest upgrades, creates pressure to churn identities, and confuses "what you first claimed" with "what you can do." The ceiling must be **dynamic and evidence-raised** — the design question is only *which evidence class* may raise it.

### 6.2 The flow

**Step 0 — baseline (exists today).** Provider is admitted with ceiling = `ResolveMaxAdmission(verified evidence)` — max `min_ram_gb` among catalog rows with a passing benchmark. Note the existing mechanism already supports re-submission: autotune can be re-run any time; a new evidence job for the **same hardware tuple** auto-promotes through the verifier without new operator action (the trust row already exists). Only a *hardware change* (new chip/memory → new tuple, guard trigger clears `verified` per migration 016) requires a new operator identity approval. This asymmetry is correct and must be preserved: **same-hardware upgrades need no operator in the loop.**

**Step 1 — claim.** Provider runs `autotune --recommend` including the larger model; submits fresh evidence. This is `provider_self_reported` and grants nothing yet by itself.

**Step 2 — mechanical pre-checks (coordinator, automatic).** Fresh evidence passes the SPEC-033 pipeline against the *existing* trust tuple; the claimed row's `min_ram_gb` must be consistent with the *verified* `unified_memory_gb` of the tuple (a 16 GB-verified tuple can never claim a 48 GB row — this closes the pure-fabrication ceiling raise for the common case and uses data the operator already attested). Swap/thermal flags in the evidence disqualify (bringing the #742 rule coordinator-side).

**Step 3 — probationary admission (new state, the core of the design).** The provider becomes routable on the larger model in a `probation` state: capped routing share (e.g. lowest selection priority, bounded concurrent slots, optional buyer opt-out via existing tier2 knobs), full price. The coordinator collects `coordinator_observed` TTFT/decode/error data on real traffic; where traffic is thin, canary probes (re-enabled per SPEC-031's gate list) supplement. Probation is *per (provider, model)*, not global — the provider keeps full eligibility on already-proven models throughout.

**Step 4 — promotion.** After N observed requests (or K canary passes) within operator-set floors — TTFT p95 under the network buyer-TTFT ceiling, no breaker trips, decode throughput above an absolute sanity floor — the ceiling raise becomes permanent, recorded as an admission event. Authority: `coordinator_observed` only. No operator judgment, no self-report.

**Step 5 — demotion symmetry.** The same observed floors, evaluated continuously (§5.3.4), demote any model — first-hello or upgraded — back to probation/ineligible. Upgrades are therefore not specially distrusted; *everything* is held to the same observed standard, which is what makes admitting them cheap.

### 6.3 Why this resolves the stated design question

"How can provider model upgrades be admitted without trusting provider self-report and without blocking legitimate upgrades?" — Self-report is demoted to a *trigger* (steps 1–2 gate on consistency, not truth); the granting evidence is observation the provider cannot inflate (step 3–4); legitimate upgrades clear probation automatically in proportion to real traffic, with zero operator involvement on unchanged hardware. A fabricator can still *enter* probation but earns capped exposure and is demoted by the very traffic they sought — the blast radius is bounded by the probation caps, which is the correct trust-minimized shape: don't prevent claims, bound their cost.

---

## 7. Catalog Gate Promotion Rules

Provenance ladder (reconciling the shipped enum with the #687 draft — the shipped six values stay; `omlx_seeded` joins them; the draft's `verified_local`/`hand_set` are subsumed):

```
never_benched / no_throughput_bench / policy / legacy_unverified   (no measurement)
        ↓ seed (advisory only)
omlx_seeded                                                        (community prior, #687)
        ↓ operator measures post-#745
measured_single_host                                               (one machine, one operator)
        ↓ N verified providers × M hardware classes converge,
          corroborated by coordinator_observed serving data
trusted_provider_matrix                                            (promotable to enforcement)
```

Rules:

1. **Provenance lives in the signed bytes.** The next catalog release carries `bench_gate.provenance` in-band for all rows; the client backfill table and the coordinator nil-acceptance are retired with that release (the triple-pinned exception then guards only the historical release, as designed). `catalog-release.py verify`/`verify-directory` gain `require_provenance` (closing F3's deploy-gate gap).
2. **No gate value changes without a post-#745 measurement** of that row (Entry 196's constraint, kept until superseded by rule 4).
3. **Advisory by default, forever, per row.** A gate may only gain enforcement power (veto, admission input) when its provenance reaches `trusted_provider_matrix` — and then under a *new field name* per SPEC-023:71-74's own guidance (`hard_min_sustained_tps`), so the advisory wire field never silently changes semantics.
4. **Promotion arithmetic** (#687 Stage 4, pulled ahead of Stages 1–3 as #744 already argues): recompute the gate from ≥N distinct verified providers' post-#745 measurements on ≥M hardware classes, cross-checked against `coordinator_observed` serving performance for providers actually serving that row. N/M are open questions (§11) — but N ≥ 3 and M ≥ 2 as floors, and the oMLX seed is dropped at promotion.
5. **`recommendable` requires honesty, not measurement**: a row may stay `recommendable` with weak provenance (today's reality) *because gates are advisory*; but a row must never be `recommendable` while `omlx_seeded` (the #687 invariant, adopted), and any UX describing a recommendable row must render its provenance class (§8).
6. **Unsigned inputs off the money path**: sign the rate card (or fold it into the signed release unit). It is currently the only unsigned input in the earnings-ranking product. [F2]

---

## 8. Buyer/Provider UX Requirements

Principle: **the machine-readable path is already mostly honest; bring the human-readable path up to it.** The house pattern exists — replicate it.

1. **Every performance or verification claim carries its evidence class**, using the existing vocabulary: `provider_reported`, `operator_approved`, `coordinator_observed`, plus the provenance enum for gate values. Model surfaces: `catalog_evidence_source` (`buyer/server.go:1096`), `tier1_disclosure` (`disclosure.go:215-227,300-313`), leaderboard `rewards_populated`.
2. **Fix the two normative-rule violations**: `README.md:22` and `docs/using-macprovider-with-openai-sdk.md:203` get the `phase7-verify/README.md:129` treatment (state what the signature proves; enumerate what it does not). SPEC-006:343/3659 already mandates this.
3. **Transcript parity with JSON** in `autotune --recommend`: render `confidence`, per-row provenance class, and drift in the human transcript; fix "Benchmarked N" to print the benchmarked count (or relabel); route warnings through human-readable lines, not bare enum rawValues on stderr. The `RecommendationEmitter.swift:169-177` style ("measured:", "not probed", explicit replicates) is the standard.
4. **Delete stale claims**: the `$0.0050/hr` donor string (`AutotuneCommand.swift:958`); update Entry-109-derived prose about `nodes_hardware_attested`.
5. **Stats overview honesty**: either add a per-field `source` object to `/v1/stats/overview` or split synthetic fields (`bandwidth_gb_per_s`, `network_power_kw`, `gpu_cores_total` — chip-table constants) under an explicitly-labeled `estimated_capacity` sub-object; label `unified_ram_gb_total`/`models_serving` as provider-reported. While `AttestationTierHardware` is unreachable, report `hardware_attestation: "unsupported"` semantics consistently with the gateway's `"none"` instead of a bare 0 counter.
6. **Provider-side verification visibility**: the CLI `status` strings are close; s/"Pending hardware verification"/"Pending operator identity approval (hardware class)"/ aligns with SPEC-033 §10.2. The portal shows nothing today (deferred Open Q5) — when it does, `waiting_trust` must render as "operator approval pending", never as a provider fault, and never as "hardware verified" once granted.
7. **Probation is visible**: when §6 lands, buyers see per-model `probation` state through the existing `/v1/models` count-breakdown pattern; providers see it with the promotion criteria and progress. Weak-vs-strong evidence must be *visible at the point of choice*, not only in docs.

---

## 9. Prebeta Minimum Viable Trust Model

### 9.1 What is acceptable *now* (small, personally-known, referral-gated cohort — SPEC-034 context)

Acceptable to rely on, with eyes open [I]:

- **Operator-approved identity** (dual-control trust tuples) as the admission root — at cohort scale the operator genuinely knows each Mac; the oracle risk (F8) is not yet binding.
- **Signed catalog artifact pinning + Tier-2 Pillar A + `require_hash_verified`** — closes misconfiguration/drift, which at this scale is the *actual* observed failure mode (every incident in the log — #742's swap selection, #745's mislabeled benchmarks, Entry 198's chip-profile gap — was honest-system error, not adversarial).
- **SPEC-022 observe mode** — receipts + route snapshots accumulate evidence without money-path risk.
- **Advisory gates + client-side vetoes (swap/thermal/buyer-TTFT)** — providers in the cohort run unmodified binaries, so client-side enforcement holds *for now*.
- **Manual operator response** to drift/incidents in place of the disabled canary — legitimate per Entry 195's small-cohort operating posture.

Not acceptable even now: the UX overstatements (§4.9) — they misrepresent to *buyers*, whose trust does not scale down with cohort size; and unmonitored heartbeat model-switching (F5) — it silently invalidates the one enforcement chain that is live (the hash predicate is re-checked per heartbeat, but the capacity logic is not).

### 9.2 What must exist before opening beyond personally-known providers

The threat model flips from "honest mistakes" to "anonymous strangers with a payout incentive" the moment referral gating loosens. Blocking set: R1–R5 below (ceiling enforcement, observed-performance persistence, hello gate on, probationary upgrade flow, UX honesty). Explicitly *not* blocking: SPEC-036 compute-integrity (its own §6.1 admits enforce is unreachable at current supply), hardware-rooted device identity (MDA Phase 3), losslessness enforcement — these are post-beta hardening.

---

## 10. Roadmap / Issue Breakdown

Ranked in implementation order. "Blocks prebeta *opening*" = must land before loosening referral gating beyond personally-known providers; the current closed cohort can operate during implementation.

---

### R1 — Enforce the capacity ceiling continuously (close SPEC-032 FR-HG7 + FR-HG6)

- **Problem**: `MaxAdmittedModelKey/ID` has no routing consumer; heartbeat model switches apply unconditionally; no mid-session evidence recheck. A provider admitted on a small model can serve any catalogued (or, with hash checks off, uncatalogued) larger model.
- **Impact**: CRITICAL (spec's own rating). Invalidates the entire admission design whenever the gate is on; today it means the gate is not worth turning on.
- **Proposed change**: (a) persist the admitted ceiling on `pool.Provider`; (b) `applyHeartbeatLocked` on `modelIDChanged` → re-evaluate `EvaluateHelloGate` against stored evidence; over-ceiling/uncatalogued → routing-ineligible for that model + provider event (not a disconnect); (c) add evidence-TTL to the 30 s `trust_revalidation.go` sweep; (d) decode and enforce `swap_detected` in `benchmarkPassesGate` (closing the #742 coordinator asymmetry).
- **Files**: `phase4-coordinator/internal/pool/provider.go` (`applyHeartbeatLocked`, `RoutingEligible` or the routing filter), `internal/ws/server.go`, `internal/ws/trust_revalidation.go`, `internal/autotune/gate.go`, `internal/routing/filter.go`.
- **Tests/evidence**: SPEC-032 AC-F1/AC-F2 flipped from expected-fail to pass; heartbeat-switch integration test; sweep TTL-expiry test; three-lane codex audit (money-path-adjacent).
- **Open questions**: exact ineligibility semantics for in-flight requests on the demoted model; whether uncatalogued switch should also fence when `ModelHashActive` is false.
- **Blocks prebeta opening**: **yes**.

### R2 — Persist coordinator-observed per-request performance

- **Problem**: True TTFT and decode time are measured on every request and discarded (headers only); `request_log` cannot answer "what TPS does provider X actually deliver on model Y."
- **Impact**: Foundation for everything: upgrade probation (R4), gate re-derivation (R6), honest drift detection (R7), buyer-facing performance claims. Without it, every performance statement in the system remains self-reported.
- **Proposed change**: add `ttft_ms` (dispatch-done→first-byte) and `decode_ms` columns to `request_log` (nullable; populated from `requestPhaseTiming`); add a per-(provider, model) rolling aggregate (p50/p95 TTFT, tokens/decode-second, sample count) — internal/operator-facing only, respecting the SPEC-017 anonymity-set constraint (no public per-provider publication).
- **Files**: `phase4-coordinator/internal/requestlog/store.go` (+ migration), `internal/buyer/phase_timing.go`, `internal/buyer/server.go` (write path), new aggregate in `internal/stats/` or `internal/pool/`.
- **Tests/evidence**: timing-column population across streaming/non-streaming/WS-tunnel paths; null-when-unmeasured semantics; migration up/down; no change to public stats surfaces.
- **Open questions**: retention window; whether gateway-side timing should also persist for cross-checking the coordinator.
- **Blocks prebeta opening**: **yes** (cheap, and everything downstream needs its data accumulating early).

### R3 — Re-enable the hello gate in production (existing #582 exception path)

- **Problem**: `require_autotune_hello_gate: false` live; hardware verification currently gates nothing.
- **Impact**: Admission control exists only on paper until flipped.
- **Proposed change**: execute the registered exception's own re-enable condition — a stranger/fresh onboarding proof (#582 pattern, Entry 198 template) with the gate on, after R1 lands (turning it on before R1 enforces a gate with a known CRITICAL bypass — acceptable for the closed cohort, not for opening). Update SPEC-032's posture section (see R8) in the same motion.
- **Files**: Pearl overlay (ops change, not repo code); `ops/exceptions/production-exceptions.json`; journey evidence under `journeys/evidence/`.
- **Tests/evidence**: live onboarding journey with gate on; `waiting_trust` → approval → admitted flow re-proven; buyer probe through the gated provider.
- **Open questions**: sequencing vs single-provider-pool fragility (incident 2026-07-10: no non-urgent coordinator restarts on a single-provider fleet — coordinate with a config-reload-safe rollout).
- **Blocks prebeta opening**: **yes**.

### R4 — Probationary model-upgrade flow (§6)

- **Problem**: No defined path from a verified small model to a larger one that neither trusts self-report nor blocks legitimate upgrades; today (gate off) upgrades are unchecked, and (gate on) upgrades are frozen until new evidence + nothing re-checks anyway.
- **Impact**: Without it, the ceiling from R1+R3 hardens into exactly the "first-hello freeze" this document rejects.
- **Proposed change**: per-(provider, model) `probation` state; entry via fresh evidence + verified-tuple memory consistency check; capped routing share during probation; promotion on N observed requests / K canary passes within floors (R2 data); demotion symmetry; provider/buyer visibility per §8.7. Needs a SPEC amendment (SPEC-032 or a new SPEC section) before IMPL, per house process.
- **Files**: `internal/pool/provider.go` (state machine), `internal/routing/filter.go` (share cap), `internal/autotune/gate.go` (entry checks), `internal/onboarding/` (evidence linkage), spec under `specs/`.
- **Tests/evidence**: state-machine unit tests; promotion/demotion integration tests over synthetic observed data; fabricated-benchmark adversarial test proving bounded exposure.
- **Open questions**: N/K/floors defaults and operator override surface; probation pricing (full vs discounted); minimum traffic problem for rarely-bought models (canary dependency → SPEC-031 re-enable preconditions).
- **Blocks prebeta opening**: **yes** (the upgrade path must exist before strangers join; the closed cohort can upgrade via operator hand-holding meanwhile).

### R5 — UX honesty sweep

- **Problem**: §4.9's table — README:22, SDK doc, transcript parity, "Benchmarked N", `$0.0050/hr`, stats-overview labeling, `hash_verified` scalar caveat, `status` wording.
- **Impact**: Buyer-facing misrepresentation independent of cohort size; SPEC-006:343 is already normative and violated.
- **Proposed change**: per-item fixes as specified in §8; one PR for docs/strings, one for the transcript/JSON parity (Swift), one for the stats-overview `source` labeling (Go, SPEC-017 amendment).
- **Files**: `README.md`, `docs/using-macprovider-with-openai-sdk.md`, `AutotuneRecommend.swift` (`humanTranscript`), `AutotuneCommand.swift:958,982-984`, `internal/stats/handlers.go` + `poolsnapshot.go` + SPEC-017, `frontdoor/console/index.html` (arm64golf staleness label).
- **Tests/evidence**: `StatusCommandTests`/transcript snapshot tests; SPEC-006:3659's audit-cycle language check run over the diff; stats contract tests.
- **Open questions**: whether `/v1/stats/overview` field additions need a partner-facing deprecation window.
- **Blocks prebeta opening**: **yes** (cheap; honesty debts compound with cohort growth).

### R6 — In-band signed provenance + gate re-derivation pipeline (#687 Stage 4 pulled ahead)

- **Problem**: Provenance is unsigned client-side state (F3); no trusted post-#745 gate matrix exists; two provenance vocabularies unreconciled; `verify` weaker than `generate`.
- **Impact**: Catalog gates stay permanently untrustworthy — acceptable while advisory, but blocks ever using them for anything, and blocks honest high-memory rows.
- **Proposed change**: next catalog release ships in-band provenance (retiring the backfill); `require_provenance` added to `verify`/`verify-directory`; adopt the §7 ladder including `omlx_seeded` into the shipped enum (superseding the draft's competing enum); implement Stage-4 promotion tooling: recompute gates from ≥N verified-provider post-#745 evidence rows cross-checked against R2 observed data; sign a re-derived release.
- **Files**: `scripts/catalog-release.py`, `phase3-binary/catalog/autotune/autotune-candidates.json`, `AutotuneStrictJSON.swift`/`AutotuneRecommend.swift` (retire backfill on new release), `autotune_feeds.go`, promotion script under `scripts/`, SPEC-023 amendment folding the #687 draft.
- **Tests/evidence**: `scripts/test-catalog-release.sh` extended; provenance-required fail-closed tests on both client and coordinator; promotion-arithmetic fixtures.
- **Open questions**: N/M quorum values; v5 signer activation timing (bridge-capable client floor per Entry 196 — this release may be the natural activation point).
- **Blocks prebeta opening**: no — follows (gates are advisory; honesty about them ships in R5).

### R7 — Wire observed data into drift/enforcement; retire self-vs-self checks

- **Problem**: `pow/drift.go` compares self-report to self-report; Pillar D's anomaly baseline is provider-supplied; canary latency gates are structurally unreliable.
- **Impact**: The "observability" story becomes real; continuous floors (§5.3.4) become enforceable.
- **Proposed change**: feed R2 aggregates into the drift evaluator as the baseline side; replace `ModelLoadTimeMs`-derived anomaly thresholds with observed-history thresholds; add the RAM self-report vs verified-tuple tripwire; escalation path WARN → probation (R4 state machine reused).
- **Files**: `internal/pow/drift.go`, `internal/tier2/pillar_d.go`, `internal/ws/server.go` (heartbeat), config knobs.
- **Tests/evidence**: drift-detection tests with fabricated heartbeat claims vs observed history; no-false-positive tests over thin-traffic windows.
- **Open questions**: window sizes; interaction with SPEC-031 re-enable (canary and observed floors overlap — decide the division of labor explicitly).
- **Blocks prebeta opening**: no — follows R2/R4.

### R8 — Spec/doc drift reconciliation

- **Problem**: §4.10's list — SPEC-032 posture inverted, SPEC-033 roster/schema gaps, SPEC-008 stale attestation note, SPEC-013 NFR-4 contradiction, SPEC-023 URL staleness, Entry-109 staleness.
- **Impact**: The next implementer (human or agent) will act on wrong premises; this research pass caught three such traps only by cross-checking overlays.
- **Proposed change**: docs-only PR batch; add a "what the catalog signature does not prove" section to SPEC-023 (the SPEC-015 pattern); amend SPEC-013 NFR-4 to reference the SPEC-023 submission carve-out.
- **Files**: `specs/SPEC-032-*.md`, `specs/SPEC-033-*.md`, `specs/SPEC-008-tier2.md`, `specs/SPEC-013-cli-autotune.md`, `specs/SPEC-023-*.md`, `docs/runbooks/spec-drift-remediation.md`.
- **Tests/evidence**: spec governance checks; CONFORMANCE.json updates.
- **Open questions**: none material.
- **Blocks prebeta opening**: no — but cheap and high-leverage; do alongside R1–R5.

### R9 — Low-cost hash-chain hardening

- **Problem**: SE attestation already signs `claimed.model_hash` and the coordinator discards it; `weights_manifest_sha256` is collected and never compared; rate card unsigned.
- **Impact**: Incremental — binds self-assertions to sessions and closes the unsigned money input; does not defeat a determined adversary (that is SPEC-036 territory).
- **Proposed change**: compare SE `claimed.model_hash` to the catalog row in `pillar_c.go`; define an expected-manifest source and compare `weights_manifest_sha256` (or stop collecting it — dead telemetry is its own overclaim); sign the rate card into the release unit.
- **Files**: `internal/tier2/pillar_c.go`, `internal/pool/provider.go`, `AutotuneRecommend.swift:1330-1340`, `internal/buyer/rate_card.go`, release scripts.
- **Tests/evidence**: pillar-C mismatch tests; rate-card signature verification tests.
- **Open questions**: whether manifest comparison needs a catalog schema addition (per-row safetensors manifest hash).
- **Blocks prebeta opening**: no.

### R10 — SPEC-036 compute-integrity implementation (post-beta)

- **Problem**: The only designed mechanism that roots model-identity claims in coordinator-held reference data has zero code.
- **Impact**: This is the eventual answer to "provider falsifies its own hash measurement" — the gap every current surface disclaims.
- **Proposed change**: implement per the merged SPEC in observe mode; enforce is explicitly unreachable at current supply (SPEC-036 §6.1) and stays maintainer-gated.
- **Files**: per SPEC-036; new `internal/` package + provider protocol support.
- **Tests/evidence**: per SPEC-036 ACs.
- **Open questions**: trusted-reference hosting economics; probe-awareness arms race (spec §4 is candid it does not defeat a probe-aware adversary).
- **Blocks prebeta opening**: no — explicitly post-beta.

Sequencing summary: **R1 → R2 → R3 → R4 → R5** is the prebeta-opening critical path (R2 can start in parallel with R1; R5 in parallel with everything); **R6 → R7** ride on R2's data; **R8** is continuous hygiene; **R9–R10** are hardening.

---

## 11. Open Questions

1. **Probation parameters** (R4): N observed requests / K canary passes / floor values; per-model or per-RAM-tier defaults; who may override (operator knob vs spec constant).
2. **Quorum for `trusted_provider_matrix`** (R6): N providers, M hardware classes; how to treat the long tail of rows only one provider ever serves.
3. **Observed-data publication vs anonymity**: SPEC-017 ruled per-request decode speed unpublishable on anonymity-set grounds. R2 keeps aggregates internal; at what pool size (if any) do per-model network aggregates become safe to publish, and does the buyer-facing probation state leak the same information?
4. **Hardware identity rooting**: does prebeta ever need a device-rooted identity (serial-derived, or MDA Phase 3), or is the operator-anchored HMAC acceptable until public opening? Current position [I]: acceptable while operators personally approve tuples; revisit at opening.
5. **Canary vs observed floors division of labor** (R7): with real-traffic floors in place, does the canary shrink to a liveness/instruction-following probe only (its honest capability per its own source comments)?
6. **Single-provider-pool fragility**: every enforcement addition (R1 demotions, R4 demotion symmetry, R3 gate-on) can empty a pool of one. FR-CAN22-style last-provider floors exist for canary; the same floor semantics need defining for ceiling/probation demotions.
7. **Should `waiting_trust` block anything in prebeta?** Today it blocks nothing (gate off). After R3 it blocks admission. Is there a middle state — admitted-but-flagged — for the window where an operator simply hasn't approved a tuple yet (the Entry 198 situation), to avoid punishing providers for operator latency?
8. **SPEC-022 enforce timing**: observe→enforce is orthogonal to this roadmap but interacts with R4 (probation providers generate receipts); decide whether enforce precedes or follows opening.
9. **Rate-card signing mechanics** (R9): separate sidecar vs folding into the release unit (affects rotation story and the v5 activation plan).

---

## 12. Evidence Appendix

### 12.1 Primary code references by area

**Catalog signing/release**: `scripts/resign-autotune-static.sh:10-128`; `scripts/catalog-release.py:242-336, 410-541, 810-855, 1499-1649`; `scripts/sign-catalog.go:143-147, 309-318, 361-364`; `phase3-binary/catalog/autotune/trusted-keys.json`; `phase3-binary/dist/static/keys/README.md:59-129`; `AutotuneRecommend.swift:1260-1488, 1604-1616`; `AutotuneCatalog.generated.swift:10-19`; `phase4-coordinator/internal/buyer/autotune_feeds.go:29-30, 144-237, 482-541, 840`; `phase4-coordinator/dist/coordinator.yaml:211-217`; `internal/buyer/server.go:673-678`.

**bench_gate/autotune**: `specs/SPEC-023-installer-autotune-recommend.md:9-34, 226-252, 380-461, 498-533, 551, 670-737, 791`; `AutotuneRecommend.swift:60-116 (tier derive), 471-544, 746-849 (provenance+backfill), 1678-1696 (scoring), 1811-1886 (eligibility/advisory), 1927-1977, 1998-2084 (JSON/transcript), 2377-2400 (swap), 3028-3129 (filter), 3133-3178 (canonical hash)`; `AutotuneCommand.swift:7, 37, 47-51, 80-81, 608-611, 719-724, 872-921, 950-984, 1045-1073`; `Stage1Iterator.swift:380-624`; `ConfigApplier.swift:172-184`; `specs/SPEC-013-cli-autotune.md:435-586, 1043-1300`.

**#745 fix chain**: `Config.swift:489-526, 592-616`; `CandidateProviderRunner.swift:269-305`; `MacProviderCLI.swift:373-378, 559-736, 945, 1024-1026, 2012-2017`; `ModelRuntime.swift:601, 610, 822-829`; `AutotuneHardwareEvidence.swift:210-213, 340-365`; `hardware_evidence.go:64-66`.

**Hardware verifier**: `specs/SPEC-033-hardware-verifier.md:76-78, 91-123, 183-222, 266-273, 298-362, 367-388, 419, 448-534, 571-574`; `phase4-coordinator/internal/onboarding/hardware_evidence.go:89-210, 233-359, 372-476, 527-544`; `internal/stats/hardwareverify/verify.go:16-30, 126-256, 262-368, 394-485`; `internal/ws/admin_hardware_trust.go:42-608`; migrations `007, 008, 015, 016, 017, 019` under `internal/stats/migrations/`; `cmd/stats-hardware-verifier/main.go:17-41`; `AutotuneHardwareEvidence.swift:12-13, 27-51, 70, 136-168, 264-374`; `AutotuneRuntimeSupport.swift:118-141`; `AutotuneRecommend.swift:183-266` (HMAC identity); `SEAttestationBuilder.swift:170-174`.

**Hello/heartbeat/routing**: `internal/ws/messages.go:19-47, 94-136, 298-320, 361-367, 403-446, 528-540, 938, 1149-1253`; `internal/ws/server.go:891-916, 955-1068, 1315-1506, 1778, 1826-1831, 2116-2464, 2666, 3442-3447, 3525-3681, 4261-4400, 4852-4875`; `internal/pool/provider.go:62-66, 187-201, 216-225, 409-443, 788-862, 1284-1366, 1552-1621, 1811-1923`; `internal/autotune/gate.go:8-108`; `internal/autotune/evidence_pg.go:24-108`; `internal/routing/filter.go:118-188`; `internal/buyer/server.go:901-931, 1092-1096, 1574-1698, 5637-5647, 6140-6162, 6283-6309, 6385-6450`; `internal/ws/trust_revalidation.go:22-210`; `internal/ws/canary_probe.go:27-120`; `internal/ws/canary_correlation.go:431-497`; `CoordinatorClient.swift:385, 2146, 4211, 4401-4423, 4478-4563`; `phase5-gateway/internal/router/server.go:307-312, 575-600, 671-678`.

**Observed-performance substrate**: `internal/buyer/phase_timing.go:20-29, 204-260`; `markProviderFirstByte` sites `internal/buyer/server.go:2439, 2530, 2880, 3086, 3369, 3540, 3646, 3901`; `internal/requestlog/store.go:43-100, 464-489`; `internal/billing/settlement_output.go:22, 49-50, 96`; `internal/stats/migrations/001_stats_tables.up.sql:18-62`; `internal/providerevents/store.go:35-52, 155-174, 341-343`; `phase5-gateway/internal/router/phase_timing.go:9-56`.

**Tier2/attestation/OPoI/settlement**: `specs/SPEC-008-tier2.md:97-102, 841, 941-957, 1229-1247, 1758-1874, 2437`; `internal/tier2/pillar_c.go:65, 156, 295-297, 433-437`; `internal/tier2/pillar_c_se.go:17, 43`; `internal/tier2/pillar_d.go:167-197`; `internal/tier2/catalog.go:331-372, 529-533, 751-757`; `Tier2Attestation.swift:93-96`; `specs/SPEC-022-verified-model-settlement.md:145-149, 421-451`; `internal/billing/route_snapshot.go:26, 195`; `internal/billing/settlement_receipts.go:616-622, 700-706, 884-899`; `internal/billing/store.go:202, 294, 909-925`; `internal/billing/payout.go:76-150`; `internal/config/config.go:505-533, 908, 994, 1047, 1074-1081, 1120, 1836, 2082`; `specs/SPEC-027-provider-proof-of-ownership.md` (41 lines); `cmd/coordinator/main.go:601-624, 1622`; `internal/pow/drift.go:15, 112, 127-212`; `specs/SPEC-030-losslessness-probe.md:20, 41, 82`; `internal/ws/losslessness.go:261-1099`; `specs/SPEC-032-proof-of-weights-hello-gate.md:29-52, 99, 137-144, 282-331, 445-462, 516-519, 551-554, 653-655`; `specs/SPEC-036-compute-integrity-receipt.md:41-92, 262-274, 2051-2094, 2323-2331`.

**UX surfaces**: `internal/stats/handlers.go:77-131`; `internal/stats/poolsnapshot/poolsnapshot.go:66-108, 143-160`; `internal/stats/hardware/cache.go:96-160`; `ProviderHardwareSummary.swift:18, 48-105`; `phase5-gateway/internal/router/disclosure.go:59, 215-227, 300-313`; `phase5-gateway/internal/router/pages.go:27-64`; `phase5-gateway/internal/router/templates/docs.md:145-155`; `internal/buyer/rate_card.go:17-51`; `frontdoor/console/index.html:511-525, 856-874, 1219-1220, 1359-1447`; `frontdoor/provider-portal/index.html:1380, 1399-1419, 1590`; `SelfUpdate.swift:2589-2718`; `RecommendationEmitter.swift:169-177`; `README.md:22, 67, 104, 142`; `docs/using-macprovider-with-openai-sdk.md:203`; `phase7-verify/README.md:129`; `specs/SPEC-006-buyer-api.md:343, 3659`; `specs/SPEC-007-explorer.md:6-9, 28-57, 675-688`; `specs/SPEC-014-provider-portal.md:925-1013, 1295-1363, 1531`; `specs/SPEC-017-network-stats-api.md:362, 594-661, 730-746`.

### 12.2 Decision-log and issue anchors

- Issue #744 (open, P2) — provenance audit table; floor-vs-fit analysis; #687 Stage-4 pull-ahead argument. Issue #745 (closed) — the incumbent-benchmark bug, code-verified chain. Issue #742 (closed) — swap disqualifier + 60 s default removal, live incident data (`swap_detected=true` served in prod, pool_size 1). Issue #687 (open) — oMLX provisional gates draft + trust invariant. PR #772 — the #744 partial (SPEC-023 v0.8). PR #751 — #745 fix. PR #748 — #742 fix.
- `beta/DECISION_CRITERIA.md`: Entry 109 (display-capacity fallback, now partially stale), Entry 134 ("signed benchmark" over-claim correction), Entry 191 (`require_hash_verified` flip), Entry 195 (small-cohort ops posture), Entry 196 (#744 bridge decisions + rejected re-derivation), Entry 198 (Air5 `waiting_trust` → dual-control approval → serving, with evidence artifact SHA), Entry 199 (blind + real-hardware verification as the runtime-feature merge gate — methodology precedent this roadmap's audit items should follow).
- `ops/exceptions/production-exceptions.json` + `ops/runbooks/pearl-exception-clearance-20260722.md` — live overlay truth for gate/canary/hash flags.
- `docs/research/RESEARCH_231_OMLX_BENCHMARK_CATALOG_MEMO.md` — oMLX calibration bands, PP-derived TTFT 1.3–2.5× underestimate (#9), gate-slack policy (#10).

### 12.3 Claims deliberately left as [E-session]

- Daily serving rows and `waiting_trust` job counts in the Pearl DB (prior session's DB output). Re-verification via read-only SSH was attempted during this pass and blocked by session permission policy; the *semantics* are independently code-verified in §2.3, and Entry 198 provides one fully-documented live instance.
- The live overlay values are taken from the committed 2026-07-22 verification artifacts, not a fresh read; if any flag was flipped after 2026-07-23, §2.2 is stale to that extent.
