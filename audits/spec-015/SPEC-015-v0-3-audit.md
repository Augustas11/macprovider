# SPEC-015 v0.3 audit — round 1 (Codex)

Scope: v0.3 deltas only, centered on §M and the named pointer edits. v0.1.x and v0.2 locked content was treated as fixed unless a v0.3 clause reached back into it.

## Lens 1 — CODE

### Catalog parser / verifier compatibility

#### C1. CRITICAL — Catalog signature algorithm casing rejects the existing catalog format

**Location:** §M.3.2 step 4, lines 2728-2744; AC-35, lines 3056-3061.

**Problem:** v0.3 requires `signature.alg` to be `"ed25519"`, but the existing signing and parsing code emits and accepts `"Ed25519"`.

**Elaboration:** `scripts/sign-catalog.go` writes `Alg: "Ed25519"` at lines 142-145 and validates that exact value at lines 281-284. `phase4-coordinator/internal/tier2/catalog.go` likewise requires `file.Signature.Alg != "Ed25519"` to fail at lines 470-472. A verifier implemented literally from §M.3.2 would reject every catalog produced by the existing tool, making catalog-backed v0.3 valid receipts unreachable. This is a v0.3 delta/code contract mismatch, not an implementation guess.

**Suggested resolution direction:** Align §M.3.2 and AC-35 with the existing `"Ed25519"` wire value, or explicitly state a backwards-compatible accept-both rule with one canonical emitted value.

#### C2. CRITICAL — `--catalog-pubkey` encoding conflicts with the existing catalog key format

**Location:** §M.3.1 flag table, lines 2673-2678; §M.4 pubkey endpoint, lines 2895-2899.

**Problem:** The spec requires standard padded base64, 44 ASCII chars, for the catalog pubkey, while existing catalog tooling and SPEC-008 use base64url-unpadded.

**Elaboration:** `scripts/sign-catalog.go keygen` writes the public key with `base64.RawURLEncoding` at line 90, and `readPublicKey` decodes it with `base64.RawURLEncoding` at lines 316-328. `phase4-coordinator/internal/tier2/catalog.go` decodes `CatalogPublicKey` the same way at lines 479-485. SPEC-008 §5.2.1 also names Ed25519 pubkeys as base64url-unpadded at lines 664-678. A literal v0.3 verifier would reject the key file produced by the tool v0.3 tells buyers to use.

**Suggested resolution direction:** Make `--catalog-pubkey` and `GET /catalog/pubkey` use base64url-unpadded, and pin the expected 43-character Ed25519 public-key encoding unless the operator intentionally wants a new incompatible format.

### CLI / output contract

#### C3. MAJOR — New catalog flags are not integrated into the normative §10.4.4 matrix

**Location:** §10.4.4, lines 2085-2125; §M.3.1, lines 2680-2705.

**Problem:** §M.3.1 gives partial catalog-flag rules but does not actually extend the v0.2 flag interaction matrix that §10.4.4 says must be extended for new interacting flags.

**Elaboration:** The spec leaves combinations such as `--catalog-url + --catalog-pubkey-url + --coordinator H`, `--catalog + --catalog-pubkey-url`, `--json` with skipped catalog checks, and explicit `--pubkey` plus catalog-backed verification to inference. This reopens the same kind of CLI contract ambiguity that v0.2 CF5/CF7/CF8 closed around `--provider-id`.

**Suggested resolution direction:** Add a v0.3 matrix or explicit sub-matrix covering all catalog flags against `--offline`, `--coordinator`, `--pubkey`, `--json`, input modes, and missing provider-id cases.

#### C4. MAJOR — v0.3 JSON fields conflict with the locked §10.4.2 schema

**Location:** §10.4.2, lines 1982-2005; §M.1.4, lines 2481-2486; §M.3.2 step 6, lines 2761-2763; §M.3.1, lines 2682-2686.

**Problem:** §M uses `details` on `inconclusive` results and adds `model_hash_verified`, but §10.4.2 still says `details` is required only when invalid and absent otherwise, and its top-level field table does not include `model_hash_verified`.

