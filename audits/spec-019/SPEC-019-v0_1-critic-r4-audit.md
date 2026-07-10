**Verdict:** FIX REQUIRED
**Tally:** C/H/M/m/Q = 0/1/2/1/0

## Closure verified

Status of r3 critic findings against v0.1.3 (`eee4282`):

- **r3 F-1** (gzip body-byte preservation contradicts gateway quota-parse path):
  **CLOSED** by posture switch. §7 lines 750-764 now mandate HTTP 415
  `request_content_encoding_unsupported` for any `Content-Encoding` header, AC-28a
  lines 354-361 codifies the parity reject fixture, §5 error-code table line 643
  registers `request_content_encoding_unsupported`, and §10 line 854-857 defers
  transparent decompression to v0.2. The r3 contradiction (gateway forwards
  gzipped bytes but `parseChatRequest` json.Unmarshals raw body) is resolved:
  v0.1.0 no longer pretends to support compressed bodies, so the gateway's
  current code path is consistent with the SPEC. **Caveat:** the closure
  introduces a fresh self-contradiction inside §7 vs AC-28a on `identity` —
  see fresh F-1 below. The contradiction is not the original r3 issue;
  the original is resolved.

- **r3 F-2** (`max_tokens` in empty-content remediation message):
  **CLOSED**. §5 line 597-600 message now reads "adjust `temperature` /
  `seed` (for stochastic models), or modify the prompt or schema before
  retrying — automatic same-request retry will not succeed." No
  `max_tokens` reference remains in the empty-content path.

- **r3 F-3** (depth-counting items-vs-properties symmetry):
  **CLOSED**. §6 lines 700-705 add the mixed-keyword worked example:
  `{type:array, items:{type:array, items:{type:object,
  properties:{id:{type:string}}}}}` is depth 4, with the explicit
  statement "Both `items` subtree and `properties[*]` subtree increment
  the counter by 1, regardless of which keyword is used at each level.
  Provider and coordinator MUST compute the same value." This closes the
  parity-drift risk under AC-12 / AC-27 by pinning the expected count
  for a mixed `items`/`properties` adversarial schema.

- **r3 F-4** (nested Pydantic `$defs` limitation undocumented):
  **CLOSED**. §10 lines 861-863 add the v0.2 deferral: "AC-30 uses a
  flat Pydantic model. Nested Pydantic models emit `$defs` / `$ref`
  which §3 rejects (per v0.1.0 reject-list); fixtures with nested
  classes are deferred to v0.2 when `$ref` / `$defs` schema reuse is in
  scope." However, this absorption introduces a fresh §10 internal
  contradiction — see fresh F-3 below — because `$ref` / `$defs`
  schema reuse is itself listed under "Deferred to v0.3 or later"
  (line 868), not v0.2.

- **r3 F-5** (Q — which existing gateway helper is the SPEC pointing
  at): **NOT ADDRESSED** in v0.1.3 (no new text in §7 lines 766-785
  beyond what was present in v0.1.2). This was Q-severity and explicitly
  marked as IMPL-audit-resolvable in r3; the SPEC remains internally
  consistent (it cites `chat_proxy.go:593-599`,
  `chat_proxy.go:601-607`, and `chat_proxy.go:317-327`) without naming
  which predicate to extend. Acceptable closure for Q; not a blocker.

Closure summary: 4 of 4 graded r3 critic findings (HIGH + 2x MEDIUM +
minor) are CLOSED in v0.1.3. The Q is left to IMPL audit, which is
where r3 said it belonged. Closure quality is high — the gzip posture
switch is bold but coherent (it preserves a single uncompressed
byte-domain), the empty-content message is unambiguously fixed, the
depth algorithm now has the mixed-construct fixture, and the Pydantic
limitation is documented.

## Fresh findings

### Finding 1: §7 `Content-Encoding` posture contradicts AC-28a on whether `identity` is accepted

