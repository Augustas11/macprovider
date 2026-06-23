# SPEC-015 v0.2 audit report

Scope: SPEC-015 v0.2 deltas only, per `specs/AUDIT_SPEC_015_V0_2_PROMPT.md`. v0.1.x normative content is treated as locked.

Required-source pass covered SPEC-015 v0.2, the v0.2 BUILD prompt, the v0.1 audit history, README lines 1-137, SPEC-006 buyer API receipt/header surfaces, SPEC-002 `/poolz` receipt-key absorption, SPEC-013 CLI style, `RFC8785JCS.swift`, and DECISION_CRITERIA entries 79-82 context where present in the file.

## Lens: code - round 1 by Codex

**Verdict:** DESIGN ROUND NEEDED

**Counts:** 2 CRITICAL, 3 MAJOR, 1 MINOR, 0 QUESTIONS

### CRITICAL findings

#### C1. Bundle mode rejects ordinary OpenAI request captures
**Location:** §10.4.1 lines 1439-1441; SPEC-006 §5.4 lines 1024-1048

**Finding:** The bundle contract says `request` is the OpenAI request body "as sent" but also says it "Must contain at least the 16 fields the §4.2 canonical prompt object reads from." Ordinary OpenAI SDK calls commonly send only required fields such as `model` and `messages`; SPEC-006 lists many supported fields as optional, and locked SPEC-015 §4.2 already says absent fields canonicalize as JSON `null`.

**Why it matters:** A conforming verifier that enforces this text will reject valid receipts from normal buyer captures whose request omitted optional fields. That is verifier-side rejection of valid receipts and directly conflicts with the BUILD prompt's bundle-mode requirement that the bundle contain the prompt exactly as the buyer holds it.

**Suggested fix:** Define `request` as the raw OpenAI request object as sent by the buyer. Require only the OpenAI-required fields needed to reconstruct §4.2, and state that absent §4.2 optional fields are treated as `null` per the locked canonicalization rule.

#### C2. Default live pubkey lookup has no buyer-callable API contract
**Location:** §10.2 lines 1341-1346; §10.5 lines 1527-1533; SPEC-002 FR-O2 lines 1316-1319

**Finding:** The CLI contract requires a live `/poolz` lookup by default, but locked SPEC-002 makes `/poolz` operator-only and bearer-authenticated. §10 does not define how a buyer verifier obtains that credential, which public endpoint it should call instead, or how a failure due to missing operator auth differs from ordinary network unreachability.

**Why it matters:** A conforming implementation cannot build the default online verification path from the named APIs. It will either return `inconclusive` for valid receipts, prompt buyers for operator credentials, or invent an endpoint outside the spec.

**Suggested fix:** Add a buyer-callable pubkey-resolution contract or make the v0.2 CLI require explicit/cached pubkeys until that contract exists.

### MAJOR findings

#### C3. JSON output schema is examples, not a complete contract
**Location:** §10.2 lines 1348-1353; §10.4.2 lines 1456-1490

**Finding:** `--json` specifies examples for `valid` and `invalid`, but not a complete schema for all results. It does not state required-vs-optional fields for `inconclusive`, does not define whether `reason` is free text or an enum, does not define `details.field` values beyond examples, and has no place for the explicit-vs-live divergence warning that §10.2 requires in non-quiet modes.

**Why it matters:** Two conforming implementations can produce incompatible JSON for the same result, especially for `inconclusive` or for explicit pubkey/live `/poolz` divergence. Scripts cannot reliably parse the v0.2 verifier surface.

**Suggested fix:** Add a normative field table or JSON Schema for `valid`, `invalid`, and `inconclusive`, including required/optional fields, enum values, and a warning field or explicit rule for where JSON-mode warnings go.

#### C4. `bundle_version` exit-code mapping contradicts itself
**Location:** §10.4.1 lines 1433-1435; §10.4.3 lines 1510-1511; AC-25 lines 1841-1846

**Finding:** §10.4.1 says any `bundle_version` other than `1` is a usage error with exit `64`. §10.4.3 says `65` is for input format errors and includes malformed input classes. AC-25 then says `bundle_version: 99` is an example that reaches exit `65`.

**Why it matters:** Exit codes are explicitly normative and script-facing. This contradiction means an implementer and a CI script can both claim conformance while disagreeing on the same invalid bundle.

**Suggested fix:** Pick one classification for unsupported `bundle_version` and make §10.4.1, §10.4.3, and AC-25 match exactly.

#### C5. Flag interaction semantics are under-specified
**Location:** §10.2 lines 1348-1358; §10.4 lines 1407-1419; §10.5 lines 1520-1539; AC-23 lines 1829-1833

**Finding:** The spec names `--offline`, `--quiet`, `--coordinator`, `MACPROVIDER_COORDINATOR`, `--pubkey`, `--json`, and `--explain`, but not their full interaction matrix. Examples: `--offline` is only tested with `--pubkey`, but §10.5 also tells buyers to pre-populate cache and run `--offline`; `--quiet` suppresses the live divergence check required by §10.2 but has no output/exit semantics; non-default coordinators are not reflected in output beyond `trust_source: "poolz_live"`.