**Elaboration:** Unknown receipt versions place `details.receipt_version` on an `inconclusive` result, and unknown catalog model IDs place `details.model_id` on an `inconclusive` result. That contradicts the existing result schema. Separately, §M.3.1 requires `model_hash_verified: null` when the catalog check is skipped, but the changelog says it is a bool present iff catalog was supplied and model hash was non-null. Two conforming verifier authors could emit different JSON for the same receipt.

**Suggested resolution direction:** Add a v0.3 result-schema amendment that explicitly updates top-level fields, `details` disposition for named inconclusive cases, and the exact tri-state type of `model_hash_verified`.

### Coordinator surface

#### C5. MAJOR — `/poolz` additive example uses the wrong existing top-level key

**Location:** §M.4, lines 2875-2883.

**Problem:** The v0.3 `/poolz` example says `"providers": [...]` is unchanged, but SPEC-002 v1.4 FR-O2 uses `"pool": [...]`.

**Elaboration:** SPEC-002 FR-O2’s response shape is anchored at lines 1322-1350 and names the provider array `pool`, not `providers`. Because §M.4 is a SPEC-002 v1.6 candidate annotation, copying the v0.3 example literally would create a non-additive response-shape change instead of adding only `catalog_id`, `catalog_url`, and `catalog_pubkey_url`.

**Suggested resolution direction:** Correct the example to preserve `"pool"` and `"summary"` and add only the three catalog fields at top level.

#### C6. MAJOR — AC-29 depends on an introspection command that does not exist

**Location:** §M.5 AC-29, lines 2991-3002.

**Problem:** AC-29 cites `macprovider-cli models inspect <model_id>` as an introspection route, but the current CLI and SPEC-011/SPEC-001 inventories only define `models list`, `models switch`, `models status`, and `models browse`.

**Elaboration:** Required reading asked for AC commands to be reproducible against current code paths. `rg` finds no `models inspect` subcommand in `phase3-binary/Sources/macprovider-cli`, SPEC-011 §3.1 lists only `list/switch/status`, and SPEC-001 v1.4 adds `browse`, not `inspect`. The alternate "heartbeat-reported hash" route is plausible, but the AC does not pin a concrete command or fixture for that path.

**Suggested resolution direction:** Replace the non-existent example with a concrete current observation route, or make the new introspection surface an explicit implementation requirement.

### Numeric / cache boundaries

#### C7. MINOR — The v0.3 header-size projection omits the signature segment

**Location:** §3.4, lines 941-946.

**Problem:** The `≤ ~960 ASCII bytes` header estimate appears to count `base64(JCS(T))` but not the literal period plus the 64-byte signature’s base64 segment.

**Elaboration:** A 700-byte JCS tuple base64-encodes to about 936 bytes; adding `.` plus standard padded base64 of a 64-byte Ed25519 signature adds 89 more bytes, yielding about 1025 bytes. This still fits the 4096-byte requirement, but the stated envelope is numerically low.

**Suggested resolution direction:** Recompute the envelope from `<base64(JCS(T))>.<base64(SIG)>` and update the displayed ceiling.

#### C8. MINOR — Cache TTL boundary language leaves exact boundary cases implicit

**Location:** §M.3.4, lines 2838-2849.

**Problem:** The cache TTL bands use `> 6h`, "between 60 seconds and 6 hours", and `< 60s`, leaving exact handling of `expires_at - now() == 6h` and the interaction with already-expired-but-within-skew catalogs to inference.

**Elaboration:** §M.3.2 step 5 allows a 60-second skew grace before `catalog_expired`, while §M.3.4 says catalogs with less than 60 seconds remaining are not cached. That is likely intended, but exact boundary wording matters for deterministic cache tests.

**Suggested resolution direction:** Use explicit interval notation for the three TTL bands and state that catalogs accepted only by skew grace are never cached.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=2 MAJOR=4 MINOR=2 QUESTION=0

## Lens 2 — SECURITY

### Cross-spec trust semantics

#### S1. CRITICAL — AC-40 contradicts SPEC-008 by allowing `hash_mismatch` providers to route at the default flag setting

**Location:** §M.5 AC-40, lines 3108-3122.