- **Severity:** HIGH
- **Location:** SPEC-019 §7 lines 750-752 vs AC-28a lines 354-361.
- **Issue:** §7 line 750-752 reads: "the gateway and coordinator MUST
  reject any request with a `Content-Encoding` header (`gzip`,
  `deflate`, `br`, or **any non-empty value**)". AC-28a line 361 reads:
  "`Content-Encoding: identity` is the only accepted value (or omitted
  header)." `identity` is a non-empty value. §7 mandates reject; AC-28a
  mandates accept. Both are normative ("MUST"). Two competent
  implementers reading these will write different code: one will reject
  every `Content-Encoding` header including `identity` (per §7 literal),
  the other will accept `identity` (per AC-28a literal). A buyer / SDK
  using an HTTP client that defaults to sending `Content-Encoding:
  identity` (some Go HTTP clients do this when explicitly opting out of
  compression) will hit divergent gateway-vs-coordinator behavior, OR
  divergent provider-vs-coordinator behavior if one layer follows §7
  and the other follows AC-28a. This is exactly the gateway/coordinator
  parity drift §7 is supposed to prevent. The fix is a one-line
  rewrite, but the SPEC is currently unimplementable as written — IMPL
  audit will catch this immediately.
- **Recommendation:** Pick one. The semantically correct posture (per
  RFC 9110 §8.4: `identity` is "no transformation has been applied")
  is to accept `identity` as a no-op. Rewrite §7 line 750-752 to:
  "the gateway and coordinator MUST reject any request whose
  `Content-Encoding` header value is non-empty and is not `identity`
  (i.e., reject `gzip`, `deflate`, `br`, and any other compression
  encoding) with HTTP 415 `request_content_encoding_unsupported`.
  Omitted header and `Content-Encoding: identity` are both accepted as
  the no-encoding case." This aligns §7 with AC-28a. Also update the
  §7 line 752 example list to remove "any non-empty value".

### Finding 2: AC-31 cross-references AC-3 for the rejected-keyword list, but AC-3 is `json_schema_missing_schema` — wrong AC pointer

- **Severity:** MEDIUM
- **Location:** SPEC-019 AC-31 lines 390-393.
- **Issue:** AC-31 reads `"v0.1.0 §3 rejects $schema (per AC-3
  rejected-keyword list)"`. AC-3 (line 154-156) is
  `json_schema_missing_schema` — a missing-field error code, not a
  rejected-keyword list. The actual rejected-keyword AC is AC-5 (line
  164-166: "Schema using any §3 rejected keyword returns HTTP 400
  `json_schema_unsupported_keyword`"). This is a stale citation that
  will confuse anyone tracing the test's contract chain. Worse, the §3
  rejected-keyword table (lines 438-445) does NOT name `$schema`
  explicitly — `$schema` is rejected only as a fallthrough via "any
  unknown keyword". So a reader checking AC-31's `$schema` claim against
  AC-3 (wrong AC) and then §3 (where `$schema` is not explicitly listed)
  has to chain two pieces of indirection to verify the rejection is
  real. This is exactly the kind of cross-reference drift the SPEC
  audit loop is supposed to catch.
- **Recommendation:** Change AC-31 line 392 from "(per AC-3
  rejected-keyword list)" to "(per AC-5 / §3 rejected-keyword list and
  unknown-keyword fallthrough)". Also consider adding `$schema`
  explicitly to the §3 rejected-keyword sentence (line 438-445) since
  AC-31 specifically calls it out and Vercel SDK output reliably emits
  it — making the rejection explicit removes the unknown-keyword
  fallthrough indirection.

### Finding 3: §10 v0.2 deferral promises nested-Pydantic fixtures "when `$ref` / `$defs` schema reuse is in scope" — but `$ref` / `$defs` is deferred to v0.3, not v0.2

- **Severity:** MEDIUM
- **Location:** SPEC-019 §10 lines 861-863 (v0.2 deferred list) vs §10
  line 868 (v0.3 deferred list).
- **Issue:** The v0.2 deferred bullet for nested-Pydantic fixtures says:
  "fixtures with nested classes are deferred to v0.2 when `$ref` /
  `$defs` schema reuse is in scope." But the v0.3 deferred list at line
  868 reads: "`$ref` / `$defs` schema reuse". So §10 promises nested
  Pydantic fixtures will land at v0.2 conditional on `$ref` / `$defs`
  support, but `$ref` / `$defs` itself is scheduled for v0.3 or later.
  This is an internally contradictory deferral: the dependency is
  scheduled AFTER the dependent feature. A reader trying to plan v0.2
  acceptance criteria will be unable to determine whether nested-Pydantic
  fixtures must be implemented for v0.2 lock. Two reasonable
  interpretations: (a) nested-Pydantic moves to v0.3 with `$ref` /
  `$defs`; (b) `$ref` / `$defs` move up to v0.2 with nested-Pydantic.
  The SPEC has to pick one.