**Why it matters:** These are exactly the paths automation and offline verification will use. Undefined combinations produce predictable implementation drift and make buyer scripts brittle.

**Suggested fix:** Add a compact flag matrix covering network access, cache use, warning emission, stdout/stderr behavior, and exit behavior for each relevant combination.

### MINOR findings

#### C6. Bundle `receipt` placeholder misnames the wire value
**Location:** §10.4.1 lines 1423-1438

**Finding:** The JSON example says `"receipt": "<base64 receipt header value>"`, but the locked wire value is `<base64(JCS(T))>.<base64(SIG)>`, not one base64 blob. The bullet below correctly says "verbatim value of the `X-MacProvider-Receipt` response header"; the placeholder should match that wording.

### QUESTIONS

None.

## Lens: security - round 1 by Codex

**Verdict:** DESIGN ROUND NEEDED

**Counts:** 3 CRITICAL, 2 MAJOR, 0 MINOR, 0 QUESTIONS

### CRITICAL findings

#### S1. Live `/poolz` trust root is buyer-inaccessible as specified
**Location:** §10.2 lines 1341-1346; §10.5 lines 1527-1533; SPEC-002 FR-O2 lines 1316-1319 and 1370; SPEC-002 GET `/poolz` lines 2362-2369

**Finding:** v0.2 makes a live `/poolz` fetch from the configured coordinator the third and default pubkey-resolution source, but locked SPEC-002 says `GET /poolz` is operator-only and requires an operator bearer key. SPEC-002 also says the detailed `pool` array is operator-only and must not be exposed to buyers by the gateway. SPEC-015 v0.2 defines no buyer credential, no public receipt-key endpoint, and no safe subset of `/poolz` for verifier use.

**Why it matters:** A buyer-side verifier following v0.2 cannot perform its default live trust-root lookup against the locked coordinator surface. It will either fail into `inconclusive` for valid receipts, require buyers to possess operator credentials, or force implementations to invent an unauthorized public endpoint.

**Suggested fix:** Define a buyer-safe pubkey-resolution surface explicitly, or make v0.2 offline/explicit-key only until such a surface exists. If `/poolz` remains the source, specify the exact authentication and redaction contract in the locked dependency before v0.2 relies on it.

#### S2. Previous-key acceptance does not require the receipt timestamp to be inside the grace window
**Location:** §10.2.1 lines 1360-1372; AC-27 lines 1854-1859; v0.1 AC-11 lines 1753-1761; §10.6 lines 1547-1549

**Finding:** §10.2.1 says a receipt signed by `receipt_pubkey_prev` verifies `valid` if the previous pubkey is still present in `/poolz`, but it does not require checking the receipt `unix_ts` against `rotated_at` and `expires_at`. AC-27 also only says "issued during the grace window" without making the verifier check executable. Locked AC-11 previously required the receipt timestamp to be between `rotated_at - 60` and `expires_at`.

**Why it matters:** A conforming v0.2 verifier could accept any tuple signed by the previous key while the previous key is visible, even if the tuple claims a timestamp outside the rotation grace interval. That contradicts §10.6's claim that a `valid` result proves the key was current or within the rotation grace window.

**Suggested fix:** Make the §10.2.1 verifier rule explicit: matching `receipt_pubkey_prev` is valid only when the tuple `unix_ts` is within the allowed grace interval, including any intended -60s slack.

#### S3. Stale-cache fallback relies on provider-reported time and can validate retired keys
**Location:** §10.2 lines 1331-1340; §10.6 lines 1543-1549

**Finding:** Cache entries are keyed by `provider_pubkey` bytes and a stale cache entry may produce `valid` after live fetch failure when `receipt.unix_ts < fetched_at`. But `unix_ts` is provider-reported and §10.6 explicitly says timestamp honesty is not proven. A holder of an old private key can sign a fresh tuple with a backdated `unix_ts` and satisfy the stale-cache predicate when the live root is unreachable.

**Why it matters:** This lets a stale local cache substitute for the current coordinator endorsement that §10.6 says `valid` proves. It is especially risky after rotation or compromise, where the current root would no longer endorse the old key.

**Suggested fix:** Do not allow stale cache to produce `valid` solely from receipt `unix_ts`. Either make stale-cache results `inconclusive`, or require cached entries to carry enough signed/observed coordinator metadata to prove the key was endorsed for the claimed interval.

### MAJOR findings

#### S4. Non-default coordinator trust is not visible in results
**Location:** §10.4.2 lines 1488-1490; §10.5 lines 1527-1533

**Finding:** The verifier can be pointed at a non-default coordinator via `--coordinator` or `MACPROVIDER_COORDINATOR`, but JSON output only reports `trust_source: "poolz_live"`. It does not report which coordinator host supplied the trust root.

**Why it matters:** Buyers can accidentally or maliciously be pointed at the wrong trust root and still see a generic `poolz_live` result. The trust boundary is coordinator-specific; hiding the host weakens auditability.

**Suggested fix:** Include the coordinator host in JSON and human output whenever `trust_source` is live or cache-derived from a live fetch, and warn when the host is non-default.

