# Audit prompt — SPEC-015 v0.3 model-hash binding

Operator-paste prompt to audit SPEC-015 v0.3 deltas in
`specs/SPEC-015-receipts.md`, MacProvider's verifiable inference
receipt contract. v0.3 extends the receipt tuple from 7 fields
(v0.1 / v0.2) to 9 fields by adding `model_hash` and
`receipt_version`, defines a catalog-based verifier extension,
adds a SPEC-002 v1.6 candidate `/poolz` catalog surface, and
pins normative provenance + version-compatibility rules.

**Cross-model pattern:** v0.3 deltas were drafted by Claude
(executing `specs/BUILD_SPEC_015_RECEIPTS_v0_3_MODELHASH_PROMPT.md`).
For independence, the audit runs in **Codex CLI first** (via
`omc ask codex` or the ambient `ask` skill), three sequential
lenses: `code`, `security`, `architect`. After Codex round 1
(all three lenses) lands, Claude does a round-2 pass for any
lens that Codex flagged with mixed verdicts. All audit reports
go into `specs/SPEC-015-v0-3-audit.md` as separate sections,
matching the v0.2 audit history in `specs/SPEC-015-v0-2-audit.md`
and the v0.1 history in `specs/SPEC-015-audit.md`.

Expected duration: ~30–45 min per lens. v0.3 deltas are scoped:
the new top-level **§M** (six subsections §M.0..§M.6); the
**Change log v0.3.0** block at the top of the spec; targeted
edits to §3.1 (legacy-shape pointer), §3.4 (wire-size envelope),
§7.6 (error-receipt hash inheritance, via §M.2 reference),
§10.4 / §10.4.2 / §10.4.4 / §10.6 (verifier CLI flag matrix +
result schema enum extensions + trust-boundary supersession),
§11 (`receipt_omitted` `model_swap_violation` semantics), §15
(Q6 close + new Q7), and §16 references. v0.1.x §§1-9 (except
§3.1 / §3.4 / §7.6 pointer edits noted above), §13, §14
AC-1..AC-17, §16 v0.1 references, and v0.2 §§10.0-10.7,
§14 AC-18..AC-27 are **LOCKED and out of scope**. Surface any
concern about them as a v0.4+ open question, not a v0.3 finding.

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session (round 1) or
Claude Code session (round 2) rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-015 v0.3 deltas, MacProvider's
verifiable-receipt model-hash binding extension at
/Users/augstar/macprovider-poc/specs/SPEC-015-receipts.md.

You are NOT here to validate, rewrite, or extend the spec. Find
problems, report them with specific severity and location, let
the operator decide fixes. The operator has read the spec; they
need an independent second (or third) opinion on what is
missing, wrong, or under-specified in the v0.3 deltas.

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-015-v0-3-audit.md

Format: structured audit report. Findings grouped by lens
(code / security / architect) and within each lens by category,
each finding tagged with severity (CRITICAL / MAJOR / MINOR /
QUESTION) and location (section number + line range if
possible). Match the rigor of `specs/SPEC-015-v0-2-audit.md`
(v0.2 audit) and `specs/SPEC-015-audit.md` (v0.1 audit). If you
are running as round 2 (Claude after Codex), APPEND your section
to the existing file, do not overwrite Codex's round 1.

End each lens section with a one-line verdict line:

  VERDICT: READY TO LOCK | READY WITH FIX PASS | DESIGN ROUND NEEDED

and a count line in the form:

  COUNTS: CRITICAL=N MAJOR=N MINOR=N QUESTION=N

so the operator can compute the rollup verdict and decide whether
to fix-then-relock (FIX PASS) or to restructure the design and
re-audit (DESIGN ROUND NEEDED).

## Scope — v0.3 deltas ONLY

The v0.3 changes are bounded:

1. **Line 3** version bump to `0.3.0 (2026-06-24, model-hash
   binding — LOCK candidate, codex audit pending)`.
2. **Line 4** Depends-on update — SPEC-011 v0.5 + SPEC-008 v0.3
   promoted to HARD dependencies; SPEC-010 v1.5 added as SOFT
   dependency; SPEC-002 v1.6 candidate annotation per §M.4
   named.
3. **Lock state v0.3** block (replacing previous lock-state
   line) + preserved v0.2 lock state for history.
4. **Change log v0.3.0** block at the top of the change-log
   stack (above v0.2.4).
