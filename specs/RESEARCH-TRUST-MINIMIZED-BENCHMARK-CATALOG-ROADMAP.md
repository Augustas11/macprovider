# RESEARCH — Trust-Minimized Benchmark & Catalog Roadmap

Date: 2026-07-27 (r2 — revised after adversarial + product-design review)
Status: research document (non-normative; basis for GitHub issues and implementation tracking)
Scope: catalog, benchmark, hardware verification, provider admission, routing, buyer/provider UX trust model
Related: #744, #745 (closed, fixed by #751), #742 (closed, fixed by #748), #687, #584, PR #772, SPEC-008, SPEC-010, SPEC-013, SPEC-017, SPEC-022, SPEC-023 (v0.8), SPEC-027, SPEC-029, SPEC-030, SPEC-031, SPEC-032, SPEC-033, SPEC-034, SPEC-036

Evidence tags used throughout:

- **[E-code]** — verified by reading code in this repo at `origin/main` (`8a39c636`, 2026-07-27)
- **[E-spec]** — verified by reading a spec/runbook/decision-log document **in this repo**
- **[E-issue]** — sourced from a GitHub issue or PR body (not in-repo; re-readable via `gh issue view`)
- **[E-session]** — reported in a prior operator session (Pearl DB output, live-overlay reads); not re-verified during this pass (a read-only DB query was attempted and blocked by session policy), corroborated where noted
- **[I]** — inference; a judgment, not an observation

---

## 1. Executive Summary

MacProvider today has a **strong integrity chain over the wrong root**. The catalog signing pipeline, the append-only release ledger, the model-hash consistency checks, the route snapshots, and the settlement receipts are all real and mostly well built — but every performance claim and almost every identity claim they protect originates as **provider self-report**. Signing, verifying, and receipting a self-reported number does not make it true; it makes it *tamper-evidently* self-reported.

Concretely:

1. **Catalog `bench_gate` numbers are not evidence.** Of the 9 live rows, 5 have no throughput benchmark behind their gate at all, and the 4 "measured" rows were measured on a single M5 32 GB machine — some while the #745 bug meant the benchmark loaded a *different model* than the one it was recorded under (§4.1). Both client and coordinator correctly treat these gates as advisory-only. [E-code, E-issue]
2. **The hardware verifier proves identity anchoring, not benchmark truth.** SPEC-033 §10.2 says so itself: the guarantee is "string-level self-consistency + an operator trust anchor, not proof the benchmarks ran on that hardware," and "cross-provider borrow is blocked, self-fabrication is not." The `hardware_identity_hash` the operator anchors to is an HMAC over a locally generated random file plus two sysctl strings — it is not device-rooted, and it is **rotatable by deleting one file** (§4.4, §4.11). [E-spec, E-code]
3. **Nothing in production ties serving to verification.** The SPEC-032 hello gate is off in the live Pearl overlay (verified 2026-07-22), the canary is off, telemetry drift is off, the losslessness probe is off, and SPEC-036 has zero lines of code. The only enforcing integrity mechanism is Tier-2 Pillar A hash verification — a consistency check on a value the provider computes about itself (§4.6). [E-code, E-spec]
4. **Even with the hello gate on, the capacity ceiling has no routing consumer.** SPEC-032 FR-HG7 is a spec-acknowledged CRITICAL gap: a provider admitted on a small model can heartbeat-switch to a larger or uncatalogued model and the pool applies it unconditionally (§4.5). [E-code, E-spec]
5. **The single most valuable unexploited asset is coordinator-observed performance.** The coordinator already measures true per-request TTFT (`providerFirstByte`) and decode wall-time on every buyer request — and throws them away, because `request_log` has no columns for them (§4.7). This is the only performance signal in the system the provider does not author. Its power is real but **bounded** (§3.3): it cannot distinguish honest work from cheaper substituted work.

**Why the #744 provenance/signing work is not enough by itself** (required finding): PR #772 was the right *labeling* move — `bench_gate.provenance`, drift surfacing, a buyer TTFT ceiling, a v5 bridge key — but it changes what we *say* about the numbers, not where the numbers *come from*. Three specifics: (a) the provenance values in production are a **hardcoded client-side backfill table**, not signed catalog bytes — the Ed25519 signature covers zero bytes of provenance, and the coordinator accepts nil and substitutes nothing; (b) provenance "does not by itself admit or reject cached benchmarks" (SPEC-023 §3.1) — it is metadata about an advisory field; (c) the enforcement pipeline (`ResolveMaxAdmission`, hash checks, settlement) never reads provenance at all. Signing the catalog harder, or labeling its rows better, cannot fix a system whose admission evidence is fabricatable by construction (§4.2, §4.3). The fix is to *change the evidence class* that admission and routing consume — from provider-claimed to coordinator-observed — which is what the roadmap in §10 sequences.

**The upgrade question** (required finding): the correct design is **not** "lock the provider to the first model selected at hello." An admitted-capacity ceiling frozen at first-hello would block every legitimate upgrade and push providers toward reconnect-churn workarounds. §6 defines the alternative. Its load-bearing correction after review: **observed latency and throughput can only *demote*, and can only gate capacity *within an already-proven model class*.** They cannot authorize a cross-class ceiling raise, because model substitution scores *better* on every latency metric than honest service of the larger model (§3.3, §6.4). Cross-class raises therefore need a model-discriminating signal, not a speed signal.

**What this roadmap deliberately does not do** (added in r2): it does not gate supply growth on adversarial defenses the current cohort has never needed. Every incident in the log has been honest-system error, not attack (§9.1). The scarce resource is providers, not trust. The re-sequenced roadmap (§10) puts supply-neutral work first, states blocking thresholds as **provider counts** rather than an unschedulable "when referral gating loosens," and marks two items as blocking *continued operation* rather than opening.

---

## 2. Current System Map

### 2.1 Components and their real function

| Component | Where | What it actually does | Prod status |
|---|---|---|---|
| Catalog signing | `scripts/resign-autotune-static.sh`, `scripts/catalog-release.py`, `AutotuneRecommend.swift:1342-1488`, `internal/buyer/autotune_feeds.go:144-205` | Ed25519 over exact feed bytes; keyring v4 `active` / v5 `bridge`; append-only ledger + tombstones; freshness + policy-version + pairing checks | Live; feed is v4-signed `published-2026-07-10-catalog-recovery-v1` |
| Catalog rows | `phase3-binary/dist/static/autotune-candidates.json` (+ canonical + baked copies, byte-parity enforced `catalog-release.py:1594-1602`) | 9 rows: `model_id`, `model_revision`, `model_sha256`, `min_ram_gb`, `min_bandwidth_tier`, `bench_gate{min_sustained_tps,max_4k_ttft_ms}`, `notes` | Live; **no row carries `bench_gate.provenance`** |
| Autotune recommend (SPEC-023 v0.8) | `AutotuneRecommend.swift`, `AutotuneCommand.swift` | Local single-replicate 4k-context probe per candidate (`Stage1Iterator.swift:428-624`); ranks by `payout × measured_tps × demand × shortage` (`:1690-1696`); hard vetoes: thermal, swap, buyer TTFT ceiling, cached-benchmark admission (`:1833-1836`); bench_gate advisory-only (`:1874-1886`) | Live client-side |
| Hardware evidence submission | `AutotuneHardwareEvidence.swift`, `internal/onboarding/hardware_evidence.go` | JCS-canonical evidence blob POSTed with **bearer token only — no signature over the evidence** (`:243-252`); strict shape validation; dedupe by `evidence_sha256` | Live, default-on (`AutotuneCommand.swift:80-81`) |
| Hardware verifier (SPEC-033) | `internal/stats/hardwareverify/verify.go`, `cmd/stats-hardware-verifier/`, migrations 007/008/015/016/017/019 | Shape/consistency checks + 4-tuple operator trust match + chip profile existence; `waiting_trust` = all gates passed except the operator rows; dual-control approval API (migration 019) | Live worker on Pearl |
| Hello admission | `internal/ws/server.go:2116-2464` | Catalog-bound 5-field envelope; model-hash vs signed catalog row (`:891-916`); SPEC-032 gate `checkAutotuneHelloGate:2332-2394` → `ResolveMaxAdmission` (`internal/autotune/gate.go:18-58`) computes a `MaxAdmittedModelKey` RAM-tier ceiling from the provider's **own** benchmarks | Envelope + hash live; **gate `require_autotune_hello_gate: false`** [E-spec `ops/exceptions/production-exceptions.json:20`] |
| Heartbeat | `internal/ws/server.go:4261-4362`, `internal/pool/provider.go:1811-1923` | Re-sends all capability fields; pool overwrites `ModelID`, `RAMGB`, context, concurrency, TPS estimate **unconditionally** (`:1851`); no ceiling re-check | Live |
| Routing | `internal/pool/provider.go:409-443`, `internal/routing/filter.go:134-188`, `internal/routing/candidate.go:66-92`, `internal/buyer/server.go:5637-5647, 6385-6450` | Eligibility = auth state + catalog-admission mode + no pending receipt key + ready + free slots; match = case-insensitive `ModelID` equality + self-reported context sufficiency + Tier-2 hash predicate; "fast" objective ranks on `EffectiveThroughput = ThroughputTPSEstimate × tier_weight` | Live; `require_hash_verified: true` since 2026-07-23 |
| Tier weighting (existing) | `internal/routing/candidate.go:71-92`, `pool.TierProvisional` | `Weights{Pinned:1.0, Provisional:0.3}`, operator-tunable via `admission.provisional_tier_weight`; SPEC-002 v1.1 §5 Step 2.5 | Live — **this is the share-cap primitive §6 reuses** |
| Canary (SPEC-031) | `internal/ws/server.go:3525-3681`, `canary_probe.go`, `internal/canarycorr/` | Nonce-echo liveness + TTFT/TPS gates + sanction machine; FR-CAN22 sole-provider floor (`pool/provider.go:1254-1277`, `CanaryTripFloorHeld`) | **Disabled in prod** (`pool.canary_enabled: false`) |
| Tier-2 Pillar A (SPEC-008) | `internal/tier2/catalog.go:331-372, 751-757` | Provider-reported boot-time hash vs signed catalog; `mismatch`/`invalid` always route-excluded | **Enforcing in prod** (the only one) |
| SPEC-022 settlement | `internal/billing/settlement_receipts.go`, `route_snapshot.go`, `payout.go` | Receipt binds request↔snapshot↔model_hash↔usage; `model_hash: null` → no debit/credit | Shipped; mode default `observe` |
| OPoI / telemetry drift | `internal/pow/drift.go` | WARN-only; TPS drift compares provider heartbeat self-report against provider benchmark self-report | **Dormant** |
| Losslessness (SPEC-030) | `internal/ws/losslessness.go` | TV-distance between plain/speculative arms of the same provider; cooperative-health only | Shipped, disabled, verdict fn test-only callers |
| Compute-integrity (SPEC-036) | spec only | Would compare served next-token distributions against a coordinator-held trusted reference | **Zero code** |
| Attestation (Pillar C) | `internal/tier2/pillar_c*.go`, `internal/ws/server.go:1778` | SE P-256 = key custody + session binding; `AttestationTierHardware` **never emitted** | Live but non-load-bearing |