**Problem:** AC-40 says a coordinator with `RequireHashVerified: false` must continue routing to providers whose hash status is `mismatch`, but SPEC-008 says `hash_mismatch` and `hash_invalid` are excluded even when the flag is false.

**Elaboration:** SPEC-008 §5.6 states that when `tier2.require_hash_verified: false`, only `uncatalogued` and `catalog_unavailable` are permissive, while `hash_mismatch` and `hash_invalid` remain excluded because the coordinator has positive evidence of false identity (lines 746-760). The current code matches that through `IsHashPredicateFailure`, which always fails mismatch/invalid at `catalog.go:599-604`. AC-40 silently demands a SPEC-008 amendment and conflicts with Entry 80, whose deferral keeps the strict flag off but does not make known-bad hashes routable.

**Suggested resolution direction:** Scope AC-40 to `uncatalogued` or catalog-unavailable providers, and state that `hash_mismatch` remains excluded per SPEC-008 regardless of `RequireHashVerified`.

### Null-hash attestation

#### S2. MAJOR — `model_hash: null` has no built-in buyer policy knob for "catalog required"

**Location:** §M.2.3, lines 2619-2657; AC-32, lines 3028-3038.

**Problem:** A buyer who supplies catalog flags still receives `valid` for a null-hash receipt, with only a warning and `model_hash_verified: null`.

**Elaboration:** The BUILD prompt correctly called null-hash behavior one of the contentious choices. The chosen protocol preserves signature verification for default warm-swap-disabled providers, but it also means a buyer cannot express "I require hash attestation" through the v0.3 CLI itself. The spec punts that policy to a deployment-specific wrapper, which is likely to produce inconsistent buyer behavior and weakens defense in depth against selective non-participation.

**Suggested resolution direction:** Consider a first-class verifier policy flag or output contract that lets buyers fail closed on `model_hash: null` without changing the base tri-state semantics for default invocations.

### Mid-swap enforcement

#### S3. MAJOR — AC-42 suppresses legitimate old-container receipts during SPEC-011 loading/draining

**Location:** §M.2.2, lines 2561-2598; AC-42, lines 3133-3143.

**Problem:** §M.2.2 says an in-flight request that began on the old container emits a receipt with the request-start hash, but AC-42 says any provider in `loading` or `draining` at receipt-emission time must not emit a receipt.

**Elaboration:** SPEC-011 §3.2 requires inference methods to snapshot `current_container` at request start and use that reference for the full request lifetime (lines 595-599). During `loading` and `draining`, old-container in-flight requests continue while new requests are rejected (lines 605-620). AC-42 drops §M.2.2’s "cannot disambiguate" qualifier and would turn a normal SPEC-011 in-flight request into a receipt omission. That makes the acceptance test contradict the construction proof.

**Suggested resolution direction:** Rewrite AC-42 around the unreachable/defense-in-depth case: only omit when the runtime cannot identify the request-start container/hash, not merely because global state is `loading` or `draining`.

### Catalog publication surface

#### S4. MINOR — §M.4 "configured" wording can expose catalog URLs before a catalog is verified

**Location:** §M.4, lines 2869-2873 and 2901-2905; AC-39, lines 3093-3106.

**Problem:** §M.4 says catalog fields are present iff `Tier2Config.CatalogPath` is configured, while AC-39 says they are present only after a catalog is successfully loaded and verified.

**Elaboration:** The safer rule is AC-39’s "effectively configured" posture. If an implementation follows the earlier "CatalogPath configured" sentence literally, `/poolz` can advertise a catalog URL/pubkey URL for a catalog that failed parse or signature verification. That is not a direct false-valid path because the verifier still checks the catalog signature, but it weakens operational clarity and can push buyers into predictable `catalog_unreachable` or `catalog_format_invalid` states.

**Suggested resolution direction:** Make §M.4 use AC-39’s loaded-and-verified condition everywhere.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=1 MAJOR=2 MINOR=1 QUESTION=0

## Lens 3 — ARCHITECT

### Buyer-side vs coordinator-side hash semantics

#### A1. MAJOR — Buyer-side catalog lookup is case-sensitive while coordinator-side lookup is case-folded

**Location:** §M.3.2 step 6, lines 2754-2764.