5. **§3.1 update** — pointer to §M.0; v0.1 / v0.2 7-key shape
   retained for legacy receipts.
6. **§3.4 update** — wire-size envelope for the v0.3 9-field
   tuple (≤ 700-byte JCS, ≤ 960-byte header).
7. **§7.6 update** — error / null-usage receipts inherit §M.2.
8. **§10.6 update** — trust-boundary supersession for v0.3
   `valid` results with non-null hash + catalog.
9. **§11 update** — `receipt_omitted` `model_swap_violation`
   reason promoted from placeholder to defined semantics.
10. **NEW top-level §M** between §10.7 and §11:
    - §M.0 v0.3 receipt tuple (9-key normative shape, JCS
      byte order)
    - §M.1 Wire and version compatibility (back-compat M.1.1,
      forward-incompat M.1.2, normal-path M.1.3, unknown-version
      M.1.4, no-JCS-amendment M.1.5)
    - §M.2 `model_hash` provenance (M.2.1 heartbeat lag,
      M.2.2 mid-response swap REFUSED, M.2.3 null-hash semantics)
    - §M.3 Catalog-based verification (M.3.1 four new CLI flags,
      M.3.2 8-step verification algorithm, M.3.3 trust-boundary
      update, M.3.4 cache TTL)
    - §M.4 Coordinator `/poolz` extension (SPEC-002 v1.6
      candidate: `catalog_id`, `catalog_url`,
      `catalog_pubkey_url`, `GET /catalog/<catalog_id>`,
      `GET /catalog/pubkey`)
    - §M.5 Acceptance criteria AC-28..AC-42 (15 new ACs)
    - §M.6 What v0.3 explicitly DOES NOT change (9 deferred
      items)
11. **§15 Q6 update** — RESOLVED in v0.3; orthogonality to
    Entry 80 `RequireHashVerified` made explicit.
12. **§15 Q7 NEW** — multi-hash receipts for swap-spanning
    streaming responses deferred to v0.4+.
13. **§16.2 v0.3 additional references** appended (catalog
    parser sources, Entry 80, SPEC-008 §5.3-5.6, SPEC-010 v1.5,
    SPEC-011 §3.2-§3.4, live infrastructure citation).

Any concern about v0.1.x clauses (§§1-9 except the §3.1 / §3.4 /
§7.6 pointer edits, §13, §14 AC-1..AC-17, original §16 lines)
or v0.2 clauses (§§10.0..10.7, §14 AC-18..AC-27) is **OUT OF
SCOPE** for this audit. If you believe one is broken, file it
as a v0.4+ open question, NOT a v0.3 finding. v0.1.3 went
through a 4-round audit; v0.2.4 went through a 5-round audit;
both are LOCKED.

## Severity definitions

- **CRITICAL** — would cause: (a) verifier-side rejection of
  legitimate v0.3 receipts; (b) false `valid` reports on
  receipts that name a model whose actual loaded hash differs
  from the catalog's expected SHA-256; (c) signature
  verification bypass on the new 9-field tuple; (d) JCS
  byte-order divergence between v0.3 Swift signer and v0.3 Go
  verifier; (e) `RFC8785JCS.swift` requiring amendment despite
  §M.1.5 claiming it does not; (f) v0.3 breakage of v0.1 / v0.2
  back-compat per §M.1.1; (g) the catalog-pubkey trust root
  introducing a worse-than-`/poolz` trust posture without
  saying so in §M.3.3 / §M.4; (h) §M.2.2 mid-swap refusal being
  unenforceable in practice (e.g. SPEC-011 §3.2 state machine
  does not give the provider a deterministic signal at
  receipt-emission time); (i) `model_hash: null` semantics
  collapsing into `invalid` or silently into `valid-with-attestation`,
  contrary to §M.2.3; (j) §M.4 `/poolz` catalog fields leaking
  operator-sensitive data the SPEC-002 v1.4 §FR-O2 protections
  forbid; (k) any v0.3 clause that reaches back into v0.1.x or
  v0.2 locked content and changes its meaning.