### 2.2 Production posture snapshot

| Control | Live value | Evidence |
|---|---|---|
| `tier2.require_hash_verified` | **true** (since 2026-07-23) | `dist/coordinator.yaml:288`; exception removed [E-spec] |
| `proof_of_weights.require_autotune_hello_gate` | **false** | `ops/exceptions/production-exceptions.json:20` (verified 2026-07-22); SPEC-032:553 *incorrectly* says true [E-spec] |
| `pool.canary_enabled` | **false** | `exc-canary-disabled-enable-gate` active [E-spec] |
| `proof_of_weights.telemetry_drift.enabled` | false (default) | `internal/config/config.go` (`TelemetryDrift.Enabled`, no committed overlay) [E-code] |
| `pool.losslessness_probe.enabled` | false (default) | `config.go:994` [E-code] |
| `tier2.require_attestation` | false (default) | `config.go:1078` [E-code] |
| `settlement.verified_model_settlement_mode` | `observe` (default; overlay unknown) | `config.go:1120` [E-code, I] |
| `referrals.require_for_registration` | **false** | `dist/coordinator.yaml:108-112` — referral gating is **not** today's admission control (§9.3) [E-code] |

### 2.3 The Pearl-DB facts from the triggering session, reconciled

- *"Providers serve traffic daily while hardware verification jobs sit in `waiting_trust`."* Consistent with code: with the hello gate off, hardware verification status has **zero** influence on admission or routing. Serving and verification are fully decoupled paths today. [E-code; DB observation itself E-session]
- *"`waiting_trust` means the exact provider/hardware trust tuple is missing, not that the provider never served."* Confirmed: `waiting_trust` is set only when every other gate passed and the reject reason is `missing_trusted_hardware_identity` or `missing_trusted_chip_profile` (`verify.go:240-246`); it self-promotes without resubmission once operator rows appear. Live corroboration: Entry 198 — Air5's job sat in `waiting_trust` purely because Pearl lacked an `apple m3` chip profile. [E-code, E-spec]

---

## 3. Evidence And Trust Boundaries

### 3.1 Evidence classes

Names match strings that already exist in the repo where possible (`"provider_reported"` — `internal/buyer/server.go:1096`; `UsageSourceCoordinatorObserved` — `internal/billing/settlement_output.go:22`; `measured_single_host` — shipped provenance enum).

| Class | Definition | Forgeable by one malicious provider? | Anchors |
|---|---|---|---|
| `provider_self_reported` | Any value computed and transmitted by provider code: benchmarks, model hash, weights manifest, RAM, context, concurrency, TPS estimate, model-load-time, hardware summary | **Yes, trivially** | `messages.go:19-47, 298-320`; `hardware_evidence.go` |
| `operator_approved_identity` | Operator vouches that a provider identity maps to a hardware class (SPEC-033 trust tuple + chip profile, dual-control) | No (needs operator) — but see §3.4: the *anchored value* is provider-controlled and rotatable | migration 019; `admin_hardware_trust.go` |
| `operator_single_host_benchmark` | A measurement the operator personally ran on operator hardware (provenance `measured_single_host`) | No — but generalizes poorly and was staled by #745 | `AutotuneRecommend.swift:799-840` |
| `trusted_provider_matrix` | Convergent measurements from ≥N verified providers on ≥M hardware classes — **does not exist yet, and is unreachable at current fleet size** (§7 rule 4) | Only by collusion | #687 Stage 4 [E-issue] |
| `coordinator_observed` | Measured by coordinator/gateway on the buyer path: per-request TTFT, decode wall-time, token counts, error/fault rates, breaker trips; canary results when enabled | **Bounded — see §3.3** | `phase_timing.go:20-29, 204-224`; `settlement_output.go:22,49-50`; `pool/provider.go:1580-1621` |
| `community_unattested` | oMLX board data — self-reported by strangers; advisory prior only | Yes | RESEARCH_231; #687 invariant [E-issue] |

### 3.2 Trust domains, mapped to the class that actually backs them today