**Problem:** v0.3 verifier lookup requires exact case-sensitive `model_id` equality, but the existing coordinator catalog path lowercases model IDs before lookup.

**Elaboration:** `phase4-coordinator/internal/tier2/catalog.go` lowercases catalog keys with `catalogModelKey` at lines 559-560 and uses that key in `VerifyProviderHash` at lines 302-304. This means the coordinator-side SPEC-008 check can resolve a case variant that the buyer-side v0.3 verifier would report as `inconclusive: model_id_not_in_catalog`. The audit prompt explicitly requires the buyer-side verifier to mirror the coordinator-side check.

**Suggested resolution direction:** Decide one canonical matching rule and align §M.3.2 with the existing SPEC-008/catalog implementation, or explicitly document why buyer-side verification is intentionally stricter and how operators avoid divergence.

### Candidate annotation hygiene

#### A2. MAJOR — `/poolz` catalog-field presence condition is internally inconsistent

**Location:** §M.4, lines 2869-2873 and 2901-2905; AC-39, lines 3093-3106.

**Problem:** The prose says fields are present when a catalog path is configured; the AC says fields are omitted if the configured catalog fails to load, parse, or verify.

**Elaboration:** This is the same ambiguity surfaced in the security lens, but architecturally it matters because §M.4 is the SPEC-002 v1.6 candidate source of truth until SPEC-002 locks the shape. Candidate annotations should be additive and unambiguous. A future SPEC-002 absorption should not have to choose between two SPEC-015 meanings.

**Suggested resolution direction:** Promote "successfully loaded and verified active catalog" to the single condition for all three fields and the two endpoint 404 cases.

#### A3. MAJOR — The staged implementation prompt referenced by the lock-state block is absent

**Location:** Lock state v0.3, line 6; BUILD prompt final deliverables, lines 155-168 and 176-182.

**Problem:** The spec says `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` is staged for the next session, but that file is not present in the repo.

**Elaboration:** The BUILD prompt requires the implementation BUILD prompt as a final deliverable after spec lock, and the SPEC lock-state paragraph uses it as evidence for the bundle-exception workflow. Referencing a non-existent staged artifact weakens the audit-loop handoff and can strand downstream implementation planning.

**Suggested resolution direction:** Either stage the implementation prompt before lock or change the lock-state wording to say it is a required follow-up, not already staged.

### Dependency / audit-history coherence

#### A4. QUESTION — SPEC-011 v0.5 is decision-locked but its spec header still says draft / lock-candidate

**Location:** SPEC-015 depends-on line 4; SPEC-011 header lines 3-5; DECISION_CRITERIA Entry 55.

**Problem:** SPEC-015 v0.3 promotes SPEC-011 v0.5 as a hard dependency, and Entry 55 records SPEC-011 v0.5 as locked, but `SPEC-011-operator-pushed-warm-swap.md` itself still says `Status: Draft (pre round-4 LOCK-confirmation audit)`.

**Elaboration:** This may be stale header metadata rather than a SPEC-015 problem. Still, because §M.2.2’s enforceability rests on SPEC-011 §3.2/§3.4, the operator should decide whether the dependency source file needs a header polish before SPEC-015 v0.3 locks against it.

**Suggested resolution direction:** Confirm whether Entry 55 or the SPEC-011 file header is authoritative, then normalize the stale header in the appropriate spec if needed.

### Audit-loop documentation

#### A5. MINOR — v0.3 additional references cite stale SPEC-011 sections in the inherited reference list

**Location:** §16.2, lines 3655-3658 and 3695-3704.

**Problem:** The older reference bullet still cites SPEC-011 §3.8 for warm-swap drain, while the v0.3 additional references correctly cite §3.2, §3.3, and §3.4.

**Elaboration:** The v0.3 deltas themselves cite the right enforceability sections, so this is not a blocker. But stale reference bullets are exactly the kind of audit-history drift that caused v0.2 CF4-style confusion around old `/poolz` wording.

**Suggested resolution direction:** Update or qualify the inherited §16.2 bullet so all SPEC-011 references for v0.3 point at §3.2/§3.3/§3.4.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 MAJOR=3 MINOR=1 QUESTION=1

