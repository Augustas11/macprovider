# SPEC-008 v0.1 audit report

## Round 1 (Codex, 2026-05-30T23:17:26Z)

### Summary
- 2 CRITICAL findings
- 17 MAJOR findings
- 1 MINOR finding
- 1 QUESTION

SPEC-008 is directionally coherent: the four-pillar architecture, phase order,
Tier-1 disclosure posture, coordinator plaintext boundary, clean-room rule, and
F-1.5 sticky survivability model all broadly match the BUILD prompt and locked
spec corpus. The blocking issues are contract precision and default-preservation
edges, not a failed architecture. The highest-impact gaps are default-off behavior
under Tier-2 evidence, crypto/key-material hygiene in logs and errors, Pillar B
wire detail, Pillar D flag semantics, and incomplete phase/disclosure mappings.

### Category sweep

| Category | Result |
|---|---|
| A Additive/default preservation | Findings C1, M16 |
| B Survivability audit | Finding m1 only; no invariant violation found |
| C Pillar A | Findings M1, M2; question q1 |
| D Pillar B | Findings M3, M4, M6, M7, M10, M12 |
| E Pillar C | Findings M2, M5, M6 |
| F Pillar D | Findings M8, M9, M17 |
| G Phase roadmap | Findings M8, M13 |
| H SPEC-001 v2.0 annotations | Findings M3, M5, M10, M15 |
| I Configuration | Findings M8, M11 |
| J Observability/audit categories | Findings C2, M7, M12 |
| K Disclosure protocol | Finding M13; non-override and partial model-hash case pass |
| L Acceptance criteria | Findings M16, M17; AC count is exactly 26 |
| M Cross-spec coherence | Findings M14, M15; no sticky/provider-side state regression found |
| N Security properties | Findings C2, M6, M7; question q1 |

### CRITICAL findings

C1. Default config can still activate Tier-2 API and audit-log behavior

**Location:** §4.3 lines 442-454; §5.7 lines 681-685; §14 AC-T2-5 lines 2065-2070. BUILD hard rule lines 346-349.

**Finding:** The spec says the coordinator MAY compute and log Tier-2 evidence
when fields are present, and says `hash_verification` appears when a provider
reports `model_hash`, even when every `tier2.*` enforcement key remains at its
default. That conflicts with the audit hard rule that a SPEC-008 coordinator
binary deployed with no config change produces no new log lines, routing
decisions, API fields, or buyer-visible responses.

**Why it matters:** This is the core Tier-1 backward-compat gate. Any default
path that changes `/v1/models` shape or audit output can break live Tier-1
deployments on binary upgrade or create expectation drift before enforcement is
operator-enabled.

**Suggested fix:** Require an explicit operator opt-in before Tier-2 evidence
changes `/v1/models` or emits Tier-2 audit events. The narrowest fix is to make
catalog/evidence observation active only when `tier2.catalog_path` is non-empty,
a required predicate is enabled, or a new default-false observe flag is enabled.
Then expand AC-T2-5 to prove no Tier-2 logs, fields, routing changes, or response
changes under a no-config deployment.

C2. Audit field hygiene omits cryptographic key material and raw attestation tokens

**Location:** §12.1 lines 1822-1830; §14 AC-T2-25 lines 2178-2182; §15.2 lines 2234-2242; §15.3 lines 2257-2267.

**Finding:** The audit-log forbidden-field list covers API keys, provider bearer
tokens, raw prompts, completions, raw `account_id`, buyer conversation tags, and
`routing_internal.conversation_key`. It does not forbid ECDH private keys, AEAD
keys, derived shared secrets, raw attestation tokens, or other raw proof material.

**Why it matters:** Pillars B and C introduce high-value secrets and bearer-like
attestation artifacts. Logging them would be a security incident and violates
the audit prompt's explicit N.1 bar.

**Suggested fix:** Add a normative ban covering ECDH private keys, X25519 shared
secrets, HKDF PRKs/OKMs, AEAD keys, raw attestation tokens/assertions/JWS bodies,
and any unredacted cryptographic proof material. Update AC-T2-25 to test these
fields are absent from Tier-2 logs.

### MAJOR findings

M1. Hash-mismatch routing requirements contradict each other

**Location:** §5.5 lines 625-631; §5.6 lines 635-637; §5.9 lines 712-715.

**Finding:** §5.5 says `hash_mismatch` and `hash_invalid` MUST exclude the
provider from serving the affected model. §5.6 then says hash status MUST NOT
change routing when `tier2.require_hash_verified: false`, except that a
catalogued mismatch SHOULD be excluded.

**Why it matters:** Implementers can choose either "known-bad hash is never
routable" or "known-bad hash is only a soft exclusion under defaults." The BUILD
prompt locked mismatch rejection as a MUST.

**Suggested fix:** Make `hash_mismatch` and `hash_invalid` consistently
routing-ineligible when a catalog entry exists. Keep default permissiveness only
for `uncatalogued` and `catalog_unavailable` states.

M2. Tier-2 buyer error envelopes are under-specified

**Location:** §4.5 lines 489-492; §5.6 lines 642-648; §6.8 lines 931-937; §7.6 lines 1121-1126.

**Finding:** The spec usually gives HTTP status and machine code, but not the
full OpenAI-compatible envelope `type`, exact `code`, and message text. It also
does not define the hash-mismatch empty-pool behavior under default/observe
config, and hard-pin failures only say "existing hard-pin failure class" plus a
Tier-2-specific code in body or logs.

**Why it matters:** SPEC-006 locks the error envelope vocabulary. Without exact
error types and bodies, Phase 1/2 implementers and tests will diverge.

**Suggested fix:** Add a Tier-2 error table covering hash-required, encrypted-leg
required, attestation required, hard-pin predicate failure, hash mismatch, AEAD
failure, and Pillar D validation failure. Include status, `error.type`,
`error.code`, message, and streaming-after-commit behavior.

M3. AEAD AAD is specified for request frames only

**Location:** §6.5 lines 849-870; §6.7 lines 898-917; §10.7 lines 1651-1679.