#### S5. Divergence warnings can disappear on the paths that need them most
**Location:** §10.2 lines 1348-1353; §10.4.2 lines 1456-1501

**Finding:** Explicit `--pubkey` wins, but the verifier must warn if live `/poolz` disagrees. The spec skips the live check under `--quiet`, has no JSON warning field, and does not say whether `--json` warnings go to stderr, stdout, or the JSON payload.

**Why it matters:** Explicit-key mode is the path where buyers are intentionally overriding the operator root. Losing or misplacing the divergence signal can make a buyer treat a stale or wrong offline key as if it matched the live coordinator.

**Suggested fix:** Define warning behavior per output mode. For JSON, include a machine-readable `warnings[]`; for quiet, state whether divergence checks are skipped or still performed without emission.

### MINOR findings

None.

### QUESTIONS

None.

## Lens: architect - round 1 by Codex

**Verdict:** DESIGN ROUND NEEDED

**Counts:** 1 CRITICAL, 3 MAJOR, 2 MINOR, 0 QUESTIONS

### CRITICAL findings

#### A1. v0.2 depends on a locked coordinator surface that does not expose buyer verification data
**Location:** §10.2 lines 1341-1346; SPEC-002 FR-O2 lines 1316-1380; SPEC-006 §5.4 lines 1084-1095

**Finding:** The architecture of v0.2 assumes the buyer verifier can resolve receipt pubkeys from `/poolz`. Locked SPEC-002 exposes receipt keys only on the operator-only `/poolz` detailed pool. Locked SPEC-006 allows the receipt response header through to buyers, but does not expose coordinator route headers or the detailed pool row to buyers. v0.2 does not add a new authorized buyer-facing resolver.

**Why it matters:** This is a locked-dependency mismatch, not an implementation detail. The verifier contract cannot be implemented as a buyer-facing default without either changing the locked coordinator/gateway API or relying on out-of-band operator credentials.

**Suggested fix:** Decide the architecture explicitly: public receipt-key lookup, authenticated buyer lookup, bundled provider-id/key artifact, or offline-only v0.2. Then update the relevant locked spec candidate before SPEC-015 v0.2 normatively depends on it.

### MAJOR findings

#### A2. BUILD prompt bundle directive drifted from "as buyer holds it"
**Location:** BUILD prompt lines 66-72; SPEC-015 §10.4.1 lines 1439-1441

**Finding:** The BUILD prompt says bundle mode contains "the receipt + the prompt + the output, exactly as the buyer holds them" and suggests the OpenAI request/response shapes. SPEC-015 adds an extra requirement that the request object contain at least the 16 canonical prompt fields, which is not how buyers normally hold OpenAI SDK requests.

**Why it matters:** This is directive drift that changes the product ergonomics and creates an artificial pre-processing requirement before verification. It also duplicates the canonicalization layer's job of filling absent fields as `null`.

**Suggested fix:** Keep bundle mode faithful to raw buyer artifacts and move all canonical-shape completion into the verifier's §4 reconstruction logic.

#### A3. The per-provider `/poolz` variant is not defined by the locked dependency
**Location:** §10.2 lines 1341-1343; SPEC-002 GET `/poolz` lines 2362-2369; SPEC-002 `/v1/pool/check` lines 2373-2396

**Finding:** §10.2 permits live fetch from "`/poolz` (or its extended per-provider variant)", but locked SPEC-002 defines `GET /poolz` and a separate `/v1/pool/check?provider_id=...` health/state endpoint. The latter does not return receipt pubkeys, and no `/poolz/<provider_id>` variant is defined in the dependency.

**Why it matters:** A v0.2 implementation can invent a per-provider endpoint and still believe it follows SPEC-015, while another implementation scans full `/poolz`. That is scope expansion into SPEC-002 without a candidate contract.

**Suggested fix:** Remove the per-provider variant from SPEC-015 or define it in SPEC-002 with exact auth, response shape, and receipt-key fields before referencing it.

#### A4. Cache keying by pubkey bytes loses provider identity
**Location:** §10.2 lines 1331-1340; §10.4.1 lines 1444-1447; §10.6 lines 1547-1549

**Finding:** The cache is keyed by `provider_pubkey` bytes, while bundle `provider_id` is optional and only "accelerates" resolution. That means the cache stores "this key was once seen" rather than "this provider_id mapped to this key under this coordinator at this time." This is weaker than the trust boundary, which describes the key as published for the resolved provider.

**Why it matters:** Provider identity is intentionally out of the signed tuple in locked v0.1, so the resolver is the place where provider-id/key binding must be precise. A pubkey-only cache erases that binding and makes future trust-root upgrades harder.

**Suggested fix:** Key cache entries by `(coordinator_host, provider_id, pubkey)` when provider_id is known, and specify the no-provider-id scan result as a distinct lower-confidence path with explicit output.

### MINOR findings

#### A5. Dependency header still reads as candidate-only for absorbed specs
**Location:** line 4; SPEC-002 header lines 3-15; SPEC-006 header lines 3-11