- **Recommendation:** Either move the nested-Pydantic deferral from
  v0.2 to v0.3 (cleaner — keeps `$ref` / `$defs` scheduling consistent),
  or move `$ref` / `$defs` schema reuse from v0.3 to v0.2 (more
  aggressive — promotes the dependency). Recommended: move
  nested-Pydantic to v0.3, since `$ref` / `$defs` is the heavier lift
  (recursion-safe canonicalization, depth-cap interaction, byte-cap
  interaction). Rewrite §10 line 861-863 as a v0.3 bullet:
  "AC-30 uses a flat Pydantic model. Nested Pydantic models emit
  `$defs` / `$ref` which §3 rejects (per v0.1.0 reject-list); fixtures
  with nested classes are deferred to v0.3 alongside `$ref` / `$defs`
  schema reuse."

### Finding 4: AC-31 `$schema` strip is a test-side fixture-comparison step, but the underlying production request would be 400-rejected — fixture covers an unreachable code path

- **Severity:** minor
- **Location:** SPEC-019 AC-31 lines 390-400.
- **Issue:** AC-31 says: "A normalization step strips the `$schema`
  top-level key from the captured Vercel body before canonical-schema
  comparison". This is unambiguously a test-side comparison step ("before
  canonical-schema comparison"). But in production, the Vercel SDK with
  `supportsStructuredOutputs:true` emits `$schema` in the actual outbound
  request body. §3 rejects unknown keywords (including `$schema`) with
  HTTP 400 `json_schema_unsupported_keyword`. So in production, the
  Vercel body never reaches inference — it 400s at the request-validation
  boundary. The fixture's "JCS-canonicalized
  `response_format.json_schema.schema` MUST match the AC-30 Pydantic
  schema modulo `title` / `description` AND `$schema`" assertion is
  comparing a strip-normalized captured-body against an AC-30 fixture —
  not testing what actually happens to a buyer's Vercel-SDK request in
  production. The fixture proves that IF `$schema` were stripped at the
  buyer side, the canonical schemas would match. It does NOT prove
  end-to-end Vercel→macprovider behavior works.

  Either: (a) v0.1.0 documents that Vercel users must run an SDK-side
  `$schema` strip before sending (and v0.1.0 release notes call this
  out as a known limitation), or (b) v0.1.0 accepts `$schema` as a
  no-op (then §3 must say so explicitly), or (c) AC-31 is downgraded
  from "paired fixture" to "schema-shape parity check" with explicit
  caveat that the live Vercel path 400s in v0.1.0.

  Option (c) is the most honest; option (a) is what the SPEC implicitly
  assumes but doesn't make explicit; option (b) is the cleanest user
  experience but expands §3.
- **Recommendation:** Add a sentence to AC-31 explicitly noting the
  limitation: "Note: in v0.1.0 production, a Vercel-SDK request that
  emits `$schema` would receive HTTP 400 `json_schema_unsupported_keyword`
  before inference. AC-31 verifies schema-shape parity assuming a
  buyer-side `$schema` strip; v0.1.0 release notes MUST surface this
  limitation. v0.2 accepts `$schema` per §10." This makes the fixture
  honest about what it tests.

## Verdict justification

R3 absorption is genuinely tight on all 4 graded critic findings. The
gzip posture switch (r3 F-1) is the most consequential — the r3 spec
was unimplementable against the gateway's actual quota-parse path, and
v0.1.3 picks a coherent layer (HTTP 415 reject) that preserves the
single uncompressed byte-domain invariant. The `max_tokens` removal
(r3 F-2) is exact. The depth-counting mixed-construct worked example
(r3 F-3) is exemplary — depth 4 is named, the algorithm rule is
restated, and provider/coordinator parity is mandated. The Pydantic
limitation note (r3 F-4) closes the silent-sidestep risk.

