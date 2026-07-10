# SPEC-001 v1.3 audit history

## Round 1 — Codex GPT-5 — 2026-06-06 — Normative audit

**Audited:** SPEC-001 v1.3 (specs/SPEC-001-phase3-binary.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N (normative)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 3 MAJOR / 2 MINOR / 1 QUESTION

### Round-1 executive summary

POLISH ROUND REQUIRED. The required byte-identity, XDG allowlist, locked-spec diff, phase3-binary diff, and line-citation spot checks pass, but SPEC-001 v1.3 still has blocking normative drift around SPEC-010 default `supported_models` emission, one AC expectation that conflicts with the binding SPEC-011 detection-precedence AC, and one under-clarified L-1 first-connect scope question.

### Category A: L-1 byte-identical default preservation

**QUESTION A.1 — §6.7.4 / AC-18.0 / top revision line, lines 4, 7, 1717, 1724-1734, 2302-2308.**
What: SPEC-001 v1.3 states that with neither opt-in set, "on-the-wire behavior is byte-identical to a v1.2.4 binary" (lines 4 and 7), while R-6.7.8 says a v1.3 binary uses v2 `auth_request` for first connection whether or not either opt-in is set, and R-6.7.10 says pre-v1.3 binaries use legacy `hello` on first connect.
Why: If L-1 means full first-connect frame identity, v2 first-connect is not byte-identical to legacy `hello`. If L-1 is intentionally scoped only to absence of new catalog/warm-swap fields, the top-level "on-the-wire behavior" wording and AC-18.0 are too broad.
Recommendation: State the author's intended scope explicitly. Either preserve legacy `hello` for the unset/unset first-connect path, or narrow all L-1 wording to "no new SPEC-010/SPEC-011 fields/sockets/state" and stop claiming full wire-frame byte identity.

### Category B: Locked-spec citations and accuracy

(no findings)

Sampled all new R-rule citations in §6.7-§6.11 against SPEC-010 v1.5 and SPEC-011 v0.5. The cited rules exist and generally match the intended source, except for the semantic conflicts reported under Categories D and E.

### Category C: Code-grounding accuracy

(no findings)

All critical-constraint line anchors were checked against source. `server.go:354`, `messages.go:333`, `messages.go:391`, `provider.go:411`, `provider.go:421`, `ModelRuntime.swift:25-68`, `ModelRuntime.swift:294-325`, `ModelRuntime.swift:340`, and `MacProviderCLI.swift:7-15` match the cited symbols/statements.

### Category D: Four-cell opt-in matrix correctness

**MAJOR D.1 — §6.2 `--supported-models` and §6.7.3 cell 1, lines 980-988 and 1715-1719.**
What: SPEC-001 says the pure default path omits `supported_models` from the wire entirely, and the unset/unset matrix cell says no `supported_models` field is emitted. Locked SPEC-010 v1.5 R-3.6.2 says that if `supported_models` is unset after resolution, the provider binary MUST send `supported_models: [model_id]`; SPEC-010 AC-19 verifies that exact binary default emission.
Why: R-3.1.5 is the coordinator-side legacy-omission interpretation rule. It does not override R-3.6.2's binary-side emission rule. R-3.6.4 only defaults `publishes_supported_models` false/omitted; it does not allow suppressing the single-entry `supported_models` field.
Recommendation: Remove the "pure default path omits supported_models" exception. Cell 1 should say the binary emits `supported_models: [model_id]` per SPEC-010 R-3.6.2, omits or false-emits `publishes_supported_models` per R-3.6.4/R-3.1.6, and omits only SPEC-011 `model_hash` / `loading` plus the control socket.

### Category E: AC-18.x tracing and coverage

**MAJOR E.1 — AC-18.3, lines 2322-2327.**
What: AC-18.3 says `macprovider-cli models list` against a serve process without `--enable-warm-swap` must exit code 4 with stderr containing `"warm swap not enabled"`.
Why: SPEC-001's own R-6.9.5 adopts SPEC-011 v0.5 R-3.1.5.x detection precedence, and SPEC-011 AC-18 specifically expects the disabled default no-socket case to follow ENOENT case 1: `"macprovider-cli serve is not running on this host (no control socket at ...)"`. The AC trace is therefore not aligned with the cited binding AC.
Recommendation: Change AC-18.3's expected stderr to the R-6.9.5 / SPEC-011 AC-18 ENOENT message, or explicitly split a separate warm-swap-disabled diagnostic case only if a socket can exist and answer without warm swap, which R-3.1.0 says it must not.

**MAJOR E.2 — AC-18.0 and AC-18.9, lines 2302-2308 and 2358-2363.**
What: AC-18.0 asserts byte-identical default behavior while D.1's matrix/default text suppresses `supported_models`; AC-18.9 cites SPEC-010 AC-19, which requires default single-entry `supported_models: ["A"]` emission.
Why: The acceptance criteria pull in both incompatible expectations. A future test author cannot determine whether the unset/unset v2 frame should omit `supported_models` for byte identity or include `[model_id]` for SPEC-010 AC-19.
Recommendation: After fixing D.1, update AC-18.0/AC-18.9 so the default matrix cell has one expected wire shape and cites SPEC-010 AC-19 directly for the single-entry catalog field.

**MINOR E.3 — AC coverage gaps in AC-18.x, lines 2302-2376.**
What: Several new R-rules are only partially covered by AC-18.x: R-6.9.5 ECONNREFUSED and handshake-timeout detection branches, R-6.11.5 cooldown/`--force` exit-code behavior, R-6.11.4 reconnect using legacy `hello`, and R-6.8.3 exact state values.
Why: The cited locked specs have AC coverage for these behaviors, so this is not an implementability blocker, but SPEC-001 v1.3's local AC suite does not pin all of its own new R-rules.
Recommendation: Add narrow AC-18.x subcases or a follow-on AC group for the missing detection branches, cooldown/force semantics, reconnect `hello` path, and state-value enumeration.

### Category F: §6.2 CLI additions

**MINOR F.1 — §6.2 CLI additions, lines 978-1016.**
What: The new flag list is present, but a few validation details are only cited indirectly rather than documented inline: `--swap-drain-timeout-seconds` says "Default per SPEC-011 v0.5 §3.9 config block" instead of spelling out default 20 and range 5-600 with exit code 2; `--publish-supported-models` does not name env/config resolution even though SPEC-010 AC-10 tests the same priority for that flag.
Why: The binding rules are cited, so implementation remains recoverable, but the audit prompt asked §6.2 to document defaults, env/config priority where applicable, valid ranges, and validation exit codes.
Recommendation: Inline the default/range/exit-code text for drain timeout and add publish flag env/config priority if the intended binary surface includes it.

### Category G: §2 scope additions

(no findings)

### Category H: Change-log + §11 hand-off

(no findings)

### Category I: Anything else

(no findings)

### Required Spot-Check Evidence

- §6.5 byte-identity spot-check: PASS. Command diff output was empty.
- XDG allowlist spot-check: PASS. `grep -n 'XDG_RUNTIME_DIR' specs/SPEC-001-phase3-binary.md` returned only line 1807 in the §6.9 "Why not" rationale block.
- Code-grounding citations: PASS. All line anchors enumerated in critical constraint 6 match actual source; the prompt text says "8" but the block enumerates 9 bullets, all checked.
- `git diff --stat phase3-binary/`: PASS, empty.
- Locked companion diff: PASS, `git diff specs/SPEC-002*.md specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md` was empty.
- §6.7.1 initial-stage table: PASS for field presence/type/requiredness against SPEC-010 v1.5 §3.1.A.
- §6.7.2 proof-stage table: PASS for field presence/type/requiredness against SPEC-010 v1.5 §3.1.C.
- §6.8 R-6.8.1 through R-6.8.7 citations: PASS against SPEC-011 v0.5 R-3.2.1 through R-3.2.7.
- §6.9 control socket path: PASS for `$TMPDIR/macprovider-cli/ctl.sock`, `FileManager.default.temporaryDirectory`, parent `0700`, socket `0600`, and R-3.1.5.x precedence text.

---

## Round 2 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-001 v1.3 (post round-1 polish)
            (specs/SPEC-001-phase3-binary.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (normative, LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 QUESTION

### Round-2 executive summary — LOCK VERDICT

LOCK CONFIRMED. The round-1 polish closes all six R1 findings, and the required sanity checks for §6.5 byte identity, locked companion specs, `phase3-binary/`, and `$XDG_RUNTIME_DIR` all pass with no new CRITICAL, MAJOR, or MINOR findings.

### Round-1 finding closure verification (R1V)

| Round-1 finding | Result | v1.3 post-polish location | Evidence |
|---|---|---|---|
| R1V-D.1 | PASS | §6.2 lines 980-992; §6.7 R-6.7.3 lines 1640-1653; §6.7.3 cell 1 line 1729 and cell 3 line 1731 | The default path now says the binary MUST emit `supported_models: [model_id]`; cell 1 also emits the single-entry catalog while omitting `publishes_supported_models`, and R-6.7.3 says `supported_models[]` is ALWAYS emitted. |
| R1V-E.1 | PASS | AC-18.3 lines 2348-2355 | AC-18.3 now takes the ENOENT case-1 path and expects exit code 4 with stderr containing `macprovider-cli serve is not running on this host (no control socket at`, matching SPEC-011 AC-18/R-3.1.5.x case 1. |
| R1V-E.2 | PASS | AC-18.0 lines 2314-2334; AC-18.9 lines 2386-2405 | AC-18.0 and AC-18.9 now consistently define the L-1 baseline as single-entry catalog emission plus omission of `publishes_supported_models` and SPEC-011 heartbeat/control-socket surface. |
| R1V-E.3 | PASS | AC-18.12 through AC-18.16 lines 2420-2468 | The new ACs cover ECONNREFUSED, handshake timeout, cooldown/`--force`, reconnect-via-hello, and state-value enumeration with citations to SPEC-011 v0.5. |
| R1V-F.1 | PASS | §6.2 lines 993-1002 and 1012-1016 | `--publish-supported-models` now documents CLI > ENV > config priority, and `--swap-drain-timeout-seconds` inlines default 20, range 5-600, and exit code 2 for out-of-range values. |
| R1V-A.1 | PASS | Top revision line 4; v1.3 change log line 7; AC-18.0 lines 2314-2334; §6.7.3 cell 1 line 1729 | The broad "byte-identical v1.2.4" framing is narrowed to "no NEW SPEC-010/SPEC-011 fields, sockets, or runtime state beyond the SPEC-010 single-entry catalog default." |

### Category R1V: Round-1 finding closure verification

(no findings)

All six round-1 closure verifications are PASS.

### Category A2: Locked-decision preservation (sanity check)

(no findings)

- A2.1 §6.5 byte-identity spot-check: PASS. `diff <(awk '/^### 6\.5/,/^### 6\.6/' /tmp/spec001-head.md) <(awk '/^### 6\.5/,/^### 6\.6/' specs/SPEC-001-phase3-binary.md)` returned empty.
- A2.2 Locked-companion diff sanity check: PASS. `git diff specs/SPEC-002*.md specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md` returned empty.
- A2.3 `phase3-binary/` diff sanity check: PASS. `git diff --stat phase3-binary/` returned empty.
- A2.4 `$XDG_RUNTIME_DIR` allowlist sanity check: PASS. `grep -n 'XDG_RUNTIME_DIR' specs/SPEC-001-phase3-binary.md` returned only line 1819 in the §6.9 "Why not" rationale line.

### Category B2: Citation accuracy on the closure surface

(no findings)

B2.1 sampled AC-18.0, AC-18.3, AC-18.9, AC-18.12 through AC-18.16, §6.7.3 cell 1, R-6.7.3, and §6.2 flag text against SPEC-010 v1.5 and SPEC-011 v0.5; all cited locked rules exist and match the closure surface. B2.2 PASS: AC-18.3's required stderr prefix matches SPEC-011 v0.5 AC-18 case-1 / R-3.1.5.x ENOENT wording.

### Category C2: New AC coverage soundness

(no findings)

AC-18.12 is operationally testable via a stale socket file with no listener; AC-18.13 uses the SPEC-011 R-3.1.5.x 2-second timeout; AC-18.14 matches the 10s cooldown and limits `--force` to the cooldown soft guard; AC-18.15 matches reconnect via legacy `hello` and OLD-hash-during-load behavior; AC-18.16 matches the runtime-state enum with `failed` as internal-only-transient for status responses.

### Category D2: Anything else

(no findings)

D2.1 no new normative surface was introduced outside the round-1 closure area. D2.2 no residual "byte-identical default" wording drift was found on the closure surface. D2.3 reminder only: after LOCK, add decision-log Entry 56 mirroring the Entry 54 / Entry 55 format.
