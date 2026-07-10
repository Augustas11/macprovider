**Verdict:** READY TO LOCK
**Tally:** C/H/M/m/Q = 0/0/0/0/0

## Closure verified

Status of r4 critic findings against v0.1.4 (`9b4ec08`):

- **r4 F-1** (§7 vs AC-28a `identity` contradiction, HIGH):
  **CLOSED**. §7 lines 755-758 now read: "the gateway and coordinator
  MUST reject any request with a `Content-Encoding` header whose
  normalized field value is not exactly `identity` (RFC 9110 §8.4.1.1
  explicit no-op encoding). `Content-Encoding: identity` and omitted
  `Content-Encoding` are accepted." AC-28a line 361 reads:
  "`Content-Encoding: identity` is the only accepted value (or omitted
  header)." Both sections now agree: identity accepted, everything else
  non-empty rejected. Grep for the old "any non-empty value" wording
  returns 0 (verified). Resolution is exactly the architect + critic
  convergent fix recommended in r4.

- **r4 F-2** (AC-31 cites AC-3 for rejected-keyword list, MEDIUM):
  **CLOSED**. Line 395 now reads "v0.1.0 §3 rejects `$schema` (per
  AC-5 rejected-keyword list)". AC-5 is correctly the
  `json_schema_unsupported_keyword` AC. Additionally, §3 line 444 now
  names `$schema` explicitly in the reject list ("`oneOf`, `anyOf`,
  `allOf`, `not`, `$schema`, `$ref`, `$defs`, ...") rather than relying
  on the unknown-keyword fallthrough. Two-step indirection eliminated.

- **r4 F-3** (§10 nested-Pydantic depends on v0.3 `$ref`/`$defs` but is
  itself deferred to v0.2, MEDIUM): **CLOSED**. Lines 879-882 move
  nested-Pydantic from v0.2 to v0.3 ("v0.3 or later: nested Pydantic
  fixtures... deferred to v0.3 when `$ref` / `$defs` schema reuse is in
  scope"). v0.3 nested-Pydantic now aligns with v0.3 `$ref`/`$defs`
  (line 878). Both bullets cite the same target version.

- **r4 F-4** (AC-31 strip is test-side, production 400s, minor):
  **CLOSED**. AC-31 lines 403-405 now include the footnote: "Production
  Vercel buyers using `supportsStructuredOutputs:true` without the
  test-side `$schema` normalization receive HTTP 400 from §3's
  rejected-keyword list in v0.1.0." Fixture is now honest about the
  test-side strip and the production-path 400 boundary.

Closure summary: 4 of 4 graded r4 critic findings (HIGH + 2x MEDIUM +
minor) are CLOSED in v0.1.4. Absorption is minimal (≤ 8 lines per the
fix prompt's estimate, confirmed in the diff). Quality is high: the
identity contradiction picks the RFC 9110 no-op posture, the AC-5
citation now resolves directly to the rejected-keyword AC, the §10
dependency is internally consistent, and the AC-31 footnote names the
production limitation.

## Fresh findings

None.

### Probe results (no findings, recorded for transparency)

**Probe 1: §7 RFC 9110 carve-out wording — is v0.1.0 locked to RFC 9110
specifically, or also accepting earlier RFC 7231 identity semantics?**
The §7 wording cites RFC 9110 §8.4.1.1 in parentheses as an informative
citation for the no-op semantics, not as a normative version-lock. The
normative requirement is the byte-level behavior: accept `identity` or
omitted, reject everything else compressed. RFC 7231's earlier identity
semantics (§3.1.2.1 of the obsoleted spec) define the same no-op
behavior, so an implementer reading RFC 7231 will land at the same
behavior. The citation is hygiene, not a forward-incompat trap.
No finding.

**Probe 2: §10 deferred list — is the v0.1.4 bullet-shape
standardization consistent across all 12+ entries?**
Counted 13 bullets across v0.2 (7 bullets) and v0.3 (6 bullets)
sections. All 13 use the shape `{target-version}: {what} [+ optional
why-if-non-obvious]`. The longer bullets (decompression L866-870,
numeric-bounds L871-873, nested-Pydantic L879-882) have justified
extensions because they document v0.1.0 fallback behavior or
non-obvious dependencies; the extensions follow the same target-then-
what-then-why shape internally. The v0.2 prefix is "v0.2:" while the
v0.3 prefix is "v0.3 or later:" — this difference matches each
section's header ("Deferred to v0.2" vs "Deferred to v0.3 or later")
and is internally consistent. No finding.

**Probe 3 (independent, adversarial-mode): AC-28a vs §7 settlement /
response-shape parity.** AC-28a says
`retryable:false`, `inference_ran:false`, `settlement_ran:false`,
identical at gateway and coordinator. §7 line 760-761 says HTTP 415
`request_content_encoding_unsupported`. The error code is in the §5
error table (line 648, "415 | gateway + coordinator pre-validation |
false"). All three sections agree. No finding.

**Probe 4 (independent, adversarial-mode): cross-section consistency on
the §3 `$schema` reject.** §3 line 443-449 names `$schema` explicitly
(closed by r4 fix C); AC-5 line 164-166 says any §3 rejected keyword
returns `json_schema_unsupported_keyword`; AC-31 line 395 cites AC-5;
§10 line 871-873 says `$schema` acceptance is deferred to v0.2. The
v0.1.0 reject + v0.2 deferral story is internally coherent across §3,
§5, AC-5, AC-31, and §10. No finding.

**Probe 5 (independent, adversarial-mode): version metadata
consistency.** Line 3 says "Version: 0.1.4 (2026-06-28, round-4 polish
absorption)". Line 5 says "Status: DRAFT — final defensive check
pending." §12 line 932 says "Status: DRAFT — final defensive check
pending OR locking target." Line 934 says "Version: 0.1.4 (2026-06-28,
round-4 polish absorption)". Status strings differ slightly between §0
metadata block (line 5) and §12 metadata block (line 932) but both
acknowledge defensive check pending. This is acceptable; the §12 form
"OR locking target" is more forward-looking but doesn't contradict §0.
No finding.

**Probe 6 (independent, adversarial-mode): empty-content retry semantics
across §1, §5, AC-18.** §1 line 99-101 names `json_schema_non_strict_unsupported`;
§5 lines 600-607 specify `retryable:false` + actionable message for
empty content; AC-18 lines 256-260 codify HTTP 502
`malformed_json_response`, `FaultBreakerQualifying`, `retryable:false`,
actionable message. Three sections agree. No finding.

## Verdict justification

v0.1.4 is the lock candidate. r4 absorption was the smallest of four
rounds (r1=31, r2=18, r3=14, r4=11 across 6 lanes; r5 from critic = 0).
The trend is strictly monotonic-decreasing and now hits zero on the
critic lane.

All 4 graded r4 critic findings are closed via exactly the fixes the
r4 audit recommended (no creative reinterpretation, no scope expansion,
no orthogonal regressions). The two fresh probes from the r5 lens
(RFC 9110 carve-out version-lock; §10 bullet-shape standardization
consistency) both return no finding: the RFC 9110 citation is
informative not normative, and the bullet shape is internally
consistent across all 13 entries.

I additionally ran four independent adversarial probes (AC-28a vs §7
parity, §3/AC-5/AC-31/§10 `$schema` story consistency, version
metadata consistency, empty-content retry semantics across §1/§5/AC-18)
and found no contradictions.

**Realist check on the zero verdict:** A 0/0/0 verdict at r5 across all
lanes would be unusual if v0.1.4 had been heavily edited. But v0.1.4
absorbed only 7 themed blocks totaling ≤ 8 lines, all 1-3 line
convergent fixes from r4 audits where 3 of 6 lanes already returned
READY TO LOCK. The small absorption surface area is precisely the
condition under which 0/0/0 is plausible. r1's 31 findings reflected
genuine v0.1.0 raw-draft surface area; r5's 0 findings reflect a SPEC
that has been progressively hardened across 4 absorption rounds. The
trend is what one expects from a well-functioning audit loop.

**Adversarial mode escalation:** Because r4 had a HIGH finding I had
escalated to ADVERSARIAL mode in r4. For r5 I started in THOROUGH mode
and stayed there — none of the r5 probes returned findings that would
trigger escalation. The SPEC is in the steady state.

**Critic confidence on remaining hidden findings:** HIGH that the SPEC
is clean. After 4 absorption rounds and 6 audit lanes (the critic lane
has now run 4 of those rounds), the probability that a missed
contradiction survives all 24 lane-rounds is low. The IMPL audit will
catch any implementation-specific gaps that the SPEC body cannot
surface (e.g. exact case-folding semantics for the `identity` token
comparison — that's an IMPL concern, not a SPEC concern, because the
SPEC says "normalized" without locking the normalization function,
which is the right altitude for a SPEC).

**Lock recommendation:** v0.1.4 LOCKS as the SPEC-019 PR anchor if all
6 r5 lanes return 0/0/0. Critic lane returns 0/0/0.