## Lens 1 — CODE — Round 2

### Round-1 Closure Check

Round 2 audited SPEC-015 v0.3.1, starting with the `Change log v0.3.1` block. C1, C2, C3, C4, C5, C6, C7, and C8 are substantively closed in the controlling §M.3 / §M.5 / §3.4 clauses: catalog signatures use `signature.alg = "Ed25519"`; catalog pubkeys use 43-character `base64.RawURLEncoding`; the v0.3 catalog flag matrix and JSON result schema are present; `/poolz` preserves `pool` / `summary`; AC-29 no longer names a nonexistent `models inspect` command; the header-size projection now includes the signature segment; and TTL boundary language is explicit.

### Catalog Pubkey Endpoint Shape

#### C9. MAJOR — §M.4 still contains the old 44-char/lowercase pubkey response in the field-definition paragraph

**Location:** §M.4 `catalog_pubkey_url` field definition, lines 3260-3264; §M.4 `GET /catalog/pubkey` detailed endpoint, lines 3292-3305; v0.3.1 changelog C2, lines 24-33.

**Problem:** The detailed endpoint block correctly requires `{"pubkey": "<43-char base64url-unpadded>", "alg": "Ed25519"}`, but the earlier normative field-definition paragraph still says the same endpoint returns `{"pubkey": "<44-char base64 ed25519 pubkey>", "alg": "ed25519"}`.

**Elaboration:** This is the same wire surface round-1 C2 fixed. `scripts/sign-catalog.go:90` emits catalog public keys with `base64.RawURLEncoding`; `scripts/sign-catalog.go:142-145` emits `signature.alg = "Ed25519"`; `scripts/sign-catalog.go:316-328` and `phase4-coordinator/internal/tier2/catalog.go:470,479-485` validate those exact encodings. SPEC-008 §5.2.1 also pins Ed25519 catalog pubkeys as base64url-unpadded. A coordinator implementer reading §M.4 top-down could implement the stale 44-char/lowercase shape while a verifier implementer follows §M.3.1 / §M.3.2 / the detailed endpoint block and rejects it. That is not a false-valid path, but it is a predictable interop split on the buyer-facing catalog-pubkey URL.

**Suggested resolution direction:** Make the §M.4 `catalog_pubkey_url` field-definition paragraph match the detailed endpoint block: 43-character base64url-unpadded pubkey and capital-E `"Ed25519"`.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 MAJOR=1 MINOR=0 QUESTION=0

## Lens 2 — SECURITY — Round 2

### Round-1 Closure Check

Round 2 found the round-1 security findings closed in the controlling SPEC-015 v0.3.1 text. S1 is closed by AC-40 lines 3522-3549, which preserves SPEC-008 §5.6 / `catalog.go:599-604`: `hash_mismatch` and `hash_invalid` fail closed even when `RequireHashVerified` is false. S2 is closed by §M.3.1.2 lines 2909-2950 and AC-32a lines 3435-3448, which add an opt-in buyer fail-closed policy for null hashes. S3 is closed by §M.2.2 lines 2715-2762 and AC-42 lines 3560-3582, which distinguish normal old-container in-flight receipts from the unreachable defence-in-depth omission path. S4 is closed by §M.4 lines 3218-3236 and AC-39 lines 3507-3520, which use a single loaded+verified active-catalog condition.

### Security Sweep

No new security findings. §M.3.3 lines 3131-3173 preserves the v0.2 §10.6 does-not-prove list except for the specifically superseded model-name/hash claim, and keeps `--catalog-pubkey-url` visibly weaker than an out-of-band `--catalog-pubkey` pin. `inconclusive` remains first-class for unknown versions, expired catalogs, catalog unreachability, and unknown catalog model IDs; null-hash receipts remain valid only for signature/prompt/output attestation unless the buyer sets `--require-model-hash`. SPEC-011 §3.2 / §3.4 provide the request-start container snapshot and drain semantics §M.2.2 relies on, and SPEC-008 §5.3-5.6 remains consistent with the buyer-side catalog check after v0.3.1's case-folding fix.

VERDICT: READY TO LOCK