**Finding:** SPEC-015 line 4 says SPEC-002 v1.3.5 with a v1.4 candidate and SPEC-006 v0.8.3 with a v0.9 candidate. In this worktree, the dependency files themselves are already versioned SPEC-002 v1.4 and SPEC-006 v0.9 with the receipt fields/header allowlist absorbed.

**Why it matters:** This is mostly reference hygiene, but the audit prompt treats locked-spec authority as important. Candidate wording can confuse whether the verifier is relying on draft annotations or absorbed locked specs.

**Suggested fix:** Align the dependency header with the current versions of record, or explicitly state that SPEC-015 is auditing against candidate names even though the local dependency files have absorbed them.

#### A6. AC-24 leaks implementation-repo packaging into the spec
**Location:** AC-24 lines 1835-1839

**Finding:** AC-24 says "The IMPL repo MUST ship a JSON-Schema document..." The spec corpus otherwise treats SPEC-015 as the normative contract and implementation prompts as a separate surface. "IMPL repo" is not a stable contract boundary in SPEC-015.

**Why it matters:** This is not a behavioral blocker, but it is the same kind of implementation-surface leakage the BUILD prompt warns against. The acceptance criterion should name the verifier release/test suite artifact, not an unspecified repo.

**Suggested fix:** Rephrase AC-24 around the verifier implementation test suite and release artifacts, leaving repository layout to the implementation BUILD prompt.

### QUESTIONS

None.

## Convergent findings

### CF1. Buyer pubkey resolution is not architecturally grounded

**Converged from:** code C2/C5, security S1/S4/S5, architect A1/A3/A4

All three lenses independently hit the same root cause: v0.2 promotes verification before the buyer-facing trust-root lookup is fully specified. The spec says the verifier should use live `/poolz`, cache, explicit pubkeys, non-default coordinators, and divergence warnings, but locked SPEC-002 exposes receipt keys only through operator-only `/poolz`, SPEC-006 does not expose detailed pool rows to buyers, and SPEC-015 does not define a safe buyer resolver or complete output/cache semantics.

**Effective severity:** CRITICAL. This must be resolved before v0.2 can lock.

### CF2. Validity depends on time windows that the verifier does not prove

**Converged from:** security S2/S3 and architect A4

The previous-key and stale-cache paths both depend on time claims, but one path omits the `rotated_at`/`expires_at` check and the other trusts provider-reported `unix_ts` after declaring timestamp honesty out of scope. This undermines the narrow §10.6 promise that `valid` means the key was current or within the rotation grace window.

**Effective severity:** CRITICAL. The verifier needs observed/coordinator-derived validity intervals or these paths should produce `inconclusive` rather than `valid`.

### CF3. Bundle and JSON schemas are not yet strict enough for automation

**Converged from:** code C1/C3/C4 and architect A2

The bundle input contract over-constrains raw OpenAI requests while the output contract under-specifies JSON result shapes and contradicts exit codes. Both issues will show up immediately in the implementation prompt and CI fixtures.

**Effective severity:** CRITICAL via C1, with MAJOR follow-on schema work.

## Lens: code — round 2 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 2 MAJOR, 1 MINOR, 0 QUESTIONS

**Round-1 resolution check:** C1, C3, C4, C5, and C6 are substantively resolved by the v0.2.1 rewrites to §10.4.1, §10.4.2, §10.4.3, §10.4.4, AC-24, and AC-25. C2 is resolved at the main resolver level by §10.7 plus §10.2's ban on `/poolz`, but stale `/poolz` wording remains in result semantics and AC-18 as C7 below.

### CRITICAL findings

None.

### MAJOR findings

#### C7. Stale `/poolz` result semantics contradict the new live resolver
**Location:** §10.1 lines 1380-1390; §10.2 lines 1428-1436; AC-18 lines 2106-2110

**Finding:** v0.2.1 correctly moves live resolution to `GET /v1/receipt-keys/<provider_id>` in §10.2 and forbids fallback to operator-only `/poolz`, but §10.1 still defines `inconclusive` and `invalid` cases in terms of `/poolz`, and AC-18 still requires the provider to be "in `/poolz`" with the issuing pubkey. These are no longer just historical references; they sit inside the normative v0.2 verifier contract and acceptance criteria.

**Why it matters:** Implementers can follow §10.2 and test against `/v1/receipt-keys`, or follow §10.1/AC-18 and retain `/poolz` assumptions. That reopens part of CF1 at the contract-consistency level even though the architectural endpoint fix is otherwise sound.

**Suggested fix:** Replace the §10.1 and AC-18 `/poolz` references with `GET /v1/receipt-keys/<provider_id>` language, and make the no-match / mismatch cases line up with §10.2.1.

#### C8. `--provider-id` became required for key resolution but is not fully specified as a CLI input
**Location:** §10.2 lines 1402-1405 and 1438-1444; §10.4 lines 1529-1537; §10.4.4 lines 1696-1719; AC-23 lines 2138-2144

**Finding:** v0.2.1 introduces `--provider-id` as the escape hatch when a bundle lacks `provider_id`, and AC-23 relies on it. But §10.4's accepted input shapes do not list `--provider-id`, §10.4.4's flag matrix does not include it, and header+hashes mode has no documented way to supply the provider id needed to call `/v1/receipt-keys/<provider_id>`.

