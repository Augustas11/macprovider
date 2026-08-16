# Cross-spec patches v0.3/v1.1.4/v0.6 regression audit

Auditor: Codex GPT-5.5

Spec set audited:
- `specs/SPEC-006-buyer-api.md` v0.3
- `specs/SPEC-002-coordinator.md` v1.1.4
- `specs/SPEC-003-open-onboarding.md` v0.6
- `specs/SPEC-001-phase3-binary.md` v1.2.2 header only

Reference inputs:
- `specs/SPEC-CROSS-006-audit.md`
- `specs/FIX_SPEC_CROSS_006_PROMPT.md`
- `specs/SPEC-006-v0-2-audit.md`

Audit scope: narrow regression check for the cross-spec patch landed at commit `990a07e`. This report verifies only the v0.2 -> v0.3, v1.1.3 -> v1.1.4, and v0.5 -> v0.6 delta, plus the SPEC-001 untouched constraint. It does not re-audit unchanged corpus sections.

## Summary

- 0 CRITICAL findings
- 2 MAJOR findings
- 0 MINOR findings
- Overall verdict: READY WITH NARROW FIX

The coordinated patch mostly landed cleanly. Dependency lines are synchronized, SPEC-001 is untouched, `/v1/pool/check` remains coordinator-owned, request correlation is now explicit, disconnect settlement is gateway-estimated, gateway config can reach `/poolz`, response header scrubbing is explicit, and SPEC-003 installer text points to `coordinator.malibu.tech`.

Two narrow regressions remain. First, the per-model `degraded` rule is not where the patched specs say it is: SPEC-006 cites SPEC-002 § 7.5, while SPEC-002 defines the rule under the buyer-side `/v1/models` text, and SPEC-006 repeats the rule instead of only referencing it. Second, the AC-26 through AC-37 cleanup is materially improved but still not complete: several AC success/alternate branches still lack explicit status and body shapes.

## Closure verification (Category A, 19 items)

### SPEC-006 v0.3 (11 items)

- F-606-1: CLOSED. § 5.4 and § 8.3 explicitly require outbound stripping of `X-MacProvider-Provider`, `X-MacProvider-Route`, and undocumented `X-MacProvider-*` response headers.
- F-606-2: CLOSED. § 7.2 and § 17.7 specify `ceil(bytes_emitted_so_far / 4)` and mark client disconnect as gateway-estimated.
- F-606-3: PARTIAL. § 5.6 references SPEC-002 v1.1.4 § 7.5 and then repeats the degraded rules. SPEC-002's actual rule is not in § 7.5. See Major M1.
- F-606-4: CLOSED. § 15.2 includes `coordinator.operator_url`, `coordinator.operator_key`, and `coordinator.poolz_poll_interval_s`, with startup failure for missing operator URL/key.
- F-606-5: CLOSED. § 17.4 normalizes 502 to `type: "api_error"` and `code: "upstream_provider_error"`.
- F-606-6: CLOSED. § 19 adds SPEC-003 v0.6 shell-script integration-test inheritance as audit category U.
- F-606-7: CLOSED. § 1.5 allows coordinated cross-spec audit/fix cycles while preserving the ban on unilateral SPEC-006 upstream edits.
- F-606-8: CLOSED. § 5.6 specifies 10s `/poolz` cache TTL and flush-on-unreachable/error.
- AC-26 method fix: CLOSED. AC-26 now uses `GET /auth/github/callback`.
- AC-27 latency proof: CLOSED. AC-27 now polls every 5s and fails if first 403 arrives only at T+65s.
- AC-26..AC-37 status/body/curl coverage: PARTIAL. Every AC now has `curl -i`, but several still lack explicit status/body shapes for alternate branches. See Major M2.

### SPEC-002 v1.1.4 (6 items)