**Finding:** §6.5 defines deterministic AAD for `inference_request` with
`direction: "c2p"`. `inference_response_chunk` also carries `enc.aad`, but the
response AAD schema is not defined.

**Why it matters:** AEAD authenticity depends on both parties committing to the
same associated data. Different implementations can authenticate different
fields for provider-to-coordinator chunks.

**Suggested fix:** Define separate canonical AAD schemas for
`inference_request`, `inference_response_chunk`, and any future encrypted
terminal/error envelope, including `type`, `direction`, `request_id`, `seq`,
`provider_id`, `assigned_id`, `stream`, and any omitted fields.

M4. AEAD decrypt-failure behavior is missing

**Location:** §6.7 lines 900-917; §12.3 lines 1843-1852; §15.2 lines 2221-2233.

**Finding:** The spec names `aead_decrypt_failed` as an audit event but does not
say what the coordinator does when a provider response chunk fails
authentication.

**Why it matters:** Decryption failure is both a security signal and a relay
failure. Implementers need deterministic behavior for provider state, WebSocket
closure, pre-commit retry/failover, post-commit streaming errors, and buyer
responses.

**Suggested fix:** Define pre-commit and post-commit handling. A reasonable rule:
log MAJOR, close or quarantine the provider session, never forward unauthenticated
bytes, use SPEC-002 failover only before buyer commit and never for hard pins,
then return/emit a standard Tier-2 error.

M5. Attestation token encoding and maximum length are not precise

**Location:** §7.4 lines 1047-1070; §10.4 lines 1532-1565.

**Finding:** `attestation_token.token` is described as
`base64url-or-JWS-token`, with no maximum length, no exact encoding choices, and
no oversized/malformed rejection code.

**Why it matters:** §10 must be precise enough for a future SPEC-001 v2.0 BUILD
session. Token parsing and buffering choices should not be invented during
implementation.

**Suggested fix:** Specify accepted encodings, maximum encoded and decoded
lengths, required canonical form, and rejection code for malformed or oversized
tokens.

M6. Key and token material are not forbidden in buyer errors, auth responses, or close reasons

**Location:** §6.8 lines 931-937; §7.6 lines 1121-1126; §10.5 lines 1602-1614; §10.9 lines 1688-1699.

**Finding:** The spec does not constrain buyer-visible errors, v2
`auth_response.error.message`, or WebSocket close reasons from including key
material, attestation tokens, derived secrets, expected hashes, or trust-root
details.

**Why it matters:** Even if audit logs are fixed, error paths can leak the same
material to buyers or providers. This is especially risky around attestation
and key-exchange failures.

**Suggested fix:** Add a shared Tier-2 redaction rule: errors and close reasons
MUST use generic reason codes and MUST NOT include raw keys, shared secrets,
attestation tokens, expected hashes, API keys, account IDs, `conv:` values, or
unredacted trust-root internals.

M7. Encrypted-leg downgrade/fallback logging is only SHOULD and conditional

**Location:** §6.8 lines 923-929; §12.3 lines 1843-1852; §15.2 lines 2221-2233.

**Finding:** When `tier2.require_encrypted_leg: false`, old providers remain
routable. Logging a cleartext fallback is only SHOULD and only when an encrypted
provider exists for the same model.

**Why it matters:** A provider can silently omit Pillar B support and continue
receiving cleartext traffic in observe/default modes. Operators need visibility
into downgrades before they decide to require encryption.

**Suggested fix:** Make fallback logging a MUST whenever Pillar B observation is
active for the deployment/model and a request routes over an unencrypted leg.
Keep no-op behavior only for pure Tier-1 deployments where Pillar B has not been
enabled or observed.

M8. Pillar D global flag and per-control flags conflict

**Location:** §8.2 lines 1205-1212; §8.3-8.5 lines 1214-1282; §9.3 lines 1403-1418; §11.1 lines 1730-1738; §13.3 lines 1979-1984.

**Finding:** §8.2 says `tier2.behavioral_safety_enabled: true` applies "the
controls below" to every response chunk. §11 also defines
`encoding_validation_enabled` and `response_time_anomaly_enabled` defaulting
false. §13 then defines `"partial"` and `"enforced"` based on which controls are
enabled.

**Why it matters:** Implementers cannot tell whether Pillar D is all-or-nothing,
global-plus-subflags, or three independent controls. Disclosure will diverge.

**Suggested fix:** Add a flag precedence matrix. For example: global flag enables
Pillar D framework; size cap is active when effective cap > 0; encoding and
TTFT are gated by their own subflags; disclosure maps every combination to
`none`, `partial`, or `enforced`.

M9. Completion encoding/control-character validation boundary is vague

**Location:** §8.4 lines 1242-1261.

**Finding:** The spec rejects "control characters outside `\t`, `\n`, and `\r`
in expected SSE framing" but does not define exact C0/C1 ranges, whether JSON
string escapes are allowed, or whether validation applies to decoded completion
text, SSE framing, full JSON envelopes, or raw provider frames.

**Why it matters:** Pillar D is meant to be a deterministic output filter.
Ambiguous byte/codepoint boundaries will create inconsistent false positives and
false negatives.

**Suggested fix:** Define validation targets separately for streaming and
non-streaming. State exact forbidden ranges and how escaped JSON control
characters differ from raw decoded control bytes.

M10. SPEC-001 v2.0 version negotiation is absent

**Location:** §10.1-§10.5 lines 1440-1615. Cross-check SPEC-001 §6.5 lines 1024-1041.

**Finding:** Old providers send `hello`; v2 providers send `auth_request`.
SPEC-008 does not define how a provider knows the coordinator supports v2 before
sending a different first message, nor how the coordinator distinguishes a
malformed v1 message from a v2 attempt.

**Why it matters:** Old and new providers must coexist safely during Phase 2.
Without negotiation or a deterministic first-message rule, the future SPEC-001
v2.0 session must invent protocol behavior.