**Why it matters:** Header+hashes mode can become unexpectedly `inconclusive` for otherwise valid receipts unless the user knows about an under-documented flag. Two implementations can also disagree on whether `--provider-id` is legal only with `--pubkey`, legal with all modes, or required for online header+hash verification.

**Suggested fix:** Promote `--provider-id <id>` into the §10.4 flag/input contract, add it to §10.4.4, and state exactly which input modes require or accept it.

### MINOR findings

#### C9. Cache timestamp formats are split between Unix seconds and RFC3339
**Location:** §10.2 lines 1412-1414 and 1433-1434; §10.7 lines 1853-1858

**Finding:** §10.2 says cache `fetched_at` is Unix seconds and that live success writes `fetched_at = now()`, while §10.7's endpoint response returns `fetched_at`, `rotated_at`, and `expires_at` as RFC3339 strings. This is parseable, but the cache format and wire format boundary should be explicit so fixtures do not drift.

### QUESTIONS

None.

## Lens: security — round 2 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 1 MAJOR, 1 MINOR, 0 QUESTIONS

**Round-1 resolution check:** S1 is resolved by the buyer-callable §10.7 endpoint and §10.2's explicit `/poolz` ban, subject to C7's stale references. S2 is resolved by the explicit `[rotated_at - 60s, expires_at]` check in §10.2.1 and AC-27. S3 is resolved because stale cache can now produce only `inconclusive`, not `valid`. S4 is resolved by `coordinator_host`. S5 is resolved for JSON/default output; `--quiet` now has an explicit suppression rule.

### CRITICAL findings

None.

### MAJOR findings

#### S6. Coordinator-rejected key can still be read as `inconclusive` in §10.1
**Location:** §10.1 lines 1378-1395; §10.2.1 lines 1490-1494

**Finding:** §10.2.1 says a receipt whose `provider_pubkey` matches neither the current nor previous key for the resolved provider MUST be `invalid`. §10.1 still says a resolver response containing no matching `receipt_pubkey` / `receipt_pubkey_prev` is `inconclusive` when no `--pubkey` was supplied.

**Why it matters:** This is the security-sensitive boundary between "the trust root could not be reached" and "the trust root was reached and did not endorse this key." Returning `inconclusive` for the latter weakens script reliability and lets a forged or retired-key receipt look like an environmental failure.

**Suggested fix:** In §10.1, reserve `inconclusive` for fetch failure, provider-id unresolvable, or no authoritative resolver answer. When `/v1/receipt-keys/<provider_id>` returns an authoritative provider record whose current/previous keys do not match, require `invalid`.

### MINOR findings

#### S7. The positive trust-boundary sentence still reads like timestamp attestation
**Location:** §10.6 lines 1762-1781

**Finding:** The opening `valid` proof says a holder signed the tuple "at the claimed `unix_ts`," while the following bullet correctly says timestamp honesty is not proven. The intended meaning is likely "signed a tuple containing the claimed `unix_ts`," but the current wording can be quoted out of context as a time attestation.

### QUESTIONS

None.

## Lens: architect — round 2 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 1 MAJOR, 1 MINOR, 0 QUESTIONS

**Round-1 resolution check:** A1 and A3 are resolved by the explicit SPEC-002 v1.5 candidate endpoint and removal of the per-provider `/poolz` variant. A2, A5, and A6 are resolved. A4 is resolved for cache identity by keying cache entries on `(coordinator_host, provider_id, receipt_pubkey)`, with the remaining provider-id CLI integration gap captured as A7/C8.

### CRITICAL findings

None.

### MAJOR findings

#### A7. Provider identity is now architecturally required but not first-class across verifier modes
**Location:** §10.2 lines 1438-1444; §10.4 lines 1529-1537; §10.7 lines 1813-1828; AC-23 lines 2138-2144

**Finding:** The v0.2.1 architecture correctly chooses a provider-id-addressed resolver, but the verifier contract still treats `provider_id` as optional bundle metadata plus an incidental `--provider-id` flag. That leaves header+hashes mode and non-bundle workflows without a first-class provider identity input, even though the live resolver cannot run without it.

**Why it matters:** Round 1 A4 was about losing provider identity in cache design. v0.2.1 fixes the cache key but leaves identity under-specified at the CLI boundary, where buyers actually invoke verification. This can push implementations back toward pubkey-byte scans or offline-only behavior.

**Suggested fix:** Make provider identity an explicit part of the verifier contract: either require `--provider-id` for online header+hashes mode, or define a separate resolver path when only `provider_pubkey` is known. Keep the no-scan rule.

### MINOR findings

#### A8. `valid` still does not explicitly disclaim receipt uniqueness
**Location:** §10.6 lines 1770-1796

**Finding:** §10.6 cleanly disclaims model attestation, timestamp honesty, privacy, absolute pubkey trustworthiness, and delivery to the verifying buyer. It still does not explicitly say that `valid` does not prove no other receipt was issued for the same prompt/response or that this was the only provider-side attestation. This is not blocking, but it is part of the same trust-boundary surface the audit prompt asked to scrutinize.