COUNTS: CRITICAL=0 MAJOR=0 MINOR=0 QUESTION=0

## Lens 3 — ARCHITECT — Round 2

### Round-1 Closure Check

Round 2 found A1, A2, A4, and A5 closed in the controlling SPEC-015 text. §M.3.2 step 6 now mirrors `catalogModelKey` with lowercase + trim; §M.4 uses the loaded+verified active-catalog rule consistently; the SPEC-011 stale-header question remains correctly treated as out-of-scope for SPEC-015; and §16.2 now cites SPEC-011 §3.2 / §3.3 / §3.4. A3 is closed only in the narrow existence sense: `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` now exists and is referenced from §16.2, but its contents have not been fully updated to v0.3.1.

### Implementation Handoff Hygiene

#### A6. MAJOR — The staged IMPL prompt still carries stale v0.3.0 instructions that contradict v0.3.1 fixes

**Location:** SPEC-015 lock-state forward link, lines 5-6; §16.2 forward reference, lines 4153-4156; staged IMPL prompt lines 139-152 and 209-224.

**Problem:** The spec now references the staged implementation prompt as the next-session handoff, but that prompt still instructs implementers to use stale pre-fix behavior on catalog pubkey encoding, catalog signature algorithm casing, and catalog model lookup.

**Elaboration:** SPEC-015 v0.3.1's controlling clauses require `/catalog/pubkey` to return a 43-character base64url-unpadded pubkey with `"Ed25519"` (§M.4 lines 3292-3305), and require buyer-side catalog lookup to mirror `catalogModelKey` with lowercase + trim (§M.3.2 lines 3008-3027). The staged IMPL prompt still says `GET /catalog/pubkey` returns `{"pubkey": "<44-base64>", "alg": "ed25519"}` at line 152, asks catalog verification to reject `signature.alg != "ed25519"` at line 224, and asks `Lookup` to use exact-case string match at line 210. Those instructions would reintroduce round-1 C1/C2/A1 in the downstream implementation session, despite the SPEC text mostly fixing them. Because the lock-state paragraph and §16.2 use the prompt as a staged forward-link, this is an audit-loop handoff defect rather than just a private note.

**Suggested resolution direction:** Refresh `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` from the v0.3.1 controlling clauses before lock/PR: 43-char base64url-unpadded catalog pubkey, capital-E `"Ed25519"`, case-folded/trimmed catalog lookup, and the active-catalog field-presence rule.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 MAJOR=1 MINOR=0 QUESTION=0

## Lens 1 — CODE — Round 3

### Round-2 Closure Check

Round 3 audited SPEC-015 v0.3.2, starting with the `Change log v0.3.2` block. The single round-2 CODE finding, C9, is closed in the controlling §M.4 text: the `catalog_pubkey_url` field paragraph now says `GET /catalog/pubkey` returns `{"pubkey": "<43-char base64url-unpadded ed25519 pubkey>", "alg": "Ed25519"}` at §M.4 lines 3294-3302, matching the detailed endpoint block at lines 3330-3343. That shape matches `scripts/sign-catalog.go:90` (`base64.RawURLEncoding` public key), `scripts/sign-catalog.go:142-145` (`signature.alg = "Ed25519"` and RawURLEncoding signature), and `phase4-coordinator/internal/tier2/catalog.go:470,479-485` (capital-E alg and RawURLEncoding pubkey validation).

### Regression Sweep

No new CODE findings. The v0.3.2 edits did not disturb the 9-field tuple, version detection, JSON result schema, catalog algorithm, cache rules, or backward-compat path. The header-size correction remains at §3.4 lines 1124-1136 with the signature segment included (`~936 + 1 + 88 = ~1025` bytes), and §M.3.2 still reconstructs the catalog canonical body in the `catalog_id`, `expires_at`, `issued_at`, `models`, `version` order produced by `scripts/sign-catalog.go:44-49`.

VERDICT: READY TO LOCK

COUNTS: CRITICAL=0 MAJOR=0 MINOR=0 QUESTION=0

## Lens 2 — SECURITY — Round 3

### Round-2 Closure Check