- F-602-1: CLOSED. § 7.2 requires honoring inbound `X-Request-ID`, recording it in `request_log`, preserving it as `inference_request.request_id`, and generating UUID v4 only for legacy direct traffic.
- F-602-2: CLOSED. § 7.4 defines public coordinator-owned `GET /v1/pool/check`; § 7.6 documents nginx route split.
- F-602-3: PARTIAL. The degraded rule exists, but it is under the buyer-side `/v1/models` text, not § 7.5 as referenced by SPEC-006. See Major M1.
- F-602-4: CLOSED. The dependency line is `SPEC-001 v1.2.2`.
- F-602-5: CLOSED. FR-O2 `/poolz` includes a `summary` block and `by_model` counts separate from detailed `pool`.
- F-602-6: CLOSED. § 7.6 states the buyer port 8443 must rebind to `127.0.0.1` when gateway is co-deployed.

### SPEC-003 v0.6 (2 items)

- F-603-1: CLOSED. § 5 says the installer calls `https://coordinator.malibu.tech/v1/pool/check?...`, cites SPEC-002 v1.1.4 § 7.4, and forbids using `api.malibu.tech` for that path.
- F-603-2: CLOSED. The dependency line is `SPEC-001 v1.2.2, SPEC-002 v1.1.4`.

## Cross-spec coherence (Category B)

- D-CROSS-1: CLOSED. SPEC-006 § 7.2 and § 17.7 agree on gateway estimation using `ceil(bytes_emitted_so_far / 4)`, and both mention a future SPEC-001 v1.2.3 candidate for provider-reported partial usage.
- D-CROSS-2: CLOSED. SPEC-002 § 7.4 owns `/v1/pool/check`, SPEC-002 § 7.6 routes it to coordinator, SPEC-006 does not claim it as a gateway path, and SPEC-003 calls `coordinator.malibu.tech`.
- D-CROSS-3: CLOSED. SPEC-006 generates and forwards UUID v4 `X-Request-ID`; SPEC-002 honors it and records it in `request_log`.
- D-CROSS-4: PARTIAL. The rule is substantively consistent, but the authoritative section reference and no-redefinition discipline did not land cleanly. See Major M1.
- D-CROSS-5: CLOSED. SPEC-006 § 10.6 states capacity tiers are independent from SPEC-002 admission tiers and forbids cascades.
- D-CROSS-6: CLOSED. SPEC-006 § 5.4 frames `logprobs` as accepted/forwarded/model-dependent and relies on SPEC-001 v1.2.2 unknown-field tolerance; SPEC-001 and SPEC-002 field tables remain otherwise unchanged.

## Dependency synchronization (Category C)

- C.1 SPEC-006: PASS. Line 4 says `SPEC-001 v1.2.2, SPEC-002 v1.1.4, SPEC-003 v0.6`.
- C.2 SPEC-002: PASS. Line 4 says `SPEC-001 v1.2.2`.
- C.3 SPEC-003: PASS. Line 4 says `SPEC-001 v1.2.2, SPEC-002 v1.1.4`.
- C.4 SPEC-001: PASS. `git diff --exit-code 990a07e^ 990a07e -- specs/SPEC-001-phase3-binary.md` is empty, and the header remains v1.2.2.

## New normative text quality (Category D)

- D.1 nginx block: PASS. The route split uses valid `location` directives and `proxy_pass` targets for gateway, coordinator buyer port, and coordinator provider port.
- D.2 gateway.yaml schema: PASS. The added `coordinator:` object is valid YAML and does not contradict `coordinators[].base_url`; the text distinguishes inference forwarding from `/poolz` control-plane access.
- D.3 502 envelope: PASS. SPEC-006 § 17.4 uses OpenAI-shaped 502 terminology with `type: "api_error"` and `code: "upstream_provider_error"`.
- D.4 AC quality: PARTIAL. The ACs are much stronger than v0.2, but some alternate branches remain hand-wavy. See Major M2.

## Scope discipline (Category E)

- E.1 New normative content beyond closed findings: PASS. The spec deltas map to F-606, F-602, F-603, D-CROSS decisions, dependency lines, or the SPEC-006 v0.2 regression AC cleanup.
- E.2 SPEC-001 untouched: PASS. Commit `990a07e` does not modify `specs/SPEC-001-phase3-binary.md`.
- E.3 Tier-3 deprecation clause: PASS. SPEC-006 still says Tier 3 MUST NOT contain a deprecation clause and MUST NOT require project shutdown.
- E.4 Out-of-scope list shrinkage: PASS. The out-of-scope list did not shrink in the audited delta.