**Suggested fix:** Define the v2 negotiation surface: either a coordinator
welcome/capability frame before provider auth, a versioned WS path, or an
explicit first-message dispatch rule with fallback/close behavior.

M11. `tier2.*` config reload semantics are undefined

**Location:** §5.2 lines 556-559; §11 lines 1702-1763.

**Finding:** §5.2 mentions startup or reload time for catalog signature failure,
but §11 never says which `tier2.*` keys are startup-only, hot-reloadable, or
watched, nor what happens to existing sessions when trust roots or enforcement
flags change.

**Why it matters:** Operators need to know whether enabling
`require_attestation`, rotating a catalog key, changing rekey thresholds, or
turning on Pillar D requires a coordinator restart.

**Suggested fix:** Add a config lifecycle table with type, default, validation,
reload behavior, and effect on existing provider sessions for every `tier2.*`
key.

M12. Coordinator restart behavior for encrypted sessions is undefined

**Location:** §6.9 lines 939-950; §12.3 lines 1843-1852. Cross-check SPEC-002 §4 FR-O5 lines 1284-1297.

**Finding:** Pillar B keys are per-session and in-memory, but SPEC-008 does not
say what happens to in-flight encrypted requests or provider sessions when the
coordinator restarts.

**Why it matters:** SPEC-002 says live pool routing state is in-memory and
providers reconnect after restart. Pillar B adds session keys and encrypted
in-flight payloads; restart invalidation must be specified.

**Suggested fix:** State that coordinator restart invalidates Pillar B sessions,
in-flight encrypted requests fail according to SPEC-002 timeout/disconnect rules,
providers must re-handshake and derive fresh keys, and a named T2.B event is
emitted when possible.

M13. Disclosure phase transitions and `tier2.phase` are incomplete

**Location:** §9.1 lines 1340-1344; §9.2 lines 1379-1384; §9.3 lines 1415-1418; §13.2 lines 1925-1951.

**Finding:** §13 introduces `tier2.phase: 0`, but the roadmap never defines
allowed values or when the field changes to 1, 2, or 3. This is especially
unclear because Phase 3 can be enabled independently of Phase 2.

**Why it matters:** The disclosure block is non-operator-overrideable, so it
must be mechanically derivable. Phase-number ambiguity risks inaccurate
`/v1/models` disclosures.

**Suggested fix:** Add a phase/disclosure transition table for Phase 0-3 and
mixed independent Pillar D enablement, or replace `tier2.phase` with explicit
active-pillar booleans/states only.

M14. Tier-2 predicates are not applied clearly to failover, preflight advancement, and SPEC-004 retry

**Location:** SPEC-008 §4.5 lines 477-492. Cross-check SPEC-004 §3 lines 124-168 and §4 FR-SR-3 lines 216-225; SPEC-002 §5 lines 1325-1416.

**Finding:** SPEC-008 inserts predicates after "SPEC-004 hard pins, sticky soft
preference, class resolution, retry policy," but SPEC-004 retry and SPEC-002
preflight advancement occur after initial selection. The spec does not state
that Tier-2 predicates are re-applied on every later provider choice.

**Why it matters:** A literal implementation could correctly filter the initial
candidate set, then fail over or retry to a provider that fails required hash,
encryption, or attestation.

**Suggested fix:** State that enabled Tier-2 predicates are eligibility filters
for every selection attempt: initial selection, preflight advancement, F-4
failover, SPEC-004 retry, and hard-pin validation.

M15. SPEC-001 v2.0 auth example reopens max-concurrency drift

**Location:** §10.2 lines 1468-1470. Cross-check SPEC-001 §4 FR-9 lines 389-416; Decision log Entry 24 line 277.

**Finding:** The v2 `auth_request` example advertises `"max_concurrency": 2`.
Locked SPEC-001 v1.2.4 says default advertised `max_concurrency` MUST be 1 for
all RAM tiers until parallel generation is validated.

**Why it matters:** Entry 24's H-003 finding was advertised-vs-enforced
capability drift. A future SPEC-001 v2.0 build can copy this example and regress
the locked fix.

**Suggested fix:** Change the example to `max_concurrency: 1`, or annotate
values above 1 as explicit operator overrides requiring runtime validation.

M16. Default-preservation AC is too narrow

**Location:** §14 AC-T2-5 lines 2065-2070.

**Finding:** AC-T2-5 checks byte-identical buyer-visible responses for
`/v1/models` and `/v1/chat/completions`, but not routing decisions, audit logs,
absence of Tier-2 fields, or log silence under no-config deployment.

**Why it matters:** It would not catch C1's default-behavior regression.

**Suggested fix:** Expand AC-T2-5 to assert unchanged provider selection,
unchanged response shape and headers, no Tier-2 audit/log events, and no
additional `/v1/models` fields under default config.

M17. TTFT anomaly AC conflicts with the default minimum threshold

**Location:** §8.5 lines 1269-1276; §11.1 lines 1736-1738; §14 AC-T2-21 lines 2155-2158.

**Finding:** §8.5 defines the TTFT anomaly threshold as
`max(response_time_anomaly_min_ms, model_load_time_ms * factor)`. §11 defaults
`response_time_anomaly_min_ms` to 10000, but AC-T2-21 expects a warning above
5000 ms with a 1000 ms baseline and factor 5.

**Why it matters:** The acceptance test will fail against the spec defaults or
force implementers to ignore the minimum threshold.

**Suggested fix:** Set `response_time_anomaly_min_ms: 0` or `5000` in AC-T2-21's
setup, or change the expected TTFT threshold to above 10000 ms.

### MINOR findings

m1. Survivability section needs exact citation and conclusion traceability polish

**Location:** §2.1 lines 158-168; §2.2 lines 205-208; §2.3 lines 236-239; §2.4 lines 264-267; §2.5 lines 282-295.

**Finding:** The survivability substance is sound, but the Tier-1 mechanism
paragraphs do not consistently cite exact source sections, and §2.5 does not
reference the cleared invariants explicitly by letters (a)-(d).