Round 2 had no open SECURITY findings, and the v0.3.2 changes do not alter the security-critical semantics. §M.3.3 lines 3165-3207 still scopes catalog-backed `valid` narrowly to non-null `model_hash` plus a fresh signature-valid catalog, preserves the remaining §10.6 DOES-NOT-PROVE bullets, and keeps `--catalog-pubkey-url` visibly weaker than an out-of-band `--catalog-pubkey` pin.

### Regression Sweep

No new SECURITY findings. `inconclusive` remains first-class for unknown receipt versions (§M.1.4 lines 2664-2683), unreachable / expired catalogs (§M.3.2 lines 2992-2997 and 3033-3041), and unknown catalog model IDs (§M.3.2 lines 3042-3061). The null-hash path retains the default valid-for-signature posture (§M.2.3 lines 2809-2833) while preserving the buyer fail-closed option through `--require-model-hash` (§M.3.1.2 lines 2943-2984 and AC-32a lines 3473-3486). SPEC-011 still supplies the request-start snapshot and drain construction (§3.2 R-3.2.2 lines 595-599; §3.4 R-3.4.1/R-3.4.2/R-3.4.4 lines 792-835), and SPEC-008 §5.6 still fail-closes `hash_mismatch` / `hash_invalid` at both `RequireHashVerified` settings.

VERDICT: READY TO LOCK

COUNTS: CRITICAL=0 MAJOR=0 MINOR=0 QUESTION=0

## Lens 3 — ARCHITECT — Round 3

### Round-2 Closure Check

The round-2 ARCHITECT finding A6 is closed at the MAJOR level. The staged IMPL prompt now matches the controlling v0.3.2 clauses for the previously stale behaviours: Step 2 uses the 43-character base64url-unpadded + capital-E `Ed25519` `/catalog/pubkey` shape at `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md` lines 150-153; Step 4 uses `base64.RawURLEncoding`, capital-E `Ed25519`, and `catalogModelKey` lowercase+trim lookup at lines 207-210 and 223-224; Step 5 now enumerates FIVE CLI flags including `--require-model-hash` and points result schema semantics at §M.3.2.1 at lines 250-260. These changes align with §M.3.1.2 lines 2943-2984, §M.3.2 lines 3008-3045, and §M.4 lines 3330-3343.

### Implementation Handoff Hygiene

#### A6-R3. MINOR — The IMPL prompt still has two stale "four new flags" summary/done-condition mentions

**Location:** §M.3.1.2 lines 2943-2984; §M.5 AC-32a lines 3473-3486; staged IMPL prompt lines 29 and 286.

**Problem:** The controlling SPEC and the detailed Step 5 IMPL instructions require FIVE verifier flags including `--require-model-hash`, but two non-controlling IMPL-prompt summary/checklist sentences still say "four new flags."

**Elaboration:** This does not reopen round-2 A6 as a MAJOR because the binding Step 5 instructions now say `internal/cli/` is extended with FIVE new flags and explicitly list `--require-model-hash` (`BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:250-255`), and the Step 5 tests require AC-32a (`:269-271`). The SPEC itself is also clear: §M.3.1.2 defines the flag and AC-32a requires the fail-closed null-hash result. The remaining stale wording is in the top-level verifier-extension summary at line 29 and the final help-output done condition at line 286. An implementer following the detailed step and ACs will still implement the right surface, but the stale summary is avoidable handoff friction.

**Suggested resolution direction:** In a cleanup pass before or during the implementation-session prompt handoff, change both stale mentions to "five new flags" and make the help-output check require `--require-model-hash` explicitly.

### Architecture Sweep

No CRITICAL or MAJOR architect findings. Entry 80 orthogonality is unmissable across the §M opening note (lines 2551-2560), §M.6 #1 (lines 3627-3634), AC-40 (lines 3560-3587), and §15 Q6 (lines 4059-4073). The v0.3.2 change log enumerates both round-2 fixes at lines 10-42, §M.6 continues to defer streaming, multi-hash receipts, federation, quantization variants, and TUF/on-chain catalog roots, and §16.2 retains the staged IMPL prompt forward-link.

VERDICT: READY TO LOCK

COUNTS: CRITICAL=0 MAJOR=0 MINOR=1 QUESTION=0
