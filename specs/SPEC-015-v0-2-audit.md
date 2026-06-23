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