**Why it matters:** This does not block v0.1, but the survivability certificate
is a high-value proof surface and should be easy to audit mechanically.

**Suggested fix:** Add exact references to SPEC-006 §1.3, SPEC-006 §F-1.5,
SPEC-004 §4, and enumerate conclusion bullets as invariants (a)-(d).

### Operator questions surfaced

q1. What is the catalog trust model and public-key provenance?

**Location:** §5.2 lines 516-564; §11.1 lines 1711-1715.

**Finding:** The catalog is signed and verified with
`tier2.catalog_public_key`, but the trust model for that key is not explicit:
operator-supplied trust-on-first-use, pinned by distribution, external authority,
or some other governance model.

**Why it matters:** This may be acceptable under the coordinator-operator trust
model, but it should be explicit before Pillar A is implemented.

**Suggested fix:** Operator decision. State the key format, source of trust, key
rotation model, and whether a compromised operator/catalog key is in or out of
scope.

### Verdict

**READY WITH FIX PASS.** The CRITICAL findings are narrow and fixable in a
SPEC-008 v0.2 pass; I did not find an architectural CRITICAL that requires
reopening the locked four-pillar/three-phase design. Phase 1 BUILD should wait
until the default-preservation and audit-secret-hygiene fixes are landed and
AC-T2-5 is expanded.

### Self-verification

- Read every section of SPEC-008 v0.1 and all 26 ACs.
- Compared SPEC-008 §§1-2 and §§5-8 against BUILD prompt locked architecture and hard rules.
- Walked Categories A through N; category results are summarized above.
- Severity chosen against the audit prompt definitions.
- Locations include section and line ranges.
- Suggested fixes included for both CRITICAL findings.
- Checked §10 wire annotations for SPEC-001 v2.0 precision.
- Checked §11 defaults and default-preservation claims.
- Checked §13 partial-pool disclosure and non-override rule.
- Checked §12/§15 audit field hygiene for sensitive data exposure.

## Round 2 (Claude, 2026-05-31T07:44:10Z)

### Summary
- 1 CRITICAL finding
- 4 MAJOR findings
- 5 MINOR findings
- 2 QUESTIONS

Operating mode: started THOROUGH; did NOT escalate to ADVERSARIAL. The v0.2 fix
pass is substantively competent — Round 1's 2 CRITICAL and 17 MAJOR are largely
and genuinely resolved (see Fix-pass verification). The single CRITICAL I raise
is a contract-precision defect introduced/left by the fix pass in the exact place
it was meant to be closed (default-preservation disclosure), not a new
architectural break. No survivability-invariant violation, no scope creep into a
locked spec, no defaulted-true flag.

### Round 2 notes on Round 1

**Findings I confirm (resolved or correctly identified):**
- C1 (default-config activates Tier-2 behavior): real in v0.1; the `observe_enabled`
  gate (§4.3, §11.2 line 2084-2090) is the correct fix mechanism. Confirmed the
  approach, but it left one residual defect — see my C1 below.
- C2 (audit hygiene omitted key material): correctly identified; fully fixed in
  §12.1 lines 2177-2182 and AC-T2-25.
- M1 (hash-mismatch routing contradiction): real; §5.5/§5.6 are now consistent
  (mismatch/invalid always excluded when catalogued; permissive only for
  `uncatalogued`/`catalog_unavailable`). Resolved.
- M3, M4, M5, M6, M10, M12, M13, M16, M17: all correctly identified and resolved.
- M15 (max_concurrency drift): confirmed real and fixed — §10.2 line 1763 now reads
  `"max_concurrency": 1` with the SPEC-001 v1.2.4 §FR-9 annotation. Verified against
  Decision log Entry 24 H-003 and SPEC-001 v1.2.4.
- m1 (survivability citation polish): confirmed; v0.2 improved citations but
  introduced two inaccurate section numbers — see my m1 below.

**Findings I disagree with / refine:**
- None of Round 1's findings are wrong. Round 1's verdict (READY WITH FIX PASS) was
  sound. My only divergence is that I hold one residual CRITICAL open where Round 1
  would likely now mark C1 fully closed; the `observe_enabled` gate is correct but
  §13.2 + AC-T2-5 reintroduce a byte-identity ambiguity at the disclosure layer.

**New findings Round 1 missed (present in both v0.1 and v0.2, or fix-pass-introduced):**
- N-C1: AC-T2-5 forbids the `tier2_milestone` field under default config, but
  `tier2_milestone` is part of the LOCKED SPEC-006 v0.8 baseline. The byte-identity
  AC contradicts itself. (CRITICAL — see below.)
- N-M1: §13.2 prose ("byte-identical to the SPEC-006 Tier-1 baseline") contradicts
  the example block shown directly beneath it (version bumped to
  `"v0.8+tier2-v0.2"` + full `tier2` object present).
- N-M2: §8.6 disclosure value `"enforced"` overstates §8.5, which makes TTFT logging
  a SHOULD, not a MUST. Non-overrideable disclosure can claim more than is enforced.
- N-m: §2.1/§2.3 cite section numbers that do not exist in SPEC-006 v0.8.1
  (`§F-1.5`, `§5.3.4`).

### Category sweep

| Category | Result |
|---|---|
| A Additive/default preservation | Finding C1 (AC-T2-5 self-contradiction), M1 (§13.2 prose/example) |
| B Survivability audit | m1 only (citation accuracy); no invariant violation; §2 substantively correct vs SPEC-006 §1.3 + SPEC-004 §2/§4 |
| C Pillar A | No new findings; M1(R1) resolved; catalog/hash/routing precise |
| D Pillar B | m2 (response AAD field-omission note); §6.4-6.7.1 now complete |
| E Pillar C | m3 (attestation `"unsupported"` vs `"none"` disclosure overlap); otherwise resolved |
| F Pillar D | M2 (`"enforced"` overstates SHOULD TTFT); m4 (validation key naming) |
| G Phase roadmap | No findings; computed phase model (§13.2) resolves R1 M13 |
| H SPEC-001 v2.0 annotations | No new findings; first-message dispatch §10.1.1 resolves R1 M10; max_concurrency fixed |
| I Configuration | M3 (§11.2 validation references helper key, not active key); lifecycle table §11.5 resolves R1 M11 |
| J Observability/audit | No new findings; key-material ban + challenge_id rule complete |
| K Disclosure protocol | C1, M1 (default-preservation byte-identity); partial-pool case correct |
| L Acceptance criteria | C1 (AC-T2-5 defect); count is exactly 26 |
| M Cross-spec coherence | m1 (stale citations); no sticky/provider-side regression; SPEC-002 namespace clean (T2.* distinct from I/J) |
| N Security properties | No findings; replay, nonce-uniqueness, key-binding, redaction all normative |