| Trust domain | What backs it today | Class | Gap |
|---|---|---|---|
| Catalog artifact identity | Ed25519-signed feed + append-only ledger | operator-authored, cryptographically bound | Sound — the strongest domain |
| Catalog `bench_gate` numbers | 4× single-host (pre-#745-fix, non-reproducing), 5× no measurement | `operator_single_host_benchmark` at best | Advisory-only is correct; the gap is anything re-deriving authority from them |
| Provider identity/auth | Bearer token + (v2) proof handshake; PoO is a 41-line skeleton + 501 stub | operator-issued credential | Adequate for prebeta |
| Hardware identity | HMAC(local random file, providerID\|ramGB\|chip) (`AutotuneRecommend.swift:183-266`) | `provider_self_reported`, then operator-anchored | **Not device-rooted; rotatable** (§3.4, §4.11) |
| Model artifact → served tokens | Preflight dir hash (self-enforced) → config value adopted as reported hash (`ModelRuntime.swift:610` — **not re-derived from loaded tensors**) → consistency at hello/heartbeat/receipt | `provider_self_reported`, consistency-chained | Complete vs misconfiguration; empty vs an adversary |
| Benchmark claims | Evidence blob, bearer-auth, shape-checked | `provider_self_reported` | SPEC-033 §10.2 self-fabrication gap; feeds `ResolveMaxAdmission` |
| Buyer-path performance | Phase timings measured, **not persisted**; token counts persisted | `coordinator_observed` (bounded) | Foundation exists and is discarded (§4.7) |
| Routing "fast" objective | `EffectiveThroughput = ThroughputTPSEstimate × tier_weight` (`candidate.go:80-92`) | `provider_self_reported` | **An inflated self-report directly buys traffic** (§4.12) |
| Operator approval | Dual-control trust tuple grants; catalog publish authority | `operator_approved_identity` | Fine at cohort scale; becomes an oracle if it starts approving *performance* (§4.8) |
| Buyer-facing confidence | `tier1_disclosure` (excellent) vs README:22 / stats overview (overstating) | mixed | §4.9, §8 |

### 3.3 What `coordinator_observed` can and cannot prove (load-bearing; corrected in r2)

An earlier draft asserted this class is unforgeable. That is **false as stated**, and the correction propagates through §5 and §6.

**Cannot be inflated:** wall-clock latency for work actually performed. A provider cannot make the coordinator's stopwatch read faster than reality for a given unit of work. Error rates, breaker trips, and timeouts are likewise coordinator-side facts.

**Can be inflated by substituting cheaper work.** Decode rate is `providerFirstByte → providerDone` over provider-emitted chunks (`phase_timing.go:213`) and token counts come from the provider's own stream (`settlement_output.go:46-52`). A provider that serves `qwen3-8b` while advertising `qwen3-32b`'s `model_id` and hash string **scores strictly better** on every latency metric than one honestly serving the larger model. The hash predicate does not stop this: `internal/ws/server.go:906-910` is a case-insensitive string compare of a **provider-reported** hash against the catalog value.

**Therefore** (the design consequence): observed latency/throughput is a valid signal for *demotion* and for capacity decisions *within an already-proven model class*. It is **not** valid authority for a cross-model-class ceiling raise. Raising a ceiling across classes requires a model-discriminating signal — the canary model-class challenge bank, or SPEC-036 compute-integrity divergence — neither of which is live today (§6.4, §10 R5/R12).

### 3.4 What `operator_approved_identity` actually anchors (corrected in r2)

The trust tuple binds `(provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb)`. Two limits:

1. **The anchor is rotatable.** `hardware_identity_hash` derives from `~/.config/macprovider/autotune-hmac-secret`, a locally generated random file (`AutotuneRecommend.swift:213-266`). Deleting it mints a fresh identity → a fresh tuple → any per-tuple sanction state (probation history, demotion) is cleared. **Any sanction keyed to this tuple is a sanction the provider can wash off with `rm`.** (§4.11, §10 R7.)
2. **The memory value is provider-submitted.** Migration 019 derives the tuple server-side "from the job row rather than trusting a client-supplied" value (`019_...up.sql:17`) — but the job row's `unified_memory_gb` came from the provider's own evidence (`hardware_evidence.go:69`, a sysctl string). The tuple's strength therefore equals **whatever the operator physically verified at first approval**, no more. That is fine while the operator installs each Mac personally; it is the precise thing that fails when the cohort opens to strangers.

---

## 4. What Is Broken Or Weak Today

### 4.1 F1 — Catalog gate numbers are unfounded, and the mechanism that produced them was broken until 2026-07-25

The #744 provenance audit [E-issue] — corroborated by the shipped backfill table `AutotuneRecommend.swift:799-840` [E-code] — records 4/9 rows measured, all on one M5 32 GB; the 3 rows needing >32 GB unmeasurable by construction on the only executor; the 2 re-measured rows diverging 1.7–1.8× in *opposite directions*. #745 explains the divergence: until PR #751, `serve --model` overrode model identity but not `model_artifact_path`, so **every candidate benchmark loaded the incumbent and recorded it under the candidate's name** — silently, since preflight validated the incumbent's path against the incumbent's hash. The fix is verified end-to-end [E-code: `Config.swift:489-526` clears the artifact binding on identity change; chain `AutotuneRecommend.swift:3040-3063` → `CandidateProviderRunner.swift:289-295` → `MacProviderCLI.swift:1024-1026` → `ModelRuntime.swift:601`]. Consequence: **no gate value predating #751 is trustworthy, and no trusted post-#745 matrix exists** — which Entry 196 correctly used to reject wholesale re-derivation.

Soft spot: the local probe now feeding first-order ranking and the buyer-TTFT hard veto is **single-replicate** by default (`AutotuneCommand.swift:37`) — "p95 TTFT" is one sample. [E-code]

### 4.2 F2 — Signing is conflated with truth in naming and prose

The signature proves exact bytes came from a keyring holder. The repo's own strongest statements agree (`keys/README.md:59-66`; SPEC-032:653-655 dropped the false "signed autotune benchmark" claim; Entry 134). But surfaces invite the stronger reading: `catalog_trust_blocked` (`AutotuneCommand.swift:1206`), `paidTrustBlockingWarnings` (`AutotuneRecommend.swift:1604`), `"status": "live_verified"` (`autotune_feeds.go:840`), SPEC-023:127 "a trustworthy catalog". SPEC-023 has no "what the catalog signature does not prove" section, unlike SPEC-015's negative list (`SPEC-015-receipts.md:2473-2495`). Meanwhile the actual money input — `/v1/rate-card` — is fetched **unsigned** with an unlabeled baked fallback (`AutotuneRecommend.swift:1330-1340`, sets `rateCardFallbackUsed` but surfaces it only as a raw stderr enum), while advisory TPS numbers get full Ed25519 protection. [E-code, E-spec]

### 4.3 F3 — The shipped provenance is unsigned client-side state, and two provenance vocabularies coexist

- Every live row omits `bench_gate.provenance`; values come from the hardcoded backfill keyed to the release SHA (`AutotuneRecommend.swift:757-840`). The signature covers zero provenance bytes. [E-code]
- The coordinator accepts nil for the pinned release and substitutes nothing (`autotune_feeds.go:500-507`) — coordinator-side consumers see no provenance. [E-code]
- `validate_candidate` is called **without** `require_provenance` at `catalog-release.py:1324, 1589, 1649, 1697, 1721` — only `generate` enforces it, so deploy/package gates accept a provenance-free release matching the legacy pin. [E-code]
- The #687 addendum draft defines a *different* enum (`verified_local | omlx_seeded | hand_set` + `gate_seed`) with zero overlap with the six shipped values; its §1 invariant is violated in spirit today (all 9 rows `recommendable`, 5 non-measured). [E-spec, E-issue]

### 4.4 F4 — The hardware verifier's anchor is a value the provider fully controls

SPEC-033 §10.2 discloses self-fabrication honestly but frames `hardware_identity_hash` as a stable device anchor. Mechanically it is `HMAC-SHA256(key = 32 random bytes from ~/.config/macprovider/autotune-hmac-secret, msg = provider|ramGB|chip)` (`AutotuneRecommend.swift:183-266`). Evidence submission is bearer-authenticated JSON with **no signature over the evidence** (`hardware_evidence.go:243-252`). The guarantee is: *this provider account consistently tells the same story, and an operator vouched for the (chip, memory) class of that story.* [E-code, E-spec]

Where verified evidence becomes authority: `ResolveMaxAdmission` (`gate.go:18-58`) derives the ceiling from the provider's **own** benchmarks — a fabricated row buys a higher tier. `benchmarkPassesGate` checks thermal, identity binding, and artifact-hash *string* equality; it deliberately never checks TPS/TTFT (`gate.go:104-106`) and **never checks `swap_detected`** despite decoding it (`evidence.go:13`) — the #742 swap veto exists only client-side. [E-code]

### 4.5 F5 — Admission is a one-shot gate with a documented CRITICAL bypass, and it is off anyway

- Off: `require_autotune_hello_gate: false` live (verified 2026-07-22). SPEC-032:553 claims the opposite — stale and inverted. [E-spec]
- **FR-HG7**: `MaxAdmittedModelKey/ID` is computed at hello and consumed only by `providerProbeModelID` (`ws/server.go:3442-3447`), which has **two** callers — the warm-up gate (`:3423`, **live**) and the canary probe (`:3734`, disabled). So today the ceiling's only live consumer is warm-up probe targeting; it appears nowhere in `RoutingEligible()` or buyer matching. A heartbeat can replace `ModelID` with a larger or uncatalogued model and `applyHeartbeatLocked` applies it unconditionally (`pool/provider.go:1851`); a switch without a loading transition emits no `SwapEvent` (`:1899-1916`). SPEC-032 marks this Gap (CRITICAL-class); AC-F1/AC-F2 documented as expected-to-fail. [E-code, E-spec]
- **FR-HG6**: no mid-session *evidence-TTL* re-check. (Trust-root revocation/expiry **is** re-checked — `trust_revalidation.go:12-23, 121, 149-159` sweeps every 30 s; only evidence freshness is uncovered.) [E-code]
- Hello carries no chip descriptor, so a credential moved to weaker hardware reuses prior evidence until TTL (SPEC-032:137-144). [E-spec]

### 4.6 F6 — Every capability input to routing is self-reported and unverified

`RAMGB`, `MaxContextTokens`, `MaxConcurrency`, `ThroughputTPSEstimate`, `ModelParamsB`, `ModelLoadTimeMs` are trusted as-is on hello and re-trusted every heartbeat [E-code]. Aggravations: (a) self-reported `RAMGB` is never compared to the verified `unified_memory_gb` in the same database; (b) `ModelLoadTimeMs` is the baseline for the Pillar D TTFT-anomaly check (`pillar_d.go:167-197`) — the provider sets its own anomaly threshold (though that path is **observe/WARN-only and config-gated**, `:193`). [E-code]

### 4.7 F7 — The "observability" mechanisms observe self-report, and the real observations are discarded

- `pow/drift.go` TPS drift compares the provider's heartbeat claim against the provider's earlier benchmark claim — self-report vs self-report, WARN-only, dormant. [E-code]
- OPoI is byte-identical to the liveness nonce echo ("aspirational names for a mechanism that does not yet prove what they imply," SPEC-032:38), zero routing readers, cannot fire while the canary is disabled. [E-spec]
- The coordinator measures true TTFT and decode wall-time on every buyer request across all 8 relay paths (`markProviderFirstByte` at `internal/buyer/server.go:2439, 2530, 2880, 3086, 3369, 3540, 3646, 3901`) and emits them as **response headers only**. `request_log` persists `latency_ms`/`routing_ms`/`queue_wait_ms` and token counts but has **no TTFT or decode column** (`internal/requestlog/store.go:43-100, 464-489`). No aggregate table carries latency or throughput per provider (`001_stats_tables.up.sql:39-62`). [E-code]

### 4.8 F8 — Operator approval is drifting toward a performance oracle

The dual-control flow (migration 019) is well built *for identity*. But verified evidence feeds `ResolveMaxAdmission` and (per #687 Stage 4) future gate re-derivation, so operator identity approval transitively **launders self-reported benchmarks into admission authority**. Design pressure is toward approving more tuples faster (Entry 198's chip-profile scramble is the live example). Boundary: operators approve *identity mappings*; performance authority comes only from `coordinator_observed`. [I, grounded in E-code above]

### 4.9 F9 — UX and docs overstate in specific, fixable places

The repo contains the correct pattern three times (`catalog_evidence_source: "provider_reported"`; gateway `tier1_disclosure`; leaderboard `rewards_populated`). Violations are localized:

| Surface | Problem | Ref |
|---|---|---|
| `README.md:22` | "the **verified model hash** … **Verifiable inference**" — unqualified; hash is self-measured. Violates SPEC-006:343 | [E-spec] |
| `docs/using-macprovider-with-openai-sdk.md:202` | "what makes MacProvider verifiable inference" — same gap; contrast `phase7-verify/README.md:129` | [E-spec] |
| `autotune --recommend` transcript | Prints "Benchmarked N" where N = *eligible* count (`AutotuneRecommend.swift:2057`); surfaces **zero** confidence/provenance/drift — #772's additions are JSON-only; warnings hit stderr as bare enum rawValues | [E-code] |
| `AutotuneCommand.swift:958` | Donor message asserts the `$0.0050/hr` gate SPEC-023 v0.4 deleted | [E-code, E-spec] |
| `/v1/stats/overview` | `bandwidth_gb_per_s`, `network_power_kw`, `gpu_cores_total` are chip-name lookup constants (`ProviderHardwareSummary.swift:48-105`) published unlabeled; **no provenance field on the wire** | [E-code] |
| `nodes_hardware_attested` | Structurally always 0 — only `AttestationTier` writer sets `self_signed` (`ws/server.go:1778`); `0` is ambiguous. Entry 109 prose now stale | [E-code] |
| `/v1/models` `hash_verified` | Scalar with no in-band caveat (field is `interface{}`, `buyer/server.go:1574`) | [E-code] |
| CLI `status` "Pending hardware verification" | Overstates per SPEC-033 §10.2; "awaiting operator approval" in the same string is right | [E-code] |
| Console arm64golf panel | Headline "best verified 12" vs "AlphaDev 17" outruns its caveat; data is a hardcoded 2026-06-05 literal with a `last_update` reading as live | [E-code] |

### 4.10 F10 — Spec/doc drift that will mislead the next implementer

SPEC-032 posture inverted (`:553`). SPEC-033 roster omits migration 019 and `promoteJob`'s re-park/advisory-lock behavior; §3 schema omits `model_artifact_path`; §10.4 R1 partially superseded by `evidence_pg.go:80-89`. SPEC-008:97-102 still describes the pre-#759 attestation overstatement as unfixed. SPEC-013 NFR-4 ("nothing leaves the machine", `:1273-1292`) is contradicted by **at least three** egress paths: default-on evidence POST, `/v1/rate-card` (`AutotuneRecommend.swift:1334`), and signed static feed fetches. SPEC-023 §3.4/§3.5 URLs stale. `ops/runbooks/spec-drift-remediation.md:132` contradicts the 2026-07-22 overlay read. [E-spec, E-code]

### 4.11 F11 — Per-tuple sanctions are erasable (new in r2)

Any state keyed to `(provider_id, hardware_identity_hash, …)` — probation history, demotion, canary sanctions persisted across reconnect (`pool/provider.go:860`) — is cleared by rotating the HMAC secret file (§3.4). A provider that fails observed floors can `rm ~/.config/macprovider/autotune-hmac-secret`, re-run autotune, and re-enter as a fresh tuple. The one brake is that a *new* tuple needs operator approval — which is exactly the brake that must scale down when the cohort opens. This bounds the durability of every sanction the roadmap proposes. [E-code, I]

### 4.12 F12 — Routing's "fast" objective ranks on self-reported throughput (new in r2)

`EffectiveThroughput(p, w) = p.ThroughputTPSEstimate × tier_weight` (`internal/routing/candidate.go:80-92`) drives SPEC-004 FR-SR-8 "fast" selection. `ThroughputTPSEstimate` is provider self-reported and re-trusted on every heartbeat (F6). **This is the one place where an inflated self-report directly buys traffic and therefore revenue** — a more direct incentive corruption than anything in the catalog, and it is not addressed by any provenance or signing work. [E-code]

---

## 5. Correct Target Model

### 5.1 The one-sentence version

**Trust artifacts and identity; treat every provider-supplied number as a claim; let the coordinator's own buyer-path measurements govern privileges — as a demotion authority always, and as a promotion authority only within a proven model class.**

### 5.2 Trusted / Claimed / Observed assignment

| Layer | Contents | Authority granted |
|---|---|---|
| **Trusted** (cryptographic or operator-anchored) | Signed catalog bytes; release ledger/tombstones; operator trust tuples (identity only, with §3.4's limits); provider credentials | Defines the *universe* of servable models and who may connect. Never asserts performance. |
| **Claimed** (provider self-report; consistency-checked) | Benchmarks, model hash, weights manifest, RAM/context/concurrency/TPS estimate, hardware summary, `bench_gate` values | May *lower* the provider's own privileges immediately (self-declared degrade honored). May grant **only capped, revocable, probationary serving** (§6). May never grant unrestricted paid serving, set enforced thresholds, or rank the routing objective. |
| **Observed** (coordinator/gateway measured) | Per-request TTFT, decode time, tokens, error/fault/breaker events; canary results when enabled | **Demotion**: always authoritative. **Promotion**: authoritative for capacity within an already-proven model class; **not** sufficient for a cross-class ceiling raise (§3.3). Also the correct input to the routing objective (replacing F12's self-report). |

### 5.3 What the coordinator should enforce continuously

1. **Catalog membership + artifact hash predicate** on the *currently served* model — already live. Keep.
2. **Capacity ceiling on every routing decision and every heartbeat model change** (closes FR-HG7): serving model's `min_ram_gb` ≤ admitted ceiling, else routing-ineligible **for that model**. Implementation note: compare in-memory against a persisted `MaxAdmittedMinRAMGB`; do **not** read Postgres under the pool mutex (§10 R3).
3. **Evidence-TTL freshness** on the existing 30 s sweep (closes FR-HG6) — trust-root lapse is already covered there.
4. **Observed-performance floors**, bucketed by workload shape (§5.4), as a demotion authority.
5. **Self-consistency tripwires** as WARN→sanction escalators: self-reported `RAMGB` vs verified `unified_memory_gb`; heartbeat TPS claim vs *observed* TPS.
6. **Sole-provider floor on every one of the above.** No enforcement action may remove the last buyer-serving provider for a model; it degrades to alert + telemetry instead. The repo already implements exactly this shape for canary sanctions — `CanaryTripFloorHeld` (`pool/provider.go:1254-1277`, FR-CAN22) — and every new enforcement path must reuse it. This is normative, not an open question.

### 5.4 Workload normalization (new in r2)

TTFT and decode rate vary by prompt length, context size, and concurrency. Unstratified p95 floors reward a provider that fails or is skipped on long-context work and punish one that accepts it. Floors must therefore be evaluated **within matched buckets** (prompt-token range × concurrency), never against a raw global p95, and never against a catalog `max_4k_ttft_ms` derived from a fixed 4k single-replicate probe.

SPEC-029 (`specs/SPEC-029-sweep-workload-class-stratification.md`, implemented PR #387) already defines the workload-class vocabulary — short chat, medium chat, long context, code, agent — and is the natural source of bucket definitions. Caveat: SPEC-029 is explicitly a *sweep-output* partition and "does not introduce runtime request classification," and `workload_profiles` is intentionally absent from the live catalog. Runtime bucketing is therefore **new work** that borrows SPEC-029's vocabulary, not a drop-in. [E-spec]

### 5.5 What stays advisory

`bench_gate` TPS/TTFT (until re-derived per §7 and explicitly promoted per-row), autotune recommendation and ranking, oMLX-seeded priors, drift warnings, OPoI pass-rate, provenance labels. The client-side buyer-TTFT ceiling stays an operator policy knob per Entry 196.

### 5.6 What must exist before any catalog numeric gate changes again

A post-#745 measurement, in-band signed provenance, and — for any gate *gaining enforcement power* — corroboration from `coordinator_observed` data or a `trusted_provider_matrix` quorum (§7).

---

## 6. Provider Model Upgrade Flow

### 6.1 The requirement (and the anti-requirement)

Two real scenarios, both of which must work:

- **Same Mac, larger catalog row.** A 64 GB Mac first benchmarked on `qwen3-8b` wants to serve `qwen3-32b`. No hardware event; the existing trust tuple still applies. **This must need no operator involvement.**
- **A catalog row published after the provider's last verification.** Same tuple, new row.

A third case is often stated loosely and is worth correcting: a provider does **not** "buy more RAM." Apple Silicon unified memory is on-package. Adding memory means a *different Mac*, which produces a new `(chip, memory)` tuple, clears `verified` via the migration-016 guard, and correctly re-enters operator identity approval. New hardware always re-enters approval; that is intended, not a gap.

Freezing providers to the first hello model is rejected: it punishes honest upgrades, invites identity churn, and confuses "what you first claimed" with "what you can do."

### 6.2 Capacity and performance are two different questions

The r1 draft conflated them. Separating them shrinks the design considerably:

- **"May this Mac physically host this row?"** — answered by `min_ram_gb` vs the operator-verified `unified_memory_gb` of the tuple (§6.3 Step 2). This is a static fact, needs no traffic, and closes the pure-fabrication ceiling raise **to the strength of the operator's first-approval physical verification** (§3.4 limit 2).
- **"Does this Mac serve this row acceptably?"** — answered by continuous observed floors (§5.3.4), which apply to *every* provider on *every* model, probationary or not.

Probation therefore buys exactly one thing: **bounded exposure in the window between a capacity claim and the first observed data point.** That window is real (a provider can pass Step 2 and still be terrible at the larger model), but it is small, and the apparatus must stay proportionate to it. If the exposure budget in §6.3 Step 3 cannot be justified against that window, probation should collapse into §5.3.4 and this section reduces to Steps 0–2.

### 6.3 The flow

**Step 0 — baseline.** Ceiling = `ResolveMaxAdmission(verified evidence)`. Re-running autotune on the **same hardware tuple** auto-promotes through the verifier with no new operator action (the trust row exists); only a hardware change needs re-approval. Preserve this asymmetry.

**Step 0b — cold start (first model).** A provider's **first** model uses the identical entry rules as an upgrade. There is no exemption: exempting first-hello would give an unknown stranger full share on day one while taxing a known provider for upgrading on the same Mac — inverting the threat model. To keep onboarding viable, first-model probation carries a **bootstrap allowance**: promotion on either the observed-sample threshold *or* elapsed-time-with-no-adverse-signal, whichever comes first (§6.3 Step 4).

**Step 1 — claim.** Provider runs `autotune --recommend` including the target model; submits fresh evidence. Grants nothing by itself.

**Step 2 — mechanical pre-checks (automatic).** Fresh evidence passes the SPEC-033 pipeline against the existing tuple; claimed row's `min_ram_gb` ≤ verified `unified_memory_gb` (strength per §3.4); swap/thermal flags in the evidence disqualify (bringing #742's rule coordinator-side).

**Step 3 — probationary serving.** Implemented as an extension of the **existing** `pool.TierProvisional` weighting (`routing/candidate.go:71-92`, operator-tunable `admission.provisional_tier_weight`) applied per-(provider, model) — not a parallel share-cap mechanism. Constraints:

- **Absolute exposure budget, not just relative share.** Relative downweighting provides zero dilution when the provider is the only holder of that model — the documented live condition. The budget must therefore be absolute and stated numerically: max concurrent slots, max requests before the first floor evaluation, and max cumulative billed value in the window. (Values are an open question, §11 Q1; the *requirement* that they be absolute and numeric is not.)
- **Probation traffic is discounted or unbilled.** The premise is that buyer traffic is the probe; charging full rate makes the buyer pay to be the test instrument, on a network where they have no alternative provider. Resolved here rather than left open.
- **No buyer opt-out claim.** Tier-2 knobs are coordinator-global config, not per-request options; the only per-request surface is a 503. Any buyer-facing opt-out is new work with a mandatory sole-provider fallback.

**Step 4 — promotion, scoped by class.** Two distinct cases:

- **Within an already-proven model class** (same class, more capacity): observed floors are sufficient authority. Promote after N observed requests within matched workload buckets (§5.4), **from ≥2 distinct payer accounts**, over ≥T elapsed time, with no breaker trips. The distinct-payer and elapsed-time requirements exist because a provider that is the sole route target for its model can otherwise register as a buyer and manufacture its own promotion traffic; the repo's canary Sybil work (`internal/canarycorr/`, FR-CAN23) is the prior art to reuse.
- **Across model classes** (the `qwen3-8b` → `qwen3-32b` case): observed latency is **not** sufficient (§3.3) — substitution scores better than honesty. Until a model-discriminating signal exists (canary model-class challenge bank re-enabled, or SPEC-036 observe-mode divergence), a cross-class raise is authorized by Step 2 capacity + operator confirmation, and is explicitly a **weaker** guarantee that must be labeled as such. Closing this properly is R12's job; the roadmap must not claim otherwise.
- **Maximum probation window.** A provider must never sit indefinitely. On reaching the window without adverse signal, promote on the bootstrap path (Step 0b) or tell the provider explicitly that the model is unpromotable at current demand. Provider-visible progress and expected criteria are required (§8).
- **Floors are per-(model, RAM-tier) and bucketed**, never a single network-absolute TTFT number — an absolute ceiling systematically penalizes large models, i.e. exactly the supply the network lacks.

**Step 5 — demotion symmetry.** The same floors, evaluated continuously, demote any model — first-hello or upgraded — subject to the §5.3.6 sole-provider floor. Promotion is durable until demoted (not "permanent").

**Step 6 — sanction durability caveat.** Per §3.4/F11, demotion state keyed to the trust tuple is erasable by rotating the HMAC secret. Until R7 lands, probation/demotion is a speed bump against honest degradation and a *deterrent*, not a control, against a determined actor. The roadmap must say this rather than imply durability.

### 6.4 Why this answers the design question

"How can provider model upgrades be admitted without trusting provider self-report and without blocking legitimate upgrades?" — Self-report becomes a *trigger* (Steps 1–2 gate on consistency and operator-verified capacity, not on claimed speed). Legitimate same-class upgrades clear on observed traffic with zero operator involvement. Cross-class upgrades are honestly labeled as resting on capacity + operator confirmation until a model-discriminating signal exists, rather than being dressed up as observation-backed. Fabricators enter with a numerically bounded exposure budget and are demoted by observed floors — with the two caveats stated plainly (substitution beats latency checks; sanctions are erasable) instead of assumed away.

---

## 7. Catalog Gate Promotion Rules

Provenance ladder (reconciling the shipped enum with the #687 draft):

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

1. **Provenance lives in the signed bytes.** The next release carries `bench_gate.provenance` in-band; the client backfill and coordinator nil-acceptance retire with it. `require_provenance` is added to every `validate_candidate` call site (`catalog-release.py:1324, 1589, 1649, 1697, 1721`), not just `generate`.
2. **No gate value changes without a post-#745 measurement** of that row (Entry 196's constraint).
3. **Advisory by default, per row.** A gate gains enforcement power only at `trusted_provider_matrix`, and then under a **new field name** (SPEC-023:71-74's own guidance: `hard_min_sustained_tps`), so the advisory wire field never silently changes meaning.
4. **Promotion arithmetic** (#687 Stage 4): recompute from ≥N distinct verified providers' post-#745 measurements on ≥M hardware classes, cross-checked against observed serving data; drop the oMLX seed at promotion. N ≥ 3, M ≥ 2 as floors (§11 Q2). **Reachability caveat:** with a fleet of 1–2 this is unbuildable today, and the >32 GB rows that most need re-derivation are precisely the ones no current hardware can measure (#584). R8 therefore splits into a buildable half (in-band provenance) and a deferred half (promotion tooling).
5. **`recommendable` is orthogonal to measurement, but never to disclosure.** A row may be `recommendable` at any provenance class **provided its class is rendered at the point of choice** (§8). The r1 draft barred only `omlx_seeded` while grandfathering `never_benched`/`policy` — inverting its own ladder by treating the strictly-better-informed class more harshly. The uniform rule replaces it. Note this is a deliberate **narrowing** of #687's stated invariant ("unattested data MUST NEVER hold the gate of a `recommendable` row"), justified by gates being advisory; if gates ever become enforcing under rule 3, #687's stricter form applies.
6. **Unsigned inputs off the money path**: sign the rate card or fold it into the signed release unit (F2).

---

## 8. Buyer/Provider UX Requirements

**Framing (corrected in r2):** at 1–2 providers with one model each, a buyer has no provider to choose *between* — the honest purpose of this section is **overclaim remediation and expectation-setting**, not decision support. Decision-support surfaces become valuable at larger pool sizes and are marked scale-triggered below.

1. **Fix the two normative-rule violations first** — `README.md:22` and `docs/using-macprovider-with-openai-sdk.md:202` get the `phase7-verify/README.md:129` treatment. SPEC-006:343/3659 already mandates this; these are the only two items in §8 that are unacceptable *today*.
2. **Every performance or verification claim carries its evidence class**, using existing vocabulary (`provider_reported`, `operator_approved`, `coordinator_observed`, plus the provenance enum). Models to copy: `catalog_evidence_source` (`buyer/server.go:1096`), gateway `tier1_disclosure`, leaderboard `rewards_populated`.
3. **Transcript parity with JSON** in `autotune --recommend`: render `confidence`, provenance class, and drift in the human transcript; fix "Benchmarked N"; replace bare stderr enums with readable lines. `RecommendationEmitter.swift:169-177` is the house standard.
4. **Delete stale claims**: the `$0.0050/hr` donor string; the Entry-109-derived `nodes_hardware_attested` prose.
5. **Stats overview honesty** (scale-triggered for the `source` object; immediate for the label): mark the chip-table constants as estimates; report `hardware_attestation` consistently with the gateway's `"none"` rather than an ambiguous `0`.
6. **Provider-side verification visibility**: s/"Pending hardware verification"/"Pending operator identity approval (hardware class)"/. The CLI `status` output is the **required** surface for probation state and progress (§6.3 Step 4) since the portal defers all such fields behind SPEC-014 Open Q5.
7. **Probation visibility is asymmetric by design.** Provider-side: always visible, with criteria and progress. Buyer-side: **gated on a minimum provider count for that model** — at pool size 1, a `probation_provider_count` field is a public sanction disclosure about one identifiable machine, which contradicts the same anonymity-set constraint that keeps observed aggregates internal (§10 R1).

---

## 9. Prebeta Minimum Viable Trust Model

### 9.1 What is acceptable now (small, personally-known cohort)

Acceptable to rely on, with eyes open [I]:

- **Operator-approved identity** as the admission root — at cohort scale the operator installs each Mac personally, which is exactly what §3.4 says the tuple's strength depends on.
- **Signed catalog artifact pinning + Tier-2 Pillar A + `require_hash_verified`** — closes misconfiguration/drift, the *actual* observed failure mode. Every incident in the log (#742's swap selection, #745's mislabeled benchmarks, Entry 198's chip-profile gap) was honest-system error, not adversarial.
- **SPEC-022 observe mode**, **advisory gates + client-side vetoes**, and **manual operator response** in place of the disabled canary (per Entry 195's small-cohort posture).

### 9.2 Three blocking tiers (replaces r1's single "blocks opening" flag)

The r1 draft called two things "unacceptable even now" and simultaneously scheduled them as opening-blockers. Resolved by tiering:

- **Tier 0 — blocks continued operation** (do now, regardless of cohort growth): the two normative overclaim violations (§8.1), and heartbeat model-switch enforcement (F5), which silently invalidates the one integrity chain that *is* live.
- **Tier 1 — blocks growth past N providers**, where N is the point at which the operator stops personally installing each Mac. Proposed N = 5 [I, §11 Q3]: observed-data persistence, ceiling enforcement, the routing-objective swap, probation, and hello-gate-on with a non-blocking approval path.
- **Tier 2 — follows**: gate re-derivation, drift wiring, identity rooting, hash hardening, compute integrity.

### 9.3 The trigger is a provider count, not a referral flag

The r1 draft gated on "before referral gating loosens." That is not schedulable: `referrals.require_for_registration: false` in the checked-in config and SPEC-034 prohibits production activation outside a one-time §8 exception — referral gating is not today's admission control. The observable trigger is instead: **the first provider the operator has not personally installed.**

### 9.4 Explicitly not blocking

SPEC-036 compute-integrity (its own §6.1 admits enforce is unreachable at current supply), hardware-rooted device identity via MDA, losslessness enforcement. **But note the tension** (§11 Q4): §6.3 Step 6 and F11 establish that sanction durability depends on identity rooting. Deferring it is a deliberate acceptance that sanctions are deterrents rather than controls until R7 — not a claim that the gap is closed.

---

## 10. Roadmap / Issue Breakdown

Re-sequenced in r2 so that **supply-neutral work comes first** and nothing that slows provider onboarding is scheduled ahead of the data that would justify it. Sizes are S/M/L including the mandatory three-lane codex audit loop; "operator hours" is the operator's own time, not agent time.

---

### R1 — Persist coordinator-observed per-request performance · **Tier 1** · Size M (~6-10 operator hours)

- **Problem**: True TTFT and decode time are measured on every request and discarded; `request_log` cannot answer "what does provider X actually deliver on model Y."
- **Impact**: Foundation for R4, R5, R8, R9. Supply-neutral — it only starts accumulating data. Every week it is deferred is a week of lost history.
- **Change**: add nullable `ttft_ms` and `decode_ms` columns to `request_log`, populated from `requestPhaseTiming`; add a per-(provider, model) rolling aggregate **bucketed by prompt-token range × concurrency** (§5.4, SPEC-029 vocabulary), internal/operator-facing only per SPEC-017's anonymity constraint.
- **Files**: `internal/requestlog/store.go` (+ migration), `internal/buyer/phase_timing.go`, `internal/buyer/server.go`, new aggregate under `internal/stats/`.
- **Tests/evidence**: population across streaming/non-streaming/WS-tunnel paths; null-when-unmeasured; migration up/down; no public-surface change.
- **Open questions**: retention window; whether gateway-side timing also persists for cross-checking.
- **Blocks**: Tier 1. Do first regardless — it is the only item whose value strictly increases with earlier start.

### R2 — Overclaim remediation (docs/strings) · **Tier 0** · Size S (~2-3 operator hours)

- **Problem**: `README.md:22` and `docs/using-macprovider-with-openai-sdk.md:202` promise verified model identity as shipping, violating SPEC-006:343's own normative rule.
- **Impact**: Buyer-facing misrepresentation, independent of cohort size.
- **Change**: apply the `phase7-verify/README.md:129` pattern (state what the signature proves; enumerate what it does not).
- **Files**: `README.md`, `docs/using-macprovider-with-openai-sdk.md`.
- **Tests/evidence**: SPEC-006:3659's audit-cycle language check over the diff.
- **Blocks**: Tier 0.

### R3 — Enforce the capacity ceiling continuously, with a sole-provider floor · **Tier 0/1** · Size L (~12-20 operator hours)

- **Problem**: FR-HG7 — the ceiling has no routing consumer (its only live reader is warm-up probe targeting); heartbeat model switches apply unconditionally; no evidence-TTL recheck.
- **Impact**: CRITICAL per the spec's own rating. Tier 0 for the *detection/alert* half (a silent switch invalidates the live hash chain); Tier 1 for the *enforcement* half.
- **Change**: (a) persist `MaxAdmittedMinRAMGB` on `pool.Provider`; (b) on `modelIDChanged`, compare the new model's catalog `min_ram_gb` against that value **in memory** — do not read Postgres under the pool mutex; re-read evidence only out-of-band on the sweep; (c) over-ceiling/uncatalogued → routing-ineligible for that model + provider event, **never** eviction when it would empty the model's pool (reuse `CanaryTripFloorHeld` semantics, FR-CAN22); (d) add evidence-TTL to the 30 s `trust_revalidation.go` sweep; (e) enforce `swap_detected` in `benchmarkPassesGate` (closes the #742 coordinator asymmetry).
- **Files**: `internal/pool/provider.go`, `internal/ws/server.go`, `internal/ws/trust_revalidation.go`, `internal/autotune/gate.go`, `internal/routing/filter.go`.
- **Tests/evidence**: SPEC-032 AC-F1/AC-F2 flipped to pass; heartbeat-switch integration test; sole-provider floor test (last provider degrades to alert, not eviction); sweep TTL-expiry test; three-lane codex audit.
- **Open questions**: in-flight request semantics at demotion (see R5's settlement note); warm-up probe-target behavior when the ceiling changes (`providerProbeModelID` is the live consumer).
- **Blocks**: Tier 0 (alerting) → Tier 1 (enforcement).

### R4 — Rank routing on observed throughput, not self-report · **Tier 1** · Size M (~6-10 operator hours)

- **Problem**: `EffectiveThroughput = ThroughputTPSEstimate × tier_weight` drives the SPEC-004 "fast" objective on a provider-authored number (F12). This is the most direct claimed→revenue path in the system.
- **Impact**: Removes the single highest-value incentive to inflate a self-report. Supply-neutral (it re-ranks, it does not exclude).
- **Change**: substitute R1's observed aggregate for `ThroughputTPSEstimate` in `EffectiveThroughput`, falling back to self-report only below a sample-count threshold; keep the tier weighting untouched.
- **Files**: `internal/routing/candidate.go`, wiring in `internal/buyer/server.go`; SPEC-002/SPEC-004 amendment.
- **Tests/evidence**: ranking tests with inflated self-reports vs observed history; cold-start fallback tests.
- **Open questions**: sample-count threshold; per-bucket vs pooled aggregate for ranking.
- **Blocks**: Tier 1. Depends on R1.

### R5 — Probationary admission (§6) · **Tier 1** · Size L (~20-30 operator hours, incl. SPEC amendment)

- **Problem**: No defined path from a verified small model to a larger one that neither trusts self-report nor freezes providers at first hello; and no bounded-exposure window for a provider's first model.
- **Impact**: Without it, R3's ceiling hardens into exactly the first-hello freeze this document rejects.
- **Change**: per-(provider, model) probation implemented as an extension of the existing `TierProvisional` weighting, plus an **absolute** exposure budget; identical entry rules for first-model and upgrade (§6.3 Step 0b) with a bootstrap allowance; discounted/unbilled probation traffic; promotion requiring distinct-payer + elapsed-time (anti-self-dealing); per-(model, RAM-tier) bucketed floors; maximum probation window; cross-class raises explicitly labeled as capacity + operator confirmation until R12. Needs a SPEC amendment before IMPL per house process.
- **Files**: `internal/pool/provider.go`, `internal/routing/candidate.go` (extend, don't duplicate), `internal/autotune/gate.go`, `internal/onboarding/`, spec under `specs/`.
- **Tests/evidence**: state-machine tests; promotion/demotion over synthetic observed data; self-dealing test (single payer cannot promote); sole-provider floor interaction; fabricated-benchmark test against the **numeric** exposure budget.
- **Open questions**: budget values (§11 Q1); thin-traffic promotion — the canary fallback is unavailable while `pool.canary_enabled: false` under an active exception whose re-enable bar is a Pearl drill plus signed go/no-go, and #584 blocks the physical baselines. **Either R5 declares a canary-free time-boxed path (preferred) or it carries an explicit dependency on SPEC-031 re-enable.**
- **Blocks**: Tier 1. Depends on R1, R3.

### R6 — Hello gate on, with a non-blocking approval path · **Tier 1** · Size M (ops-heavy, ~8-12 operator hours)

- **Problem**: `require_autotune_hello_gate: false`; hardware verification gates nothing. But turning it on makes **dual-control operator approval a hard admission gate** (migration 019 raises `dual_control_required` when requester == approver) — on a one-operator team, for providers the operator does not know.
- **Impact**: Admission control exists only on paper until flipped; flipping it naively converts operator latency into an onboarding block (Entry 198 is the live cost: chip profile added, DB row verified, coordinator restarted, second-operator approval, all before one known Mac could serve).
- **Change**: (a) define an `admitted_but_unapproved` state — routable under probation caps, alerting, time-limited — so operator latency never blocks admission (promotes §11 Q7 from open question to requirement); (b) then execute the registered exception's re-enable condition with a fresh-onboarding proof. Sequence after R3 so the gate does not enforce a known CRITICAL bypass.
- **Files**: Pearl overlay (ops), `ops/exceptions/production-exceptions.json`, `internal/ws/server.go` + `internal/onboarding/` for the new state, journey evidence.
- **Tests/evidence**: live onboarding journey with gate on; `waiting_trust` → admitted-but-unapproved → approved flow; buyer probe through the gated provider.
- **Open questions**: whether a synthetic/staged stranger satisfies the exception's "fresh onboarding" bar, given that a real stranger is the event R6 gates.
- **Preconditions**: config-reload-without-restart, **or** a second provider online — a coordinator restart on a single-provider pool is a documented multi-hour outage (incident 2026-07-10). This is a precondition, not an open question.
- **Blocks**: Tier 1. Depends on R3, R5.

### R7 — Make sanctions durable against identity rotation · **Tier 1/2** · Size M (~8-12 operator hours)

- **Problem**: F11 — probation/demotion state keyed to the trust tuple is cleared by `rm ~/.config/macprovider/autotune-hmac-secret`. Every sanction R3/R5 introduce is washable.
- **Impact**: Determines whether the Tier-1 apparatus is a control or a deterrent. Tier 1 if the cohort opens to strangers; Tier 2 while the operator installs every Mac.
- **Change**: minimum viable — bind sanction state to the *provider credential* (operator-issued, not provider-derived) in addition to the tuple, and have the coordinator issue the identity secret at registration rather than accepting a provider-generated one. Full device rooting (MDA, `IOPlatformSerialNumber`) stays deferred.
- **Files**: `AutotuneRecommend.swift` (identity derivation), `internal/onboarding/`, migration for sanction keying.
- **Tests/evidence**: rotation test (secret deleted → sanction persists); credential-rotation semantics.
- **Open questions**: migration path for existing tuples; interaction with legitimate re-installs.
- **Blocks**: Tier 1 if opening to strangers; otherwise Tier 2. §9.4 records the accepted risk in the interim.

### R8 — In-band signed provenance (now) + gate re-derivation (deferred) · **Tier 2** · Size S + L

- **Problem**: Provenance is unsigned client-side state (F3); no trusted post-#745 matrix exists; two vocabularies unreconciled; `verify` weaker than `generate` at five call sites.
- **Change**: **R8a (buildable now, Size S)** — next release ships in-band provenance; `require_provenance` added to every `validate_candidate` call site; adopt §7's ladder including `omlx_seeded`. **R8b (deferred, Size L)** — Stage-4 promotion tooling; **explicitly unbuildable until ≥3 verified providers exist**, and the >32 GB rows remain unmeasurable pending #584.
- **Files**: `scripts/catalog-release.py`, catalog JSONs, `AutotuneStrictJSON.swift`/`AutotuneRecommend.swift`, `autotune_feeds.go`, SPEC-023 amendment folding the #687 draft.
- **Tests/evidence**: `scripts/test-catalog-release.sh` extended; provenance-required fail-closed on both sides.
- **Open questions**: N/M quorum (§11 Q2); v5 signer activation timing (this release may be the natural point).
- **Blocks**: Tier 2.

### R9 — Wire observed data into drift; retire self-vs-self checks · **Tier 2** · Size M

- **Change**: feed R1 aggregates in as the drift baseline; replace `ModelLoadTimeMs`-derived Pillar D thresholds with observed history; add the RAM self-report vs verified-tuple tripwire; escalate WARN → probation via R5's machine.
- **Files**: `internal/pow/drift.go`, `internal/tier2/pillar_d.go`, `internal/ws/server.go`, config.
- **Open questions**: window sizes; division of labor with the canary if SPEC-031 re-enables.
- **Blocks**: Tier 2. Depends on R1, R5.

### R10 — Spec/doc drift reconciliation · **continuous hygiene** · Size S

- **Change**: fix §4.10's list; add a "what the catalog signature does not prove" section to SPEC-023 (SPEC-015 pattern); amend SPEC-013 NFR-4 to enumerate **all** egress paths (HF pre-warm, hardware evidence, rate card, signed static feeds).
- **Files**: `specs/SPEC-032`, `SPEC-033`, `SPEC-008-tier2.md`, `SPEC-013`, `SPEC-023`, `ops/runbooks/spec-drift-remediation.md`.
- **Blocks**: nothing; do alongside R1/R2.

### R11 — Low-cost hash-chain hardening · **Tier 2** · Size M

- **Change**: compare the SE-signed `claimed.model_hash` against the catalog in `pillar_c.go` (it is already signed and currently discarded); define an expected source for `weights_manifest_sha256` or stop collecting it; sign the rate card.
- **Files**: `internal/tier2/pillar_c.go`, `internal/pool/provider.go`, `AutotuneRecommend.swift:1330-1340`, `internal/buyer/rate_card.go`, release scripts.
- **Blocks**: Tier 2.

### R12 — SPEC-036 compute-integrity (observe mode) · **Tier 2, post-beta** · Size XL

- **Problem**: The only designed mechanism that roots model claims in coordinator-held reference data has zero code — and it is the only thing that would make cross-class ceiling raises observation-backed rather than capacity+operator-backed (§6.3 Step 4).
- **Change**: implement per the merged SPEC in observe mode; enforce stays maintainer-gated and is unreachable at current supply (SPEC-036 §6.1).
- **Blocks**: nothing, but it is the named closure for §6.4's acknowledged weak spot.

**Sequencing**: `R1 ∥ R2 ∥ R10` immediately (supply-neutral) → `R3` → `R4` → `R5` → `R6`, with `R7` promoted into that chain the moment a non-personally-installed provider is expected. `R8a` any time; `R8b`, `R9`, `R11`, `R12` follow. Minimum viable subset if time-constrained: **R2, R1, R3(a-c)** — overclaim fixed, data accumulating, silent model-switching no longer possible.

---

## 11. Open Questions

1. **Probation exposure budget** (R5): numeric values for max concurrent slots, max requests before first floor evaluation, max cumulative billed value; promotion N (distinct-payer count, sample count) and elapsed-time T; maximum probation window. The *requirement* that these be absolute and numeric is settled (§6.3 Step 3); the values are not.
2. **Quorum for `trusted_provider_matrix`** (R8b): N providers, M hardware classes; how to treat rows only one provider ever serves; whether #584's hardware unblock changes the answer.
3. **N for the Tier-1 threshold** (§9.2): proposed 5, defined operationally as "the operator no longer personally installs each Mac." Is a count the right form, or should it be the qualitative trigger alone?
4. **Identity rooting timing** (R7): does prebeta reach strangers before R7 lands? §9.4 accepts sanctions-as-deterrents in the interim; that acceptance should be revisited at the first non-personally-installed provider.
5. **Thin-traffic promotion** (R5): time-boxed bootstrap vs SPEC-031 canary re-enable. The canary path carries #584 and a signed go/no-go bar; the time-boxed path grants promotion on absence of evidence. Which is less bad?
6. **Sole-provider floor semantics** (R3/R5): FR-CAN22 gives the canary shape; does the same "hold the floor and alert" rule apply to a provider serving *above its ceiling*, where holding the floor means knowingly routing to an unadmitted model?
7. **Workload bucketing** (R1/§5.4): SPEC-029's classes are sweep-output definitions with no runtime classifier. What is the minimum runtime bucketing that makes floors fair — prompt-token ranges alone, or does concurrency need to be a dimension from day one?
8. **Cross-class promotion in the interim** (§6.3 Step 4): "capacity + operator confirmation" reintroduces the operator as an approver of something performance-adjacent — precisely F8's concern. Is a bounded number of operator-confirmed cross-class raises acceptable, or should cross-class raises simply wait for R12?
9. **SPEC-022 enforce timing**: orthogonal but interacts with R5 (probation traffic generates receipts; discounted/unbilled probation needs a settlement story).
10. **Rate-card signing mechanics** (R11): separate sidecar vs folding into the release unit (affects rotation and v5 activation).

---

## 12. Evidence Appendix

### 12.1 Primary code references by area

**Catalog signing/release**: `scripts/resign-autotune-static.sh:10-128`; `scripts/catalog-release.py:242-336, 410-541, 810-855, 1324, 1499-1649, 1697, 1721`; `scripts/sign-catalog.go:143-147, 309-318, 361-364`; `phase3-binary/catalog/autotune/trusted-keys.json`; `phase3-binary/dist/static/keys/README.md:59-129`; `AutotuneRecommend.swift:1260-1488, 1604-1616`; `AutotuneCatalog.generated.swift:10-19`; `internal/buyer/autotune_feeds.go:29-30, 144-237, 482-541, 840`; `dist/coordinator.yaml:211-217`; `internal/buyer/server.go:673-678`.

**bench_gate/autotune**: `specs/SPEC-023-installer-autotune-recommend.md:9-34, 71-74, 226-252, 380-461, 498-533, 551, 670-737, 791`; `AutotuneRecommend.swift:60-116, 183-266, 471-544, 746-849, 1330-1340, 1678-1696, 1811-1886, 1927-1977, 1998-2084, 2377-2400, 3028-3129, 3133-3178`; `AutotuneCommand.swift:7, 37, 47-51, 80-81, 608-611, 719-724, 872-921, 950-984, 1045-1073, 1206`; `Stage1Iterator.swift:380-624`; `ConfigApplier.swift:172-184`; `specs/SPEC-013-cli-autotune.md:435-586, 1043-1300`; `specs/SPEC-029-sweep-workload-class-stratification.md` (header, §1).

**#745 fix chain**: `Config.swift:489-526, 592-616`; `CandidateProviderRunner.swift:269-305`; `MacProviderCLI.swift:373-378, 559-736, 945, 1024-1026, 2012-2017`; `ModelRuntime.swift:601, 610, 822-829`; `AutotuneHardwareEvidence.swift:210-213, 340-365`; `hardware_evidence.go:64-66`.

**Hardware verifier**: `specs/SPEC-033-hardware-verifier.md:76-78, 91-123, 183-222, 266-273, 298-362, 367-388, 419, 448-534, 571-574`; `internal/onboarding/hardware_evidence.go:69, 89-210, 233-359, 372-476, 527-544`; `internal/stats/hardwareverify/verify.go:16-30, 126-256, 262-368, 394-485`; `internal/ws/admin_hardware_trust.go:42-608`; migrations `007, 008, 015, 016, 017, 019` (019 header `:9-12, :17`, dual-control raise `:505-507`); `cmd/stats-hardware-verifier/main.go:17-41`; `AutotuneHardwareEvidence.swift:12-13, 27-51, 70, 136-168, 264-374`; `AutotuneRuntimeSupport.swift:118-141`; `SEAttestationBuilder.swift:170-174`.

**Hello/heartbeat/routing**: `internal/ws/messages.go:19-47, 94-136, 298-320, 361-367, 403-446, 528-540, 938, 1149-1253`; `internal/ws/server.go:891-916, 906-910, 955-1068, 1315-1506, 1778, 1826-1831, 2116-2464, 2666, 3416, 3423, 3442-3447, 3525-3681, 3734, 4261-4400, 4852-4875`; `internal/pool/provider.go:39, 62-66, 187-201, 216-225, 409-443, 788-862, 1254-1277, 1284-1366, 1552-1621, 1811-1923`; `internal/routing/candidate.go:65-92`; `internal/autotune/gate.go:8-108`; `internal/autotune/evidence_pg.go:24-108`; `internal/routing/filter.go:118-188`; `internal/buyer/server.go:901-931, 1092-1096, 1564-1585, 1574-1698, 5447, 5637-5647, 6140-6162, 6283-6309, 6385-6450`; `internal/ws/trust_revalidation.go:12-23, 121, 149-210`; `internal/ws/canary_probe.go:27-120`; `internal/canarycorr/epoch.go:102, 259, 356`; `CoordinatorClient.swift:385, 2146, 4211, 4401-4423, 4478-4563`; `phase5-gateway/internal/router/server.go:307-312, 575-600, 671-678`.

**Observed-performance substrate**: `internal/buyer/phase_timing.go:20-29, 204-260`; `markProviderFirstByte` sites `internal/buyer/server.go:2439, 2530, 2880, 3086, 3369, 3540, 3646, 3901`; `internal/requestlog/store.go:43-100, 464-489`; `internal/billing/settlement_output.go:22, 46-52, 96`; `internal/stats/migrations/001_stats_tables.up.sql:18-62`; `internal/providerevents/store.go:35-52, 155-174, 341-343`; `phase5-gateway/internal/router/phase_timing.go:9-56`.

**Tier2/attestation/OPoI/settlement**: `specs/SPEC-008-tier2.md:97-102, 841, 941-957, 1229-1247, 1758-1874, 2437`; `internal/tier2/pillar_c.go:65, 156, 295-297, 433-437`; `internal/tier2/pillar_c_se.go:17, 43`; `internal/tier2/pillar_d.go:167-197`; `internal/tier2/catalog.go:331-372, 529-533, 751-757`; `Tier2Attestation.swift:93-96`; `specs/SPEC-022-verified-model-settlement.md:145-149, 421-451`; `internal/billing/route_snapshot.go:26, 195`; `internal/billing/settlement_receipts.go:616-622, 700-706, 884-899`; `internal/billing/store.go:202, 294, 909-925`; `internal/billing/payout.go:76-150`; `internal/config/config.go:505-533, 908, 994, 1047, 1074-1081, 1120, 1836, 2082`; `specs/SPEC-027-provider-proof-of-ownership.md`; `cmd/coordinator/main.go:601-624, 1622`; `internal/pow/drift.go:15, 112, 127-212`; `specs/SPEC-030-losslessness-probe.md:20, 41, 82`; `internal/ws/losslessness.go:261-1099`; `specs/SPEC-032-proof-of-weights-hello-gate.md:29-52 (quote at :38), 99, 137-144, 282-331, 445-462, 516-519, 553-555, 653-655`; `specs/SPEC-036-compute-integrity-receipt.md:41-92, 262-274, 2051-2094, 2323-2331`.

**UX surfaces**: `internal/stats/handlers.go:77-131`; `internal/stats/poolsnapshot/poolsnapshot.go:66-108, 143-160`; `internal/stats/hardware/cache.go:96-160`; `ProviderHardwareSummary.swift:18, 48-105`; `phase5-gateway/internal/router/disclosure.go:59, 215-227, 300-313`; `phase5-gateway/internal/router/pages.go:27-64`; `phase5-gateway/internal/router/templates/docs.md:145-155`; `internal/buyer/rate_card.go:17-51`; `frontdoor/console/index.html:511-525, 856-874, 1219-1220, 1359-1447`; `frontdoor/provider-portal/index.html:1380, 1399-1419, 1590`; `SelfUpdate.swift:2589-2718`; `RecommendationEmitter.swift:169-177`; `README.md:22, 67, 104, 142`; `docs/using-macprovider-with-openai-sdk.md:202`; `phase7-verify/README.md:129`; `specs/SPEC-006-buyer-api.md:343, 3659`; `specs/SPEC-007-explorer.md:6-9, 28-57, 675-688`; `specs/SPEC-014-provider-portal.md:925-1013, 1295-1363, 1531`; `specs/SPEC-017-network-stats-api.md:362, 594-661, 730-746`; `specs/SPEC-034-referral-gated-prebeta.md` (header, §8); `dist/coordinator.yaml:108-112`.

### 12.2 Decision-log and issue anchors [E-issue unless noted]

- **#744** (open, P2) — provenance audit table; floor-vs-fit analysis; #687 Stage-4 pull-ahead. **#745** (closed) — incumbent-benchmark bug. **#742** (closed) — swap disqualifier + 60 s default removal; live prod data (`swap_detected=true` served at `pool_size: 1`). **#687** (open) — oMLX provisional gates draft + trust invariant. **#584** — lab-Mac hardware blocker; canary-induced throughput collapse on the M1 8 GB provider. **PR #772** — #744 partial (SPEC-023 v0.8). **PR #751** — #745 fix. **PR #748** — #742 fix. **PR #387** — SPEC-029 landed.
- `beta/DECISION_CRITERIA.md` [E-spec]: Entry 109 (display-capacity fallback, partially stale), Entry 134 ("signed benchmark" over-claim correction), Entry 191 (`require_hash_verified` flip), Entry 195 (small-cohort ops posture), Entry 196 (#744 bridge decisions + rejected re-derivation), Entry 198 (Air5 `waiting_trust` → dual-control approval → serving), Entry 199 (blind + real-hardware verification as the runtime-feature merge gate — the methodology precedent this roadmap's IMPL items should follow).
- `ops/exceptions/production-exceptions.json` + `ops/runbooks/pearl-exception-clearance-20260722.md` [E-spec] — live overlay truth for gate/canary/hash flags; `exc-canary-disabled-enable-gate` re-enable bar.
- `docs/research/RESEARCH_231_OMLX_BENCHMARK_CATALOG_MEMO.md` [E-spec] — oMLX calibration bands; PP-derived TTFT 1.3–2.5× underestimate (#9); gate-slack policy (#10).

### 12.3 Claims deliberately left unverified

- All `[E-session]` Pearl-DB claims in §2.3. Read-only SSH re-verification was attempted this pass and blocked by session permission policy; semantics are independently code-verified, and Entry 198 provides one fully-documented live instance.
- Live overlay values are from the committed 2026-07-22/23 verification artifacts, not a fresh read. If a flag changed after 2026-07-23, §2.2 is stale to that extent.
- Issue/PR body contents (`[E-issue]`) are not in-repo and were read via `gh`; they are re-readable but not version-pinned by this document.

### 12.4 Review history

- **r1** (2026-07-27) — initial six-lane audit.
- **r2** (2026-07-27) — revised after adversarial verification (C=1 H=7 M=10 L=7) and product-design critique (C=4 H=11 M=10 L=3). Material changes: §3.3 corrects the `coordinator_observed` unforgeability claim; §3.4 documents tuple rotatability and the operator-verification ceiling; §6 splits capacity from performance, defines cold start, scopes promotion by model class, reuses `TierProvisional`, requires absolute exposure budgets, resolves probation pricing, and adds anti-self-dealing; §5.3.6 makes the sole-provider floor normative; §7 rule 5 fixes the ladder inversion; §9.2 replaces one blocking flag with three tiers and a provider-count trigger; §10 re-sequences supply-neutral work first, adds R4 (routing objective) and R7 (sanction durability), splits R8, and adds size/operator-hour estimates. Citation corrections: `providerProbeModelID` has two readers (warm-up live, canary disabled); `ops/runbooks/` path; SPEC-032 quote at `:38`, posture at `:553`; SDK doc at `:202`; five `validate_candidate` call sites; NFR-4's three egress paths; Pillar D observe-only; `[E-issue]` class added.