### QUESTIONS

None.

## Convergent findings — round 2 by Codex

### CF4. v0.2.1 fixed the trust-root architecture but left resolver terminology split

**Converged from:** code C7, security S6

The buyer-safe `/v1/receipt-keys/<provider_id>` endpoint resolves the original CF1 architecture problem, but §10.1 and AC-18 still speak in `/poolz` terms and §10.1 still conflicts with §10.2.1 on no-match semantics. This is no longer a "drop and redesign" issue; it is a fix-pass consistency issue.

**Effective severity:** MAJOR. Replace stale `/poolz` result/AC wording and align authoritative no-match as `invalid`.

### CF5. Provider identity must be promoted into the verifier CLI contract

**Converged from:** code C8, architect A7

The v0.2.1 cache and live endpoint both need `(coordinator_host, provider_id, receipt_pubkey)`, but §10.4 does not make `provider_id` a complete CLI input across modes. This is the main regression introduced by the otherwise-correct fix for CF1/A4.

**Effective severity:** MAJOR. Add `--provider-id` to the normative input and flag matrix, especially for header+hashes mode.

### CF6. Round-1 criticals are closed in substance

**Converged from:** code/security/architect resolution checks above

The original CF1/CF2/CF3 critical roots are not still open in their round-1 form: live lookup is no longer operator-only `/poolz`, previous-key grace has an executable time-window check, stale cache cannot produce `valid`, raw OpenAI request bundles are accepted, JSON/exit-code surfaces are materially pinned, and cache keying includes provider identity. The remaining findings are consistency and integration fixes suitable for one v0.2.2 pass.

**Effective severity:** informational closure note.

## Lens: code — round 3 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 2 MAJOR, 1 MINOR, 0 QUESTIONS

**Round-2 resolution check:** CF4 / C7 / S6 are resolved by the v0.2.2 rewrite of §10.1 and AC-18: stale `/poolz` wording is gone from the v0.2 verifier result semantics, authoritative resolver no-match is `invalid`, 404 remains a named `inconclusive` case, and AC-18 now uses `GET /v1/receipt-keys/<bundle.provider_id>`. C9 is resolved by the RFC3339 UTC cache-field normalization in §10.2. S7 and A8 are resolved in §10.6. CF5 / C8 / A7 are mostly resolved by making `--provider-id` first-class, but the fix introduced the new code-contract findings below.

### CRITICAL findings

None.

### MAJOR findings

#### C10. Missing provider id is both a required-argument error and an `inconclusive` result
**Location:** §10.4 lines 1612-1618, §10.4 lines 1634-1656, §10.4.3 lines 1790-1794, §10.4.4 lines 1833-1841

**Finding:** Header+hashes mode says `--provider-id` is REQUIRED unless `--pubkey` is supplied. Under §10.4.3, a missing required CLI argument is a usage error with exit `64`. But the later provider-id requirements and flag matrix say that when `--pubkey` is not supplied and no provider id can be obtained, the verifier returns `inconclusive` with `reason: "provider_id_unresolvable"` and exit `2`; the explicit header+hashes/no-provider-id/no-pubkey row repeats that result.

**Why it matters:** Scripts cannot rely on the exit-code mapping for a common v0.2.2 edge case. One conforming implementation can reject the invocation at parse time as `64`; another can run the verifier and emit `result: "inconclusive"` with exit `2`. This is exactly the kind of exit-code ambiguity the v0.2 audit prompt classifies as MAJOR.

**Suggested fix:** Choose one branch. If header+hashes mode truly requires `--provider-id`, make the no-provider-id/no-pubkey invocation exit `64` everywhere and remove the `inconclusive` matrix row. If `provider_id_unresolvable` is intended to be a normal verifier result, replace "REQUIRED" with "needed for online lookup" and keep exit `2`.

#### C11. `live_check_skipped` schema omits required v0.2.2 warning cases
**Location:** §10.4 lines 1645-1651; §10.4.2 lines 1743-1749; AC-22 lines 2274-2281; AC-23 lines 2283-2289; AC-24 lines 2291-2300

**Finding:** §10.4 now requires a `live_check_skipped` warning with `reason: "provider_id_unresolvable"` when explicit `--pubkey` can produce `valid` but no provider id is recoverable. AC-22 also requires `live_check_skipped` with `reason: "network_unreachable"` when no explicit pubkey exists and live resolution fails. But the `warnings[]` schema only allows `reason` values `offline_flag` and `network_unreachable`, and describes `live_check_skipped` as emitted only when explicit `--pubkey` was used.

**Why it matters:** The release JSON Schema required by AC-24 cannot validate every normative output without inventing behavior outside the §10.4.2 table. JSON consumers also cannot know whether `provider_id_unresolvable` is a legal warning reason, a top-level `reason` only, or an implementation mistake.

**Suggested fix:** Expand the `live_check_skipped.reason` enum to include `provider_id_unresolvable`, and rewrite the "When emitted" column so it covers both explicit-pubkey divergence-check skips and ordinary live-resolution failures required by AC-22.

### MINOR findings