### CRITICAL findings

C1. AC-T2-5 forbids `tier2_milestone`, a field that is part of the LOCKED SPEC-006 baseline — the byte-identity gate contradicts itself

    **Location:** §14 AC-T2-5 (line 2458-2459). Cross-check SPEC-006 v0.8.1 §5.3.1 (`tier1_disclosure` baseline, line 985 — `"tier2_milestone": "future"`).
    **Finding:** AC-T2-5 requires, under default config, that "no Tier-2 fields
    (`hash_verified`, `hash_verification`, `attested`, `attestation`,
    `tier2_session`, `tier2_milestone`) appear in any response," AND that
    "`/v1/models` response bytes are identical to the Tier-1 baseline." But
    `tier2_milestone: "future"` is a MANDATORY field of the SPEC-006 v0.8.1
    Tier-1 baseline (`tier1_disclosure` block, SPEC-006 §5.3.1 line 985; operator
    override forbidden there). The two clauses of AC-T2-5 are mutually exclusive:
    a response cannot be byte-identical to a baseline that contains
    `tier2_milestone` while also omitting `tier2_milestone`.
    **Why it matters:** AC-T2-5 is THE gate that proves additive-only / no Tier-1
    regression — the highest-priority audit category (A) and the audit prompt's
    CRITICAL bar ("silent regression of Tier-1 behavior"). An implementer who makes
    AC-T2-5 pass literally must strip `tier2_milestone` from the default
    `/v1/models` response, which breaks byte-identity with the locked SPEC-006
    contract and removes a Tier-1 disclosure field on binary upgrade. The defect
    lives inside the very test meant to prevent this class of regression, so it
    would pass a Tier-1-breaking implementation rather than catch it.
    **Confidence:** HIGH. Direct factual contradiction verified against locked
    SPEC-006 text.
    **Realist check:** Worst case is a real Tier-1 disclosure-field regression
    shipped through a passing AC. Detection is NOT fast because the AC is the
    detector and it is the thing that is wrong. No data loss / security / financial
    impact, and the fix is a one-line edit — but per the audit's own severity
    definition (silent Tier-1 regression) this earns CRITICAL. Not downgraded.
    **Suggested fix:** Remove `tier2_milestone` from the forbidden-field list in
    AC-T2-5 (it is a baseline field, not a Tier-2-evidence field). Keep the other
    five forbidden fields. Optionally restate AC-T2-5 as: under default config, the
    `tier1_disclosure` block contains EXACTLY the SPEC-006 v0.8.1 baseline keys
    (`version: "v0.8"`, `plaintext_to_provider`, `model_identity`,
    `hardware_attestation`, `tier2_milestone`, `sticky_affinity`) and NONE of the
    additive Tier-2 keys (`model_hash_verified`, `provider_leg_encryption`,
    `untrusted_provider_safety`, `tier2`), and the `version` string is unchanged
    from `"v0.8"`.

### MAJOR findings

M1. §13.2 prose claims byte-identical default disclosure, but the example block beneath it is NOT byte-identical to the SPEC-006 baseline

    **Location:** §13.2 (lines 2267-2317). Cross-check SPEC-006 v0.8.1 §5.3.1
    (lines 980-992).
    **Finding:** §13.2 states `"With default config, the disclosure block MUST
    remain byte-identical to the SPEC-006 Tier-1 baseline."` The JSON example shown
    immediately under that sentence sets `"version": "v0.8+tier2-v0.2"` (the
    SPEC-006 baseline is `"version": "v0.8"`) and includes the additive
    `model_hash_verified`, `provider_leg_encryption`, `untrusted_provider_safety`
    fields plus the full `tier2` sub-object. The example is unlabeled — an
    implementer cannot tell whether this block is the default-config render
    (contradicting the byte-identity sentence) or the observe/active render. The
    `"v0.8+tier2-v0.2"` version string alone guarantees the example is NOT
    byte-identical to baseline, so if it is the default render the spec is
    self-contradictory; if it is the active render it is mislabeled.
    **Why it matters:** This is the precise default-preservation surface Round 1 C1
    targeted. The `observe_enabled` gate (§4.3) is correct, but §13.2's example
    reintroduces ambiguity at the disclosure layer: two competent implementers will
    diverge on whether the version string bumps and the `tier2` object appears under
    default config.
    **Confidence:** HIGH (direct quote vs locked baseline).
    **Realist check:** Detected at implementation/review time if the reviewer
    cross-checks SPEC-006; contained because §4.3's normative gate is unambiguous.
    Stays MAJOR (predictable implementer confusion + drift), not CRITICAL, because
    §4.3 provides a correct normative anchor that overrides the example. Mitigated
    by: §4.3 + §11.2 + §13.2-intro all forbid default-config changes; only the
    illustrative example is wrong.
    **Fix:** Label the §13.2 example "active-state (observe or enforcement) example"
    and add a separate explicit default-config example that is byte-identical to
    SPEC-006 (version `"v0.8"`, no `tier2` object, no additive state fields). State
    that the `version` string MUST remain `"v0.8"` until §4.3 permits Tier-2
    response changes.