The gzip absorption introduced one fresh HIGH (§7 vs AC-28a on
`identity`) and one fresh MEDIUM (§10 deferred-list internal
contradiction on nested-Pydantic dependency on `$ref` / `$defs`). The
AC-31 `$schema` strip absorption introduced one fresh MEDIUM (wrong
AC cross-reference) and one fresh minor (fixture-vs-production gap).
None of these is structurally as bad as the r3 gzip contradiction;
all four are one-to-five-line fixes.

**Realist check on F-1 severity:** The §7-vs-AC-28a `identity`
contradiction is HIGH because:
(a) It's a normative MUST contradiction between sections of the same
    SPEC — both implementers writing to §7 and implementers writing to
    AC-28a will produce different code;
(b) Detection is silent: an HTTP client that explicitly opts out of
    compression by sending `Content-Encoding: identity` will hit
    divergent gateway-vs-coordinator behavior; the divergence will
    show up as a parity-test failure, not an immediate runtime crash;
(c) The fix is trivial (one §7 sentence rewrite).
Mitigating factors: in practice, almost no HTTP client sends
`Content-Encoding: identity` explicitly — it's the implicit default.
Realistic blast radius is small. Detection time is at IMPL parity test
construction, not production. If this were the only finding I would
downgrade to MEDIUM, but it stands at HIGH because the SPEC is
unimplementable as written for one specific value (`identity`) and the
fix is mandatory before lock — there's no "ship now and fix later"
posture available.

**Realist check on F-2 (AC-3 vs AC-5 cross-reference):** MEDIUM because
the cross-reference itself is wrong AND the §3 rejected-keyword table
doesn't explicitly name `$schema`. Both are reachable via fallthrough
("any unknown keyword"), but the IMPL author has to chain two
indirections to verify the assertion. Easy fix.

**Realist check on F-3 (§10 nested-Pydantic dependency on v0.3 `$ref`/
`$defs`):** MEDIUM because the SPEC promises a v0.2 deferral that
depends on a v0.3 feature. v0.2 planners will be unable to determine
whether nested-Pydantic must ship at v0.2. Easy fix.

**Realist check on F-4 (AC-31 strip is test-side, production 400s):**
minor because the test still has value (it proves shape parity for the
post-strip canonical form), but the fixture is currently silent about
the limitation. Adding the limitation note to AC-31 is hygienic, not
structural.

**Adversarial mode escalation:** Because F-1 is HIGH, I escalated to
ADVERSARIAL mode for the remaining inspection. I specifically probed:
(a) the §10 deferred list for v0.2-vs-v0.3 scheduling consistency
    across all bullets — found the nested-Pydantic vs `$ref`/`$defs`
    contradiction (F-3);
(b) the AC-31 rewrite for production-path vs fixture-path divergence —
    found the strip-is-test-side issue (F-4);
(c) the AC-31 cross-references for staleness — found the AC-3 vs
    AC-5 misnaming (F-2);
(d) the empty-content `retryable:false` + "buyer MAY issue modified
    retry" semantics — actually clean. §5 line 604-609 is unambiguous:
    `retryable:false` binds the SDK auto-retry loop, "MAY issue
    modified retry" is advisory to the buyer human/code making the
    retry decision. This is the right altitude. SDK authors get a
    machine-readable signal (`retryable:false`), buyers get an
    actionable message. No finding.
(e) the depth algorithm mixed-keyword example for off-by-one or
    sibling-vs-nested confusion — counted manually, depth 4 is
    correct, the sibling-doesn't-increment rule is unambiguous. No
    finding.
(f) the gzip 415 vs SPEC-006 §1650-1657 — SPEC-006 §1650-1657 is the
    413 oversize posture; SPEC-019 §7 line 763-764 explicitly says "No
    SPEC-006 or SPEC-001 amendment is required: SPEC-006 §1650-1657
    already covers request-body size limits and 413; this adds 415
    for a separate header gate." Clean.

**One more r3 absorption pass closes all four findings.** F-1 is a
1-3 line §7 rewrite. F-2 is a one-word fix. F-3 is a §10 bullet move.
F-4 is a 2-line note on AC-31. Estimated absorption ≤ 8 lines total.
v0.1.4 absorption should converge.

**Critic confidence on remaining hidden findings:** MEDIUM-HIGH that
the SPEC is otherwise clean. r3 absorption was the smallest of the
four rounds (r1=31, r2=18, r3=14, r4 fresh=4); the trend is correct.
v0.1.4 should be the lock candidate.