## Critical findings

No CRITICAL findings.

## Major findings

**M1 - Per-model degraded authority is section-desynchronized and partly redefined in SPEC-006.**

Severity: MAJOR

Locations:
- SPEC-006 § 5.6, line 1086
- SPEC-002 buyer-side `/v1/models` text, lines 752-759
- SPEC-002 § 7.5, lines 2032-2111

What is wrong: The patch intended SPEC-002 v1.1.4 to be the normative home for the per-model `degraded` boolean and SPEC-006 to reference that definition without redefining it. SPEC-006 § 5.6 says the rule is defined in SPEC-002 v1.1.4 § 7.5, but SPEC-002 § 7.5 is the admission/admin endpoint section and contains no degraded rule. The rule actually appears earlier under the buyer-side `/v1/models` text. SPEC-006 also repeats the full rule inline, which violates the audit instruction to avoid a second definition.

Why it matters: This does not currently contradict the rule, but it weakens the cross-spec authority chain for D-CROSS-4. An implementer following the cross-reference lands in the wrong section; a future edit could update one copy and miss the other.

Fix recommendation: In one narrow text patch, either move or duplicate the normative degraded definition into the intended SPEC-002 § 7.5 location and update all references, or change SPEC-006 to cite the actual SPEC-002 section. Then remove the repeated rule from SPEC-006 and replace it with a pure reference plus "gateway computes from `/poolz` using that rule."

**M2 - AC-26 through AC-37 still have residual status/body-shape gaps on alternate branches.**

Severity: MAJOR

Location: SPEC-006 § 18, AC-26 through AC-37

What is wrong: The v0.3 AC patch fixed the method error, the T+60s revocation proof, and many missing error envelopes. However, the regression requirement was "each of the 12 ACs must include explicit HTTP status code + response body shape + curl -i verification command." Several branches still fall short:

- AC-26's allowlisted callback branch says it returns "the status/body for that stage" without naming the status or body.
- AC-29's valid-state branch says it reaches code exchange and does not return `oauth_state_invalid`, but gives no expected status/body.
- AC-30's allowed-scope branch says it reaches issuance or the next validation stage, but gives no expected status/body.
- AC-34's upstream-error branch says it uses an OpenAI envelope, but does not name the status, `type`, or `code`.

Why it matters: The earlier SPEC-006 v0.2 audit found AC ambiguity as the remaining regression class. v0.3 substantially improves the ACs, but these branches can still pass while leaving buyer-visible OAuth and header-strip behavior underspecified.

Fix recommendation: Keep the existing AC structure and add exact expected statuses/body shapes for the alternate branches. If a branch intentionally delegates to the next OAuth stage, name the acceptable status range and the minimum response fields; for AC-34, name the expected 502 envelope or the exact mocked failure status/code.

## Minor findings

No MINOR findings.

## Verdict + rationale

READY WITH NARROW FIX. The coordinated corpus is close to lock: all dependency lines are synchronized, SPEC-001 stayed untouched, `/v1/pool/check` ownership is coherent, the request-correlation path now has a shared key, and the quota/header/status/config patches are materially in place. No architectural contradictions or locked-decision violations were found.

Do one narrow v0.4/v1.1.5/v0.7 text patch, not a broad audit cycle. Patch the per-model `degraded` authority/xref so SPEC-002 has the normative rule exactly where downstream specs cite it, and make SPEC-006 reference rather than redefine it. Then finish the remaining AC explicitness gaps for AC-26, AC-29, AC-30, and AC-34. After that, the spec corpus should be ready to lock and proceed to BUILD_PHASE5.

## Self-verification

- [x] Read all three patched specs at their new versions.
- [x] Walked Category A's 19 closure checks.
- [x] Verified D-CROSS-1 through D-CROSS-6 coherence across the three specs.
- [x] Verified dependency-line synchronization.
- [x] Confirmed SPEC-001 v1.2.2 untouched.
- [x] Verified new normative text quality.
- [x] Checked scope discipline.
- [x] Verdict recorded.