M2. Disclosure value `"enforced"` (§8.6) overstates §8.5, which makes TTFT logging only a SHOULD

    **Location:** §8.6 matrix + closing paragraph (lines 1539-1546); §8.5
    (lines 1507-1510, "the coordinator SHOULD log a WARN audit event"); §13.3
    (lines 2361-2366, non-overrideable `untrusted_provider_safety` values).
    **Finding:** §8.6 maps the combination (size cap > 0, encoding on, TTFT on) to
    `untrusted_provider_safety: "enforced"`. But §8.5 specifies TTFT anomaly logging
    as a SHOULD, and explicitly says "an anomaly is a signal, not a failure" and the
    coordinator "SHOULD NOT reject." So `response_time_anomaly_enabled: true` enables
    a best-effort signal, yet the disclosure asserts `"enforced"`. The disclosure
    block is non-operator-overrideable and governed by the §1.4 north-star ("never
    claim more ... than the enabled Tier-2 pillars actually enforce"). `"enforced"`
    implies a hard guarantee that §8.5 does not provide.
    **Why it matters:** The disclosure is a buyer-trust surface with a CRITICAL
    non-override protection. Claiming `"enforced"` when one of the three controls is
    a SHOULD-level signal is exactly the expectation-drift class SPEC-008 exists to
    close (Decision log Entry 24 H-001).
    **Confidence:** MEDIUM. The author could argue `"enforced"` describes
    configuration state (all three controls switched on), not enforcement strength.
    But the field name `untrusted_provider_safety` and the north-star rule push
    toward enforcement-strength semantics.
    **Fix:** Either rename the strongest state to `"all_controls_enabled"` (config
    semantics, honest), or upgrade §8.5 TTFT logging to a MUST when
    `response_time_anomaly_enabled: true` so `"enforced"` is truthful, or define
    `"enforced"` as "size cap + encoding validation enforced; TTFT anomaly logging
    enabled (best-effort signal)" so the weaker guarantee is explicit.

M3. §11.2 startup validation gates on the helper key, not the active cap key — Pillar D enable path is under-validated and the rule reads as a contradiction

    **Location:** §11.2 (lines 2076-2077: "Startup MUST fail when
    `behavioral_safety_enabled: true` and `default_output_size_cap_bytes <= 0`").
    Cross-check §8.3 (lines 1435-1446) and §11.1 (lines 2048-2050).
    **Finding:** The validation references `default_output_size_cap_bytes` (a
    non-binding helper, default 1048576) rather than `output_size_cap_bytes` (the
    key that actually activates the cap, default 0). Per §8.3, `behavioral_safety_enabled: true`
    with `output_size_cap_bytes: 0` is explicitly valid (size cap disabled; matrix
    row 2 → `"none"`). So the §11.2 rule never meaningfully fires against the active
    cap, and an operator can enable Pillar D with the size cap fully disabled while
    startup validation only inspects the inert helper. The rule appears to intend to
    prevent "Pillar D on but cap misconfigured," yet it inspects the wrong key.
    **Why it matters:** Predictable implementer confusion: which key gates the
    size-cap control? §8.3 and §11.2 point at different keys. An implementer could
    wire startup failure to the wrong key and reject valid observe/partial
    deployments, or believe the cap is validated when it is not.
    **Confidence:** HIGH (direct cross-reference).
    **Fix:** Clarify §11.2 intent. If the goal is "helper must be sane when set,"
    state that. If the goal is "active cap must be positive when size-cap control is
    relied upon," gate on `output_size_cap_bytes > 0` and reconcile with §8.3's
    explicit allowance of `output_size_cap_bytes: 0` under
    `behavioral_safety_enabled: true`.

M4. §7.7 `attested: "unsupported"` and §13.3 `hardware_attestation` overload "unsupported"/"none" without a deterministic mapping for the not-required-but-present case

    **Location:** §7.7 (lines 1363-1368: `"unsupported"` when "every currently
    routable provider is unsupported OR not required"); §13.3 (lines 2354-2359:
    `hardware_attestation` ∈ none/unsupported/partial/all). Cross-check §13.2 default
    example (line 2277: `"hardware_attestation": "none"`).
    **Finding:** §7.7's per-model `attested` collapses "all unsupported" and "not
    required" into the same `"unsupported"` value, while §13.3's top-level
    `hardware_attestation` offers BOTH `"none"` and `"unsupported"`. The spec never
    defines the deterministic boundary: when Pillar C observation is active,
    `require_attestation: false`, and providers present no token — is the disclosure
    `"none"` or `"unsupported"`? Both are plausible under the prose, but the
    disclosure is non-overrideable and MUST be mechanically derivable.
    **Why it matters:** Two implementations will render different
    non-overrideable disclosure for the identical pool state, undermining the
    "mechanically derivable" property that the non-override guarantee depends on.
    **Confidence:** MEDIUM.
    **Fix:** Add an explicit truth table mapping (Pillar C active? require?
    attested-count / unsupported-count / failed-count) → exact
    `hardware_attestation` value, mirroring §8.6's matrix discipline for Pillar D.

### MINOR findings

m1. §2 cites SPEC-006 section numbers that do not exist in v0.8.1.
    §2.1 (line 168) cites "SPEC-006 §1.3 and SPEC-006 §F-1.5"; §2.3 (line 246)
    cites "SPEC-006 §5.3.4". SPEC-006 v0.8.1 has no numbered "§F-1.5" header (F-1.5
    is the informal name of the survivability clause embedded in §1.3) and no
    "§5.3.4" (DELETE /v1/sticky is normatively defined in the §1.3 region around
    line 1119; sticky disclosure is §5.3.1). The SUBSTANCE of §2 is accurate — the
    HMAC derivation in §2.1 matches SPEC-006 §1.3 lines 165-172 (scope ‖ account_id
    ‖ buyer_tag, HMAC-SHA256, `conv:` + unpadded base64url), and the DELETE/TTL/
    coordinator-internal claims are correct. Only the citation labels are wrong.
    Fix: cite "SPEC-006 §1.3 (F-1.5 survivability clause)" and "SPEC-006 §1.3
    (DELETE /v1/sticky)".

m2. §6.5.2 response AAD omits the `assigned_id`/`provider_id` symmetry note that
    request AAD has, and the §10.7 encrypted-chunk example does not restate that
    `direction: "p2c"` is authenticated. Both parties must commit to identical AAD;
    the spec is correct but a one-line "both directions authenticate
    `provider_id` + `assigned_id` + `direction`" cross-note would prevent decoder
    drift.

m3. §11.1 helper keys `output_bytes_per_token_ceiling` and
    `default_output_size_cap_bytes` are easy to confuse with the active
    `output_size_cap_bytes`. Consider renaming to `*_recommended_*` to signal they
    never activate enforcement (ties to M3).

m4. Shadow mode is referenced four times (§9.3 line 1684, §11.4 line 2117, §12.5
    line 2230, §15.4 line 2679) as conditional ("if implemented", "when a shadow
    mode exists") but never normatively defined. Acceptable for v0.2 (it is opt-in
    and optional), but a one-line "shadow mode is out of normative scope for v0.2"
    statement would prevent an implementer from inferring a requirement.

m5. §8.5 / AC-T2-21: the production default `response_time_anomaly_min_ms: 10000`
    plus `response_time_anomaly_factor: 5.0` means a provider with a 1000 ms
    baseline never trips below 10000 ms TTFT. This is sensible noise control, but no
    guidance ties the floor to realistic Apple-Silicon cold-start TTFT; an operator
    enabling the control blind could set a floor that never fires. Advisory only.

### Operator questions surfaced

q1. Disclosure version string policy. Should the `tier1_disclosure.version` field
    bump to `"v0.8+tier2-v0.2"` only when §4.3 permits Tier-2 response changes (so
    default deployments keep `"v0.8"` for byte-identity), or always once a SPEC-008
    binary is deployed? The byte-identity rule (§13.2, AC-T2-5) requires the former,
    but the §13.2 example shows the bumped string unconditionally. Operator decision;
    drives the C1/M1 fix.

q2. `"enforced"` disclosure semantics (ties to M2). Is
    `untrusted_provider_safety: "enforced"` intended to mean "all three controls
    configured on" (config state) or "all three controls provide hard enforcement"
    (guarantee state)? §8.5's SHOULD-level TTFT makes the latter untrue. Operator
    must choose which semantics the non-overrideable disclosure asserts.

### Fix-pass verification

- C1 (default config activates Tier-2 API/audit behavior) — PARTIALLY RESOLVED.
  Evidence: §4.3 (lines 479-491) + §11.2 (lines 2084-2090) add the `observe_enabled`
  gate and a clean normative "MUST NOT compute / emit / change / add unless one of
  {catalog_path non-empty, any require_* true, behavioral_safety_enabled, observe_enabled}"
  rule. This correctly closes the routing/audit/computation surface. RESIDUAL: the
  DISCLOSURE surface reintroduces a byte-identity defect — AC-T2-5 forbids the
  baseline `tier2_milestone` field (my C1) and §13.2's example bumps `version` and
  shows the `tier2` object without labeling it active-state (my M1). The gate
  mechanism is right; the disclosure example + AC are wrong.

- C2 (audit hygiene omits key material) — RESOLVED.
  Evidence: §12.1 (lines 2177-2182) now bans ECDH private keys, X25519 shared
  secrets, HKDF PRK/OKM, AEAD keys, per-frame nonces (beyond `kid`), raw attestation
  token bytes/JWS body, raw challenge bytes, trust-root material. AC-T2-25 updated to
  test these absences. §4.7 adds a parallel redaction rule for errors/close reasons.

- M1 (hash-mismatch routing contradiction) — RESOLVED.
  Evidence: §5.5 (lines 727-734) + §5.6 (lines 737-742) consistently make
  `hash_mismatch`/`hash_invalid` routing-ineligible when catalogued; permissive only
  for `uncatalogued`/`catalog_unavailable`. No residual contradiction.

- M2 (under-specified error envelopes) — RESOLVED.
  Evidence: §4.6 error table (lines 551-561) gives code, HTTP status, `error.type`,
  message template, and streaming-commit behavior for all 9 Tier-2 errors.

- M3 (response AAD undefined) — RESOLVED.
  Evidence: §6.5.2 (lines 990-1014) defines the p2c `inference_response_chunk` AAD
  schema with the same forbidden-field list as c2p. (See minor m2 for a clarity nit.)

- M4 (AEAD decrypt-failure behavior missing) — RESOLVED.
  Evidence: §6.7.1 (lines 1066-1088) defines pre-commit (log, no unauthenticated
  bytes, close/quarantine, 502 `tier2_aead_decrypt_failed`, failover only for
  non-hard-pin) and post-commit (SSE error event, close stream, no retry) handling.

- M5 (attestation token encoding/length imprecise) — RESOLVED.
  Evidence: §7.4 (lines 1285-1297) + §10.4 (lines 1858-1867) specify accepted
  encodings (base64url DER/CBOR, or compact JWS exactly 3 segments), 16384-byte max,
  and `tier2_attestation_token_too_large` / `tier2_attestation_token_invalid` codes.

- M6 (key/token material not forbidden in errors/close reasons) — RESOLVED.
  Evidence: §4.7 (lines 568-580) + §10.5 (lines 1919-1921) + §10.9 (lines 2008-2011)
  add the redaction rule to buyer errors, `auth_response.error.message`, and WS close
  reasons.

- M7 (downgrade/fallback logging only SHOULD/conditional) — RESOLVED.
  Evidence: §6.8 (lines 1098-1106) makes T2.B fallback logging a MUST whenever Pillar
  B config is non-default or an encrypted provider exists for the model, and keeps the
  no-op only for pure Tier-1 deployments.

- M8 (Pillar D global vs per-control flag conflict) — RESOLVED.
  Evidence: §8.6 flag precedence matrix (lines 1532-1546) maps every combination to
  none/partial/enforced. (See my M2 for the `"enforced"` honesty nit and M3 for the
  validation-key nit — both refinements, not the original conflict.)

- M9 (encoding/control-char boundary vague) — RESOLVED.
  Evidence: §8.4 (lines 1478-1496) defines exact forbidden ranges (C0 except
  TAB/LF/CR, U+007F, C1 U+0080-U+009F), separates streaming vs non-streaming targets,
  and handles JSON `\uXXXX` escapes vs raw bytes and SSE framing.

- M10 (v2.0 version negotiation absent) — RESOLVED.
  Evidence: §10.1.1 (lines 1724-1737) first-message dispatch rule: `auth_request`+v2
  → v2 flow; `hello`+v1 → Tier-1; else close 4000. Coordinator sends no frame first.

- M11 (config reload semantics undefined) — RESOLVED.
  Evidence: §11.5 lifecycle table (lines 2125-2139) gives per-key reload behavior and
  effect on existing sessions; startup-only vs hot-reloadable is explicit.

- M12 (coordinator restart for encrypted sessions undefined) — RESOLVED.
  Evidence: §6.10 (lines 1132-1149) defines key invalidation, in-flight pre/post-commit
  handling, mandatory re-handshake, and `coordinator_restart_session_invalidated` event.

- M13 (disclosure phase transitions / `tier2.phase` incomplete) — RESOLVED.
  Evidence: `tier2.phase` removed from config; §13.2 (lines 2322-2337) defines computed
  values 0/1/2/3/"mixed" with derivation conditions, including independent Pillar D
  ("mixed"). §11.5 marks `phase` computed/read-only.

- M14 (predicates not re-applied on failover/preflight/retry) — RESOLVED.
  Evidence: §4.5 (lines 525-538) states enabled predicates are eligibility filters
  re-applied on preflight advancement, F-4 failover, SPEC-004 retry, and hard-pin
  validation — "not re-admitted because previously considered."

- M15 (max_concurrency example reopens drift) — RESOLVED.
  Evidence: §10.2 line 1763 now `"max_concurrency": 1` with the
  "default: 1 per SPEC-001 v1.2.4 §FR-9; increase only after parallel-generation
  validation" annotation. Verified against SPEC-001 v1.2.4 and Entry 24 H-003.

- M16 (default-preservation AC too narrow) — RESOLVED in scope, but the EXPANDED AC
  is itself defective. Evidence: AC-T2-5 (lines 2449-2459) now asserts unchanged
  provider selection, byte-identical `/v1/models` and `/v1/chat/completions`, no
  `T2.*` events, and no Tier-2 fields. This is the correct expansion Round 1 asked
  for — BUT the field list erroneously includes `tier2_milestone` (a baseline field),
  making the AC self-contradictory (my C1). The breadth fix landed; a factual error
  rode in with it.

- M17 (TTFT AC vs default threshold conflict) — RESOLVED.
  Evidence: AC-T2-21 (lines 2548-2554) sets `response_time_anomaly_min_ms: 0`
  explicitly and notes production MAY raise it; config default is 10000 (§11.1 line
  2054). No conflict remains.

- m1 (survivability citation/conclusion polish) — PARTIALLY RESOLVED.
  Evidence: §2.5 (lines 295-304) now enumerates cleared invariants (a)-(d) explicitly.
  RESIDUAL: §2.1/§2.3 introduce two non-existent SPEC-006 section numbers (§F-1.5,
  §5.3.4) — see my m1. Substance correct; labels wrong.

- q1 (catalog trust model / key provenance) — RESOLVED.
  Evidence: §5.2.1 (lines 653-666) defines trust-on-first-config, Ed25519 32-byte
  base64url key, operator-pinned, no CA/revocation, rotation via restart, compromised
  key in scope for operator rotation / out of scope for auto-mitigation in v0.2.

### Verdict

**READY WITH FIX PASS.** The v0.2 fix pass genuinely closed Round 1's 2 CRITICAL
and all 17 MAJOR findings; the architecture, survivability audit (§2), default-gate
mechanism (§4.3 `observe_enabled`), key-material hygiene, Pillar B wire detail, and
phase/disclosure model are sound and cross-spec-consistent. I found no
architectural CRITICAL, no F-1.5 invariant violation, no scope creep into a locked
spec, and no defaulted-true flag.

The single CRITICAL (C1) is a one-line self-contradiction inside AC-T2-5 — it
forbids the locked SPEC-006 baseline field `tier2_milestone` while also demanding
byte-identity with that baseline. Paired with M1 (§13.2's mislabeled example) and
M2 (`"enforced"` overstating a SHOULD), these are all closable in a narrow
SPEC-008 v0.3 fix pass touching §13.2, §14 AC-T2-5, §8.6/§8.5, §11.2, and the §2
citations. None require reopening the locked four-pillar/three-phase design.

Phase 1 BUILD (Pillar A) should wait until C1 and M1 land, because both touch the
default-preservation disclosure surface that Phase 1 implements first. M2, M3, M4,
and the minors can be folded into the same pass or deferred to the Phase 2 spec
window without blocking Phase 1.

### Self-verification
- Read every section of SPEC-008 v0.2 (§§0-16, all 26 ACs) including the truncated
  tail (§11.2-§16) on a second read.
- Verified §2 survivability claims against SPEC-006 v0.8.1 §1.3 (HMAC derivation
  lines 165-172, DELETE /v1/sticky line 1119) and SPEC-004 v0.3.1 §2 (line 109
  Tier-2 out-of-scope) and §4 (line 217 sticky→provider_id).
- Verified M15 fix against SPEC-001 v1.2.4 §FR-9 and Decision log Entry 24 H-003.
- Verified SPEC-002 audit namespace (categories I/J) does not collide with T2.A-D.
- Confirmed C1 by reading the SPEC-006 §5.3.1 baseline (`tier2_milestone` line 985).
- Ran Self-Audit (moved nothing below confidence bar; C1/M1 HIGH, M2/M4 MEDIUM with
  counter-arguments stated) and Realist Check (C1 held at CRITICAL; M1 held at MAJOR
  with §4.3 as mitigating anchor).
- Severity chosen against the audit prompt definitions; locations by section number
  (primary) plus line ranges (v0.2 numbering).