#### C12. Core algorithm still describes resolution as pubkey-byte-oriented
**Location:** §10.0 lines 1389-1390; §10.2 lines 1519-1526

**Finding:** §10.0 step 5 says to resolve the trusted pubkey "for the receipt's provider_pubkey bytes," while §10.2 now makes `provider_id` the resolver address and forbids broad pubkey-byte scanning. §10.2 is clear enough to control, but the algorithm summary still points implementers toward the old identity-loss framing.

### QUESTIONS

None.

## Lens: security — round 3 by Codex

**Verdict:** READY TO LOCK

**Counts:** 0 CRITICAL, 0 MAJOR, 0 MINOR, 0 QUESTIONS

**Round-2 resolution check:** S6 is resolved. §10.1 now reserves `inconclusive` for fetch failure, provider-id unresolvable, stale-cache/live-failure, or the special 404 retired-provider case; authoritative HTTP 200 key no-match and out-of-window previous-key matches are `invalid`. S7 is resolved by §10.6's "signed a tuple containing `unix_ts`" wording and the explicit content-not-chronology paragraph. The v0.2.2 changes do not introduce a false-`valid`, unrooted-pubkey, telemetry, trust-boundary, or `inconclusive`-collapse issue.

### CRITICAL findings

None.

### MAJOR findings

None.

### MINOR findings

None.

### QUESTIONS

None.

## Lens: architect — round 3 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 1 MAJOR, 0 MINOR, 0 QUESTIONS

**Round-2 resolution check:** A7 is resolved in architectural direction: provider identity is now a first-class CLI input across header+hashes, bundle, and stdin modes, and §10.2 no longer leaves online resolution without a provider-id path. A8 is resolved by the new receipt-uniqueness disclaimer in §10.6. The BUILD-prompt deferrals remain intact: no bulk verification, no receipt explorer, no model-hash binding, no hardware trust-root, no chain verification, no TUF/on-chain root, and no buyer SDK integration landed in v0.2.2.

### CRITICAL findings

None.

### MAJOR findings

#### A9. Provider-id promotion still has two incompatible architectural interpretations
**Location:** §10.4 lines 1612-1656; §10.4.4 lines 1833-1841

**Finding:** v0.2.2 simultaneously models `provider_id` as a required address component for online header+hashes verification and as an optional identity that may fail to resolve into a normal tri-state verifier result. Both architectures are defensible, but the spec currently contains both. That leaves the verifier boundary unclear: is "missing provider id" a CLI contract violation, or is it a successful invocation whose trust root cannot reach a verdict?

**Why it matters:** This is the only remaining architectural ambiguity from CF5. If left as-is, the implementation prompt will need to choose one meaning, and that choice will be a spec patch disguised as implementation.

**Suggested fix:** Normalize §10.4 around one architectural rule. For a strict CLI contract, require `--provider-id` before execution in header+hashes mode. For a pure tri-state contract, allow the invocation and make provider-id absence an `inconclusive` resolver state.

### MINOR findings

None.

### QUESTIONS

None.

## Convergent findings — round 3 by Codex

### CF7. v0.2.2 closes the round-2 roots but leaves provider-id absence ambiguous

**Converged from:** code C10, architect A9

The round-2 roots CF4 and CF5 are fixed in substance: `/v1/receipt-keys/<provider_id>` is now the operative resolver, authoritative no-match is `invalid`, cache timestamps match the wire shape, `--provider-id` is first-class, and §10.6's trust boundary is sharper. The remaining blocker is a regression introduced while promoting `--provider-id`: missing provider identity is specified both as a required-argument usage error and as a normal `inconclusive` result.

**Effective severity:** MAJOR. One fix pass should be enough: pick either exit `64` or exit `2` semantics for missing provider id in header+hashes mode, then align §10.4, §10.4.3, §10.4.4, the warning schema, and AC-22/AC-24 around that choice.

## Lens: code — round 4 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 1 MAJOR, 0 MINOR, 0 QUESTIONS

**Round-3 resolution check:** C10 is resolved in the controlling CLI contract: §10.4, §10.4.3, and §10.4.4 now consistently make missing `provider_id` without `--pubkey` an exit-64 usage error before the verifier runs. C11 is resolved by adding `provider_id_unresolvable` to the `live_check_skipped.reason` enum for the explicit-`--pubkey` / no-provider-id path. C12 is resolved by rewriting §10.0 step 5 around `provider_id` and by explicitly forbidding pubkey-byte scans. The remaining code finding is a narrow stale-wording regression inside the same provider-id surface.

### CRITICAL findings

None.

### MAJOR findings

#### C13. Provider-id reason wording still conflicts with the strict CLI and JSON contracts
**Location:** §10.1 lines 1516-1520; §10.4.1 lines 1761-1766; §10.4.2 lines 1798-1799 and 1817-1818; §10.7 lines 2073-2076