- **MAJOR** — would cause: significant buyer confusion;
  predictable v0.3.x patch within first month of deployment;
  ambiguity that two conforming v0.3 verifier implementations
  could resolve differently and produce different results on
  the same v0.3 receipt; under-justified numeric thresholds
  (6h cache TTL, 60s catalog skew grace, the new
  `--catalog-pubkey` 44-char base64 budget); hand-wavy MUST /
  SHOULD splits in §M.2, §M.3, or §M.4; CLI flag-combination
  rules in §M.3.1 that admit undefined behavior; AC test
  commands in §M.5 that are not reproducible (e.g. depend on a
  fixture file the spec doesn't name); §16 references that
  conflict with cited source-file line numbers; missing
  forward-compat reasoning (e.g. how a v0.4 receipt against a
  v0.3 verifier behaves under §M.1.4).

- **MINOR** — quality issues that don't block v0.3 but should
  be cleaned in v0.3.1 or v0.4. Naming inconsistencies, missing
  cross-references between §M and §10 / §3 / §7 / §11 / §15 /
  §16, prose clarity, underspecified edge cases that won't fire
  frequently, redundant or contradictory phrasing.

- **QUESTION** — genuinely unresolved design choices the spec
  couldn't decide alone. Operator input required. Distinguish
  from the §15 Open Questions the spec already names (Q1, Q2,
  Q3, Q4, Q5, Q7) — those are not findings unless they hide a
  CRITICAL/MAJOR underneath.

## Critical constraints to honor while auditing

**1. v0.1.x AND v0.2 normative content is LOCKED.** Any v0.3
clause that would require changes to v0.1.x §§1-9 (except the
§3.1 / §3.4 / §7.6 pointer edits explicitly noted), §13, §14
AC-1..AC-17, original §16 references, or to v0.2 §§10.0-10.7
and §14 AC-18..AC-27, is a CRITICAL finding ("v0.3 deltas reach
back into locked content").

**2. The v0.1 / v0.2 wire contract is BIT-IDENTICAL for legacy
receipts.** v0.3 introduces a NEW wire shape (the 9-field
tuple) gated by `receipt_version: "3"` and applied ONLY to v0.3
receipts. v0.1 / v0.2 receipts (with no `receipt_version`)
MUST canonicalize and verify exactly as v0.1.3 / v0.2.4
specified. Any clause that changes the 7-field v0.1 / v0.2
canonical bytes, JCS rules in §3.2, or §3.3 signature step =
CRITICAL.

**3. §M.3.3 trust boundary is the surface a security auditor
will hit hardest.** Any clause anywhere in v0.3 that
contradicts §M.3.3 (e.g. an AC implying timestamp attestation,
a clause silently strengthening the trust root, a default
behaviour that lets `--catalog-pubkey-url` short-circuit
operator-pinning safety) = CRITICAL. The v0.2 §10.6
DOES-NOT-PROVE list is PRESERVED for v0.3 except for the
specific model-name bullet superseded by §M.3.3; any v0.3
clause that accidentally erodes the other §10.6 disclaimers
(timestamp honesty, no-other-observer, uniqueness, replay-
resistance) = CRITICAL.

**4. `inconclusive` remains a first-class result.** Any v0.3
clause that implies `inconclusive` collapses into `valid` or
`invalid`, or any default behavior that silently downgrades
`inconclusive` to `valid`, = CRITICAL. Specifically check
§M.3.2 step 5 (expired catalog → inconclusive), step 6
(unknown model_id → inconclusive), §M.2.3 (null hash + catalog
→ valid-without-hash-check), §M.1.4 (unknown receipt_version
→ inconclusive).

**5. The v0.3 verifier and provider have no implementation
yet.** This audit is on the spec, not on code. Any finding that
depends on "the code will / won't do X" is out of scope;
surface it as guidance for the forthcoming
`specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` instead.

**6. SPEC-011 v0.5 + SPEC-008 v0.3 are HARD dependencies.**
v0.3 depends on SPEC-011 v0.5 §3.3.0-§3.3.5 (heartbeat
extension, opt-in gating), §3.2 (warm-swap state machine),
§3.4 (drain semantics) for §M.2 to be enforceable. v0.3 depends
on SPEC-008 v0.3 §5.3-5.6 (Pillar A hash semantics) for §M.3.2
catalog-check provenance. Any v0.3 clause that requires
SPEC-011 OR SPEC-008 amendments to be true = CRITICAL ("v0.3
silently demands cross-spec amendment").

**7. Entry 80 `RequireHashVerified` deferral is preserved.**
`beta/DECISION_CRITERIA.md` 2026-06-22 Entry 80 ruled that the
flag stays at its `false` default until any of three triggers
fire. §M.6 #1 and AC-40 pin this. Any v0.3 clause that
silently demands a flag flip = CRITICAL.

**8. d-inference clean-room.** Do NOT inspect d-inference
source.

## Required reading (in order, fully)

1. `/Users/augstar/macprovider-poc/specs/SPEC-015-receipts.md`
   v0.3.0 — the spec under audit. Read fully. Bias toward
   reading **§M** carefully — this is the entire v0.3 contract.
   Then read the change log v0.3.0 block, then re-read §3.1 /
   §3.4 / §7.6 / §10.6 / §11 / §15 Q6 + Q7 / §16 to verify the
   delta edits.

2. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_015_RECEIPTS_v0_3_MODELHASH_PROMPT.md`
   — the BUILD prompt with the operator's v0.3 spec-writing
   instructions. The spec MUST honor every item under "What
   v0.3 MUST normatively add" and every item under "What v0.3
   MUST explicitly defer". Diff it against §M and the v0.3.0
   change log; any deviation = MAJOR ("BUILD prompt directive
   drift") or CRITICAL ("BUILD prompt MUST became SPEC SHOULD",
   or "v0.3 silently shipped a deferred item"). Particularly
   check that the BUILD prompt's "five most contentious design
   choices" (receipt_version field, null-hash semantics,
   §M.2.2 enforceability, catalog-trust root, forward-compat
   marker) are each pinned with a defensible decision and
   rationale.

3. `/Users/augstar/macprovider-poc/specs/SPEC-015-v0-2-audit.md`
   AND `/Users/augstar/macprovider-poc/specs/SPEC-015-audit.md`
   — v0.2 + v0.1 audit histories. v0.3 MUST NOT regress
   anything either round closed. Specifically check the
   round-1 v0.2 findings on trust-root architecture (CF1),
   time-window validity (CF2), schema strictness (CF3), and
   the round-2-3 findings on stale `/poolz` wording (CF4) and
   `--provider-id` first-class CLI input (CF5). v0.3's catalog
   surface and verifier flags MUST follow the same trust
   posture and CLI conventions.

4. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 — §3.2 warm-swap state machine, §3.3 heartbeat
   extension (R-3.3.0 opt-in, R-3.3.1 raw 64-hex, R-3.3.5
   replacement rule), §3.4 drain semantics (R-3.4.1 in-flight
   tracking, R-3.4.2 drain timeout, R-3.4.4 503 on
   loading/draining). Verify §M.2 provenance rules are
   ACHIEVABLE under SPEC-011's rules without amending SPEC-011.
   Especially check §M.2.2: does the SPEC-011 §3.2 state
   machine give the provider a deterministic, atomic signal at
   receipt-emission time that disambiguates "which container
   served this request"? If not, §M.2.2 needs a SPEC-011
   normative addition, which means §M.2.2 reaches into a hard
   dep and v0.3 silently demands cross-spec amendment.

5. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.3 — §5.3-5.6 Pillar A model-hash semantics; §5.5
   five-state HashStatus enum; §5.6 routing predicate. Verify
   §M.3.2 catalog-check semantics are CONSISTENT with §5.3-5.6
   (the buyer-side verifier mirrors the coordinator-side
   check); any divergence = MAJOR ("v0.3 buyer-side and v0.3
   coordinator-side resolve to different hash-verification
   outcomes on the same inputs").

6. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 — `supported_models[]` + `publishes_supported_models`
   semantics. Verify §M.2.3 (warm-swap-disabled null-hash) is
   internally consistent with SPEC-010's published-models
   semantics. Verify §M.6 #6 (quantization variants get
   distinct `model_id`) is supported by SPEC-010's namespace
   conventions.

7. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.4 — focus on §7 (`/poolz` shape). v0.3 §M.4 adds three
   new top-level fields and two new endpoints as a SPEC-002
   v1.6 candidate annotation. Verify the annotation is
   additive, non-breaking, and follows the SPEC-002 v1.4 +
   v1.5 candidate-annotation precedent. Verify it does NOT
   leak operator-sensitive fields the v1.4 §FR-O2 protections
   forbid (`hostname`, `endpoint_url`, `connected_at`,
   throughput estimates).

8. `/Users/augstar/macprovider-poc/scripts/sign-catalog.go` —
   the existing catalog signing tool. Verify §M.3.2 step 4
   reconstructs the canonical body in the EXACT key order
   `sign-catalog.go:42-49` produces (`catalog_id`,
   `expires_at`, `issued_at`, `models`, `version`) and decodes
   the signature as `base64.RawURLEncoding` per
   `sign-catalog.go:145`. Verify the per-model field is named
   `sha256` per `sign-catalog.go:31` and NOT something else.

9. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/tier2/catalog.go`
   — the existing in-coordinator catalog parser. Verify §M.3.2
   schema matches `catalogFile` per `catalog.go:64`, validates
   the 64-hex pattern per `catalog.go:22`, and uses
   `ParsedCatalog.CatalogID` per `catalog.go:45`. Verify the
   v0.3 verifier's reimplementation discipline (pure-Go in
   `phase7-verify/`) per §M.3's opening paragraph.

10. `/Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
    — the in-house Swift JCS implementation. Verify §M.1.5's
    "no amendment required" claim: the two new keys
    (`model_hash`, `receipt_version`) sort cleanly into the
    existing UTF-16 key-order emission path, the JSON null
    literal is handled by §3.2 step 1 (RFC 8785 §3.2.2.2), and
    no new types enter the canonical form.

11. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go`
    lines 142, 335 — current state of
    `Tier2Config.RequireHashVerified` (default false). Verify
    §M.6 #1 and AC-40 cite the right lines and the right
    default value.

12. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
    Entry 80 (2026-06-22) — operator ruling on
    `RequireHashVerified` deferral. Verify §M.6 #1 matches
    Entry 80's three triggers verbatim and does not silently
    add or drop a trigger.

13. `/Users/augstar/macprovider-poc/README.md` lines 1-137 —
    the thesis. v0.3 closes the "decentralized inference"
    promise's hardest gap (provider-loaded weights provably
    matching declared model). The §M.3.3 trust boundary MUST
    match what the README does (and does not) promise after
    v0.3 ships.

## Audit categories — work through each lens, then each category

### Lens 1 — CODE (impl-feasibility / API design)

C.1  **Tuple shape (§M.0).** Verify the 9-field table is
     complete: every field has a stated type, a stated
     required/optional disposition, and a stated provenance.
     Check that the table is presented in JCS canonical order
     and that this order matches what RFC 8785 §3.2.3 produces
     for the 9 ASCII key names listed. Spot-check by computing
     UTF-16 code-unit lex order on the 9 strings; any
     mis-ordering = CRITICAL.

C.2  **Version detection (§M.0 + §M.1.1 + §M.1.4).** Verify
     the version-detection rule (presence of `receipt_version`,
     not field count) is unambiguous. Specifically: what does
     a v0.3 verifier do if it receives a 7-field receipt where
     one of the seven IS named `receipt_version`? What does it
     do for a 9-field receipt missing `receipt_version` but
     having one of the v0.3 fields? The spec's "MUST contain
     EXACTLY these N keys" rules should make these cases
     unambiguous; verify they do.

C.3  **`receipt_version` typing (§M.0).** Verify the
     string-vs-int decision is explicitly justified. Check
     that a v0.4+ author has enough guidance to pick the next
     value (i.e. `"4"`, not `"v4"`, not `4`).

C.4  **CLI flags (§M.3.1).** Verify the four new flags are
     mutually consistent with the v0.2 §10.4.4 flag matrix.
     Specifically: does `--catalog` + `--catalog-pubkey-url`
     work, or is it disallowed? Does `--catalog-pubkey-url` +
     `--coordinator` (v0.2 flag) compose, and which host
     dominates? Does `--json` produce the new fields
     `model_hash_verified` even when `--catalog` was not
     supplied? Audit the matrix exhaustively.

C.5  **Verifier algorithm (§M.3.2).** Verify the 8-step
     algorithm short-circuits cleanly at each failed step and
     names the resulting `result + reason` unambiguously.
     Check that the steps are ordered by failure cost (cheapest
     check first) — if not, surface as MINOR. Specifically:
     should step 5 (expires_at check) run BEFORE step 4
     (signature verify)? Step 4 is expensive (full canonical-
     body reconstruction); step 5 is a clock comparison.

C.6  **Cache TTL (§M.3.4).** Verify the three-band TTL is
     specified completely: what about a catalog with
     `expires_at < now()` (already expired by step 5)? Should
     it cache for negative time? Verify cache-key includes
     enough state to detect rotation of the catalog pubkey
     (the spec names this; verify it's correct).

C.7  **`/poolz` extension (§M.4).** Verify the three new
     top-level fields are JSON-serializable in a way the
     SPEC-002 v1.4 §FR-O2 response generator can produce
     additively. Verify the two new endpoints (`/catalog/...`
     and `/catalog/pubkey`) match the §10.7
     `/v1/receipt-keys/<provider_id>` precedent in HTTP shape,
     auth posture, rate-limit posture, and cache headers.

C.8  **AC test commands (§M.5).** Spot-check each of AC-28
     through AC-42: is the test command reproducible against
     this repo's current code paths? AC-29 names
     `macprovider-cli models inspect` — does that subcommand
     exist? If not, the AC needs to specify an alternative
     introspection route. AC-39 names `Tier2Config.CatalogPath`
     and `/poolz` JSON keys — verify those names are accurate
     against the config + handler code.

C.9  **`X-MacProvider-Receipt` header size (§3.4 v0.3 update).**
     Verify the ≤ 960-byte projection for v0.3 receipts is
     correct given §M.0's 9-field tuple. Specifically: 64-byte
     `model_hash` value + JSON quotes/colon/comma = roughly
     80 bytes; `"receipt_version":"3"` = 22 bytes. Project
     full v0.3 `JCS(T)` upper bound from scratch and compare
     against the spec's claim.

C.10 **Backward-compat path (§M.1.1).** Verify the v0.3
     verifier's legacy-7-field path is identical to a v0.2.4
     verifier's behavior for a v0.2 receipt — i.e. the v0.3
     verifier is a pure superset. Any clause that subtly
     changes back-compat behavior = CRITICAL.

### Lens 2 — SECURITY (cryptographic claims, threat model, trust boundary)

S.1  **Trust boundary §M.3.3.** Verify that "v0.3 `valid` with
     catalog" claim is precisely scoped. Confirm the §10.6
     v0.2 DOES-NOT-PROVE list is preserved except for the
     specific model-name bullet. Any other bullet weakened
     accidentally = CRITICAL.

S.2  **`model_hash: null` semantics (§M.2.3).** This is the
     most contentious §M choice per the BUILD prompt. Verify
     the chosen "valid + skipped + warning" path does NOT let
     a malicious provider opt out of hash attestation
     selectively while still presenting `valid` receipts to
     buyers who would have demanded hash binding. Consider:
     can a provider serve two different models on consecutive
     requests, declare one with `model_hash: null` (warm-swap
     disabled) and the other with a real hash, and have both
     verify? Is there a defence-in-depth check the spec
     should add? If a defence-in-depth check is missing =
     MAJOR.

S.3  **Catalog-pubkey trust root (§M.3.3 + §M.4).** Verify the
     operator-mutability disclaimer is unmissable. The
     §M.3.3 paragraph "v0.3 §M.3.3 strengthens the receipt
     against PROVIDER substitution attacks — it does NOT
     strengthen the receipt against OPERATOR-level attacks"
     is the critical posture statement. Any clause anywhere
     in v0.3 that contradicts this = CRITICAL. Verify
     `--catalog-pubkey-url` (which delegates trust to the same
     coordinator that serves `/poolz`) is positioned as the
     LESS-TRUSTED option vs `--catalog-pubkey` (explicit pin).

S.4  **Mid-swap refusal §M.2.2.** This is the most claim-heavy
     §M.2 clause. Verify the construction proof: under
     SPEC-011 §3.2 + §3.4, does the provider's runtime ALWAYS
     know which container served a given request at receipt-
     emission time? If there's any window where it doesn't —
     e.g. the runtime swaps `Provider.ModelHash` atomically
     but the request was in flight on a goroutine that hadn't
     yet pinned the old container reference — the §M.2.2
     enforceable-by-construction claim is wrong. If so:
     CRITICAL (v0.3 silently demands SPEC-011 amendment).

S.5  **Signature scope (§M.0).** Verify the §3.3 signature
     step covers the new 9-field canonical bytes. Specifically:
     since `model_hash` MAY be `null` (a non-string JSON
     value), does the RFC 8785 §3.2.2.2 encoding produce
     deterministic bytes across implementations? Cross-check
     `RFC8785JCS.swift`'s null handling against a hypothetical
     pure-Go verifier. Any byte-level divergence = CRITICAL.

S.6  **Forward-compat (§M.1.2).** Verify the "v0.1 / v0.2
     verifier reading a v0.3 receipt MUST report `invalid`"
     posture does not introduce a new attack surface. E.g.
     can a malicious provider issue v0.3 receipts to a v0.2
     verifier expecting them to fail open as a fallback? The
     spec says invalid; verify nothing silently downgrades to
     valid.

S.7  **`/poolz` field leakage (§M.4).** Verify the three new
     `/poolz` fields (`catalog_id`, `catalog_url`,
     `catalog_pubkey_url`) do NOT leak operator-sensitive
     info. Specifically: is `catalog_id` (e.g.
     `macprovider-tier2-model-catalog-2026-05-31`)
     operator-private? It currently goes into journald and
     `model_hash_verified` events at coordinator level, but
     §M.4 makes it buyer-visible. Verify this is intentional
     and not a privacy regression.

S.8  **Catalog cache poisoning (§M.3.4).** Verify the cache
     keying scheme (`catalog_url, catalog_pubkey_url_or_explicit_marker`)
     prevents a buyer from being served a stale-good catalog
     against a freshly-rotated pubkey. The spec names this;
     verify the rule fully closes the attack.

S.9  **Streaming + receipts (§M.2.2 + §15 Q5 + §15 Q7).**
     Verify v0.3 doesn't accidentally enable a streaming
     receipt — §6.3 / §12 already say streaming carries no
     receipt; verify §M.2.2 + §M.5 ACs don't contradict that.

S.10 **HARD dependency on SPEC-011 v0.5 + SPEC-008 v0.3.**
     Verify both are in LOCK or LOCK-candidate state and that
     the specific clauses cited (SPEC-011 R-3.3.0, R-3.3.1,
     R-3.3.5, §3.2, §3.4; SPEC-008 §5.3-5.6) exist in those
     specs and say what v0.3 claims they say. Any miscitation
     = CRITICAL.

### Lens 3 — ARCHITECT (cross-spec consistency, evolution arc, deferral hygiene)

A.1  **BUILD prompt directive coverage.** Diff every "What
     v0.3 MUST normatively add" item in the BUILD prompt
     against §M / §M.5. Every MUST in the BUILD prompt MUST
     appear as a normative statement in §M; missing = MAJOR or
     CRITICAL depending on the item. Particularly: did the
     spec address every one of the five "most contentious"
     items the BUILD prompt named?

A.2  **Deferral hygiene (§M.6).** Diff every "What v0.3 MUST
     explicitly defer" item in the BUILD prompt against §M.6
     and §15. Every deferred item MUST appear as an explicit
     non-change with a named successor; missing or inverted =
     MAJOR.

A.3  **Cross-spec invariants.** Verify v0.3 does NOT change
     the line-3 versions of any other SPEC except as
     additive candidate annotations. SPEC-001 / SPEC-002 /
     SPEC-005 / SPEC-006 / SPEC-008 / SPEC-010 / SPEC-011 /
     SPEC-013 line-3 versions MUST be byte-identical to their
     pre-v0.3-branch state. Any inadvertent bump = CRITICAL.

A.4  **Change log v0.3.0 completeness.** Verify the change log
     enumerates every normative change in v0.3. Particularly:
     are §10.6, §11, §15 Q6/Q7, §16 references all called out?
     Missing call-out = MAJOR (audit-doc hygiene).

A.5  **Evolution arc to v0.4+.** Verify the §15 Q7
     (multi-hash streaming receipts) is precisely framed: what
     question does v0.4 need to answer? Verify §M.6 #2/#3
     anchor streaming + multi-hash to Q5 + Q7 respectively, so
     v0.4 has a clean starting point.

A.6  **Entry 80 orthogonality (§M opening note + AC-40).**
     Verify the orthogonality between v0.3 receipt-side hash
     binding and coordinator-side `RequireHashVerified`
     enforcement is unmissable. The opening §M paragraph + §M.6
     #1 + AC-40 are the three locations; verify they are
     mutually consistent.

A.7  **§3.1 / §3.4 / §7.6 / §10.6 / §11 / §15 / §16 edits.**
     Each delta edit on existing locked sections must be
     SCOPED to the version-specific clause it amends. Verify
     the edits do NOT silently widen scope (e.g. amending a
     v0.1 normative clause for both v0.1/v0.2/v0.3 when only
     v0.3 should be affected). A clear failure mode: the §10.6
     bullet supersession says "for v0.3 valid with non-null
     model_hash and catalog" — verify it does not implicitly
     apply to all v0.3 valid results.

A.8  **House voice / RFC 2119.** Spot-check §M for MUST /
     SHOULD / MAY rigor. v0.3 is normative; soft language
     ("might", "could", "may want to") = MINOR.

A.9  **Audit-history coherence.** Verify the lock-state
     blocks (v0.2 preserved + v0.3 candidate) are
     historically accurate. The v0.2 lock state from the
     v0.2.4 release should be preserved verbatim; the v0.3
     candidate should match this PROMPT's audit-loop framing.

A.10 **`feedback-spec-audit-loop-before-pr` / `feedback-bundle-spec-impl-one-pr`
     compliance.** Verify the lock-state block correctly
     invokes the bundle EXCEPTION rule for major version bumps
     with downstream implementers (§M.5 §M.6 + the lock-state
     paragraph). The BUILD prompt's §"Final deliverables"
     also requires a staged IMPL prompt; the spec should
     reference it as a forward-link.

## Codex CLI invocation (round 1)

If you are running this prompt in the Codex CLI:

```
codex exec \
  --model claude-opus-4-7 \
  --system "$(cat <<'SYS'
You are an independent senior-level technical auditor for SPEC-015 v0.3
of the MacProvider verifiable-inference protocol. Use the lens, scope,
severity, and constraint rules supplied in the user prompt. Output is a
structured Markdown audit report — no diff, no fixes, no extension of
the spec. Read the cited files; do not invent line numbers.
SYS
)" \
  -p - <<'PROMPT'
<paste the entire === BEGIN PROMPT === ... === END PROMPT === block here>
PROMPT
```

Run three sequential invocations, one per lens, writing each to a
fresh section in `specs/SPEC-015-v0-3-audit.md`. After all three,
compute the rollup verdict:

- If any lens returned **DESIGN ROUND NEEDED** → spec needs a
  substantive rewrite; bump line 3 from `0.3.0` to `0.3.1` and
  re-run.
- If any lens returned **READY WITH FIX PASS** and others
  READY TO LOCK → bump to `0.3.1` (or `0.3.x+1`), apply fixes,
  re-run only the FIX-PASS lenses.
- If ALL three lenses returned **READY TO LOCK** → v0.3.x is the
  LOCK candidate. Proceed to push + PR per `feedback-spec-audit-loop-before-pr`.

## What MUST be in every audit report

Each finding MUST cite:

- The spec section number (e.g. `§M.3.2 step 6`).
- The approximate line range in `specs/SPEC-015-receipts.md`.
- The severity (CRITICAL / MAJOR / MINOR / QUESTION).
- A one-sentence statement of the problem.
- A one-paragraph elaboration with cross-references to the
  supporting files (the BUILD prompt, SPEC-011 / SPEC-008,
  catalog source files) so the operator can verify.
- A suggested resolution direction (NOT a written fix; pointer
  at most). The operator picks the fix.

Each lens section ends with the VERDICT line and the COUNTS
line described above.

=== END PROMPT ===
```

---

## Operator workflow per round

1. Run the three Codex sessions (code → security → architect).
2. Each Codex run appends a `## Lens N — <name> — Codex round R` section to `specs/SPEC-015-v0-3-audit.md` with findings, VERDICT, and COUNTS.
3. Operator reads the rollup. If READY TO LOCK across all three lenses on round R, stop — v0.3.x is the LOCK candidate.
4. If FIX PASS or DESIGN ROUND NEEDED: pick the lens with the strictest verdict, decide the fix, apply to `specs/SPEC-015-receipts.md`, bump line 3 from `v0.3.x` to `v0.3.x+1`, append a `**Change log v0.3.x+1:**` block citing the audit-round findings resolved, re-run all three lenses.
5. Loop until 0 CRITICAL + 0 MAJOR across all three lenses on a single round.

Expected round count: 3-5. v0.3 is a wire-shape change; expect Round 1 to surface 5-10 findings concentrated on the four BUILD-prompt-named contention points (`receipt_version`, null-hash, §M.2.2, catalog trust root).

## When the loop closes

- Push `spec/015-receipts-v0-3` to origin.
- Open a PR pointing at the v0.3 SPEC delta, this audit prompt, the audit transcript, and the staged `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md`.
- Append a `beta/DECISION_CRITERIA.md` entry per the BUILD prompt's "Final deliverables" §"appended entry".
- The IMPL PR opens in a separate session per the [[feedback-bundle-spec-impl-one-pr]] major-bump exception rule.