**Finding:** v0.2.3 intends to separate missing provider identity from resolver failure: missing provider id is exit `64`, `provider_id_not_in_pool` is the top-level inconclusive reason for §10.7 HTTP 404, and `provider_id_unresolvable` is only a `live_check_skipped.reason` warning when explicit `--pubkey` lets verification proceed without a resolver address. Two normative clauses still blur those meanings. §10.4.1 says an absent bundle `provider_id` follows fallback rules "which MAY produce `inconclusive` if no other identification path applies," even though §10.4 and the flag matrix require exit `64` when no provider id can be obtained and no `--pubkey` is supplied. §10.1 also says HTTP 404 is `inconclusive` with `reason: "provider_id_unresolvable"`, while the §10.4.2 exhaustive top-level reason enum and §10.7 404 wording use `provider_id_not_in_pool`.

**Why it matters:** Scripts and JSON Schema consumers can still disagree on two common paths: bundle/stdin without provider identity, and live resolver 404. One conforming implementation could follow the strict matrix and exit `64`, while another could follow the bundle-field note and emit `inconclusive`; one could emit a top-level reason outside the §10.4.2 enum for 404. This is not a security regression, but it is still the exit-code/schema ambiguity CF7 was supposed to close.

**Suggested fix:** Make §10.4.1's `provider_id` bullet say absence follows §10.2/§10.4 fallback rules and produces exit `64` when no provider id is obtainable without `--pubkey`; reserve `inconclusive` there for resolver failures after a provider id exists. Change the §10.1 404 sentence to `reason: "provider_id_not_in_pool"` so `provider_id_unresolvable` remains warning-only.

### MINOR findings

None.

### QUESTIONS

None.

## Lens: security — round 4 by Codex

**Verdict:** READY TO LOCK

**Counts:** 0 CRITICAL, 0 MAJOR, 0 MINOR, 0 QUESTIONS

**Round-3 resolution check:** The v0.2.3 deltas do not re-open the round-3 security result. `inconclusive` remains first-class and cannot become `valid` for unrooted pubkeys; authoritative key mismatch and out-of-window previous-key matches remain `invalid`; stale cache still cannot produce `valid`; `--offline --pubkey` still has zero network; non-default coordinator use remains visible; and §10.6 continues to avoid model-attestation, timestamp-honesty, privacy, pubkey-root, replay, and uniqueness overclaim. The C13/A10 provider-id reason drift is machine-contract wording, not a false-valid or trust-boundary regression.

### CRITICAL findings

None.

### MAJOR findings

None.

### MINOR findings

None.

### QUESTIONS

None.

## Lens: architect — round 4 by Codex

**Verdict:** READY WITH FIX PASS

**Counts:** 0 CRITICAL, 1 MAJOR, 0 MINOR, 0 QUESTIONS

**Round-3 resolution check:** A9 is resolved in the main architecture: v0.2.3 chooses the strict CLI contract, makes `provider_id` the resolver address, forbids provider scans, and reserves `inconclusive` for trust-root failures after parse-time input validation succeeds. BUILD-prompt deferrals remain intact: no bulk verification, no receipt explorer, no model-hash binding, no HSM/hardware trust root, no cross-provider chain verification, no TUF/on-chain root, and no buyer SDK integration landed in v0.2.3.

### CRITICAL findings

None.

### MAJOR findings

#### A10. Strict provider-id contract is architecturally chosen but not fully reified
**Location:** §10.1 lines 1516-1520; §10.4.1 lines 1761-1766; §10.4 lines 1700-1725; §10.4.4 lines 1903-1915

**Finding:** The architecture now clearly chooses "missing provider id is a CLI contract violation" over "missing provider id is a runtime `inconclusive` result." However, §10.4.1 still describes absent bundle `provider_id` as a path that may become `inconclusive` when no identification path applies, and §10.1 still uses the old `provider_id_unresolvable` reason for the 404 retired-provider case. Those stale clauses preserve a sliver of the old dual interpretation even though the controlling §10.4 paragraphs and matrix are strict.

**Why it matters:** The implementation BUILD prompt should not have to decide which provider-id interpretation wins when generating tests and JSON Schema. Leaving stale wording in a lock candidate risks a "spec patch disguised as implementation" exactly where round 3 asked v0.2.3 to make the architectural choice explicit.

**Suggested fix:** Align the two stale clauses with the strict contract: no provider id before execution is `64`; HTTP 404 after a provider-id-addressed resolver call is `inconclusive` with `provider_id_not_in_pool`; `provider_id_unresolvable` is only a warning reason for explicit-pubkey verification with no addressable live check.

### MINOR findings

None.

### QUESTIONS

None.

## Convergent findings — round 4 by Codex

### CF8. v0.2.3 chose the strict provider-id contract but left stale reason/field wording

**Converged from:** code C13, architect A10

The round-3 roots are closed in substance: C10's exit-code contradiction is fixed in §10.4/§10.4.3/§10.4.4, C11's warning enum is fixed, C12's algorithm framing is fixed, and A9's architectural choice is made. The remaining issue is narrow but still lock-blocking for automation: §10.4.1 still hints that absent provider identity can become `inconclusive`, and §10.1 still assigns the old `provider_id_unresolvable` top-level reason to §10.7 404 despite the enum and endpoint wording using `provider_id_not_in_pool`.

**Effective severity:** MAJOR. One text-only fix pass should be enough; no security redesign or resolver architecture change is needed.
