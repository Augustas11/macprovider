# SPEC-017 v0.1.8 — Claude subagent ROUND 3 audit

**HEAD:** `e2eb011` ("fix(017): close adversarial r2 findings — AC-17 stdout + §6.6.2 mechanical gate + doc drifts")
**Worktree:** `/Users/augstar/macprovider-spec017-step1/`
**Date:** 2026-06-26
**Reviewer:** independent claude subagent, adversarial mode
**Tools used:** read, grep, go build/vet/test (with integration tag), Docker testcontainers, regex-probe harness, JSON-encoder probe harness

---

## Verdict: **READY TO SHIP**

**0 CRITICAL / 0 HIGH / 0 MEDIUM** at the SPEC-017 v0.1.8 lock surface.

Two LOW-severity *observations* are recorded below as discovery-stage findings — neither blocks the lock. They are listed for completeness and the consumer's filter.

---

## R2 closure verification — by finding

### r2 CRITICAL (SECURITY) — §6.6.2 sign-off was doc-only

**Closed.** Defense-in-depth mechanical gate landed in `phase4-coordinator/cmd/coordinator/partnerkeys.go:176-235`:

- `--production` flag (default `false`) gates production issuance; staging path semantics unchanged (existing fixture tests still pass).
- When `--production`, `--signoff-spec-6-6-2 TEXT` is REQUIRED.
- Two regex sanity checks gate the signoff value:
  - `(?i)spec-014.*sha\s*=\s*[A-Fa-f0-9]{7,}` (SPEC-014 SHA reference, case-insensitive, ≥7 hex chars)
  - `\b20\d\d-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b` (well-formed YYYY-MM-DD in 20xx).
- Validation fires BEFORE DSN resolution / DB connection (`partnerkeys.go:205-235` → DSN at `:256`); operator who forgot signoff doesn't see admin-DSN failure first.
- Signoff persists into `stats_partner_key_issued` event as fields `production: true` and `signoff_spec_6_6_2: <text>` (`partnerkeys.go:378-381`).
- Signoff WITHOUT `--production` is a loud config error (`:230-235`) instead of a silent drop.

Adversarial regex probe (10 inputs at `/tmp/test_regex.go`) confirms:
- Newline injection in signoff value is harmless: `encoding/json.Encoder.Encode` properly escapes `\n` as the two-char `\n` sequence (verified by probe). The signoff is never emitted to stderr outside the JSON event.
- SQL-injection-shaped signoff text passes the regex but is only stored as a JSON string field; never used in SQL.
- Audit fraud (lying about SHA / date) is not blocked — the SECURITY r2 audit explicitly accepts this: the lie is recorded in the event for post-hoc accountability. The gate's purpose is to defeat operator forgetfulness and wrapper-script automation, not to defeat a malicious operator who already holds the admin DSN.

Test coverage: `TestProductionRequiresSignoff` (5 sub-cases) — all PASS at HEAD. Sub-cases cover staging default, missing signoff, malformed signoff, well-formed signoff + event-field assertion, and the "signoff without --production fails loud" symmetry case.

### r2 HIGH (ARCH) — AC-17 stdout contract

**Closed.** SPEC §10 AC-17 says "Prints exactly one 47-character token beginning `mpk_` to stdout". The r2 IMPL printed the metadata line to stdout BEFORE the token; secret-ingestion scripts capturing stdout received metadata+token instead of a single token line.

Fix in `partnerkeys.go`:
- Metadata line moved to STDERR (`:343-344`, was previously stdout).
- `--token-out` success diagnostic moved to STDERR (`:410`); stdout is now EMPTY when `--token-out` is used.
- New `assertStdoutIsTokenOnly` test helper (`partnerkeys_integration_test.go:267-286`) enforces `^mpk_[A-Za-z0-9_-]{43}\n?$` AND banned-substring list `[id=, label=, prefix=, created_by=, rotated_from_id=, created_at=]`.

Verified no regression in `runIssue` callers: grep over `phase4-coordinator/cmd/coordinator/*.go` for `runIssue|runPartnerKeysIssue` returned 23 hits — all are inside the same test file, all updated to match the new shape. `TestTokenRedactionOnFailedInsert` (the prompt's specific worry) at `:758-808` uses `extractRawTokenLine` which trims trailing newline and returns the last line; the new "stdout is exactly one token line" shape satisfies that contract trivially.

All 6 targeted integration tests PASS:
- `TestAC17_IssueLockedSPECCommand` — uses `assertStdoutIsTokenOnly`; asserts stderr carries `id=`, `label=X`, `prefix=`, `created_by=`, `created_at=` (line 356).
- `TestIssueTokenOutWritesFile` — asserts stdout is empty (line 731) and stderr contains "token written to ..." (line 734).
- `TestIssueJournalStreamSuppresses`, `TestTokenRedactionOnFailedInsert`, `TestProductionRequiresSignoff`, `TestStep4C_StatsPartnerKeyIssuedEvent` — all PASS.

### r2 MEDIUM 1 (claude-subagent) — SPEC §5.9 304 CORS drift

**Closed.** `specs/SPEC-017-network-stats-api.md:1291-1303` now includes the 2026-06-26 erratum reconciling §5.9 with the round-1 304-CORS fix. 304 carries RFC 7232 headers (ETag, Cache-Control, Vary) PLUS §5.7 projection-aware CORS (ACAO + Access-Control-Allow-Credentials on partner projection + Access-Control-Max-Age on preflight). Cross-document grep for the obsolete phrase "only the headers required by RFC 7232" finds exactly one hit — the prior round's audit file (historical, not normative). No test/code references the obsolete phrase.

`TestAC12_304IfNoneMatch` and `TestAC12_304IfNoneMatch_CORSHeadersPresent` both PASS in `phase4-coordinator/internal/stats/` integration suite. CORS write at `handlers.go:710` happens BEFORE the 304 short-circuit at `:711`; both 200 and 304 emit projection-aware ACAO.

### r2 MEDIUM 2 (claude-subagent) — BUILD prompt line 462 burst drift

**Closed.** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:462` now carries the burst=59 qualifier and references the §5.6 v0.1.8 erratum + Step 4.B nginx directive. All three burst references in the BUILD prompt (lines 22, 462, 569) are now self-consistent and mirror SPEC §5.6's distinction between "sustained-throughput amplification" (forbidden) and "short-term bucket capacity nginx requires for AC-8" (mandatory `burst=59 nodelay`).

### r2 LOW (ARCH) — provider_portal SELECT migration comment

**Closed.** `phase4-coordinator/internal/stats/migrations/004_grants.up.sql:86-115` rewrites the comment block: SELECT is now described as the locked SPEC §7.2.3 v0.1.8 inventory, not an "IMPL-authored deviation" or "SPEC v0.2 candidate". The earlier wording was an artifact of the audit-round narrative; the v0.1.8 erratum closed the gap.

---

## Build + test evidence

```text
$ go build ./...                    # phase4-coordinator
(no output, exit 0)

$ go vet ./...                      # phase4-coordinator
(no output, exit 0)

$ go test -tags integration -run "TestAC17_IssueLockedSPECCommand$|TestProductionRequiresSignoff$|TestIssueTokenOutWritesFile$|TestIssueJournalStreamSuppresses$|TestTokenRedactionOnFailedInsert$|TestStep4C_StatsPartnerKeyIssuedEvent$" -count=1 ./cmd/coordinator/
PASS    ok    github.com/augstar/macprovider-coordinator/cmd/coordinator    5.663s

$ go test -tags integration -count=1 ./cmd/coordinator/
ok    github.com/augstar/macprovider-coordinator/cmd/coordinator    21.291s

$ go test -tags integration -count=1 ./internal/stats/
ok    github.com/augstar/macprovider-coordinator/internal/stats     144.878s
```

Full integration suite passes for both `cmd/coordinator/` and `internal/stats/`. No skipped tests.

---

## Adversarial probes that did NOT find an issue ("what I tried to refute but couldn't")

1. **Newline / log-injection via `--signoff-spec-6-6-2`** — I crafted `"SPEC-014 sha=abc1234 disclosure-live=2026-09-01\nFORGED"` and verified via standalone `encoding/json` harness that the encoder writes the literal two-char `\n` escape sequence, not a raw newline. The value lands in the JSON event field safely; the value is never echoed to stderr outside the JSON event.
2. **Audit-fraud signoff bypass** — I confirmed the regex matches a SHA of all zeros (`sha=0000000`) and a future date. This is intentional: the design's stated tradeoff is that the gate defeats operator forgetfulness and wrapper-script automation; it does not defeat a malicious operator who already holds the admin DSN. The signoff value is recorded for post-hoc accountability.
3. **Wrapper-script omits `--production` against a PROD DSN** — the operator can still issue a STAGING-style key (no signoff required) against a production DSN. The signoff is defense-in-depth; the DSN environment is the provenance mark. This is the explicit design tradeoff acknowledged in the r2 SECURITY findings.
4. **`runIssue` callers expecting metadata-on-stdout** — grep found 23 hits, all inside the integration test file, all updated. No production code path (other than the daemon dispatcher at `partnerkeys.go:119`) calls `runPartnerKeysIssue`. Wrapper scripts in OPS.md (`grep -rn "token-out" --include="*.sh"`) returned zero results — no shell wrapper exists yet that would be broken by the empty-stdout-on-`--token-out` shape.
5. **`TestTokenRedactionOnFailedInsert` regression** — the prompt flagged this as a possible breakage. Read the test at `partnerkeys_integration_test.go:758-808`: it uses `extractRawTokenLine(outA)` (which trims trailing newline and returns the last line). The new shape (exactly one token line) is the trivial happy case. Test PASSES.
6. **§5.9 SPEC text breaks other tests** — grep for "only the headers required by RFC 7232" returned 1 hit (a historical r2-audit file). No test or normative file references the obsolete phrase.
7. **Rotation flow + production gate** — rotation is `--rotate-from N` on the issue path. The production gate fires BEFORE the rotate-from DB lookup (`partnerkeys.go:205-235` → DB at `:263`). So a production rotation also requires `--production --signoff-spec-6-6-2`. `TestRotationOverlap` exercises rotation without `--production` (staging) and passes.
8. **JSON event field ordering** — `encoding/json.Encoder` writes map fields in (Go-implementation-defined) insertion order, not strict alphabetical. Tests use `strings.Contains` so order doesn't matter. No bug.
9. **Stderr metadata line + `%s` for operator-controlled label** — `partnerkeys.go:343` does `fmt.Fprintf(stderr, "id=%d label=%s ...", id, *label, ...)`. A label with embedded newlines would inject lines into stderr. This is a PRE-EXISTING surface (label is stored in `partner_keys.label`, controlled by the operator who already holds the admin DSN). Out of r3 scope; not a new finding from the r2 fixes.
10. **Revoke does not enforce the production gate** — confirmed deliberate. Revoke is the safe-direction operation (over-eager revoke = downtime, not exposure). No signoff required.

---

## Low-severity observations (NOT blocking)

### LOW-1 — Signoff regex does not bind to the same SHA across re-runs

**Confidence:** MEDIUM. **Severity:** LOW.

The regex `(?i)spec-014.*sha\s*=\s*[A-Fa-f0-9]{7,}` accepts ANY 7+ hex chars after `sha=`. An operator could pass `sha=abc1234` one day, `sha=def5678` the next (both fake), and the gate would accept both. This is the same "audit fraud is not blocked" tradeoff explicit in the design; calling it out so the operator runbook makes it visible. **Recommendation (NON-BLOCKING):** OPS.md §10.5 (which I did not re-read) could include a sentence: "the signoff value is a recorded operator declaration, not a cryptographic verification — the value is preserved in the `stats_partner_key_issued` event payload for post-hoc audit against the actual SPEC-014 v0.9 commit SHA in this repo."

### LOW-2 — `--rotate-from` does not require an active (un-revoked) predecessor

**Confidence:** MEDIUM. **Severity:** LOW.

`partnerkeys.go:277-289` checks `EXISTS (SELECT 1 FROM partner_keys WHERE id = $1)` for `--rotate-from`. It does not check `revoked_at IS NULL`. An operator could `--rotate-from` a long-revoked predecessor, producing a B row whose lineage points at a dead A. The lineage is recorded, the resulting B key is independent and works; the audit semantic is fuzzier ("rotation from a key that was revoked 6 months ago"). **Not a security defect** — no exposure surface. **Not in r3 scope** — this predates the r2 fixes. Surfaced only because the r3 prompt asked "what's the next layer?" Out of scope for SPEC-017 v0.1.8 lock.

---

## Files reviewed at HEAD `e2eb011`

- `phase4-coordinator/cmd/coordinator/partnerkeys.go` (issue/revoke/list dispatcher, signoff gate, event emit)
- `phase4-coordinator/cmd/coordinator/partnerkeys_integration_test.go` (23 runIssue callers + assertStdoutIsTokenOnly helper + 5-subcase TestProductionRequiresSignoff)
- `phase4-coordinator/internal/stats/handlers.go` (writeJSON, 304 CORS positioning)
- `phase4-coordinator/internal/stats/handlers_integration_test.go` (304 + CORS tests)
- `phase4-coordinator/internal/stats/migrations/004_grants.up.sql` (provider_portal SELECT comment)
- `specs/SPEC-017-network-stats-api.md` (§5.9 erratum text, §5.7 cross-ref, AC-17 text, §5.6 burst reconciliation)
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` (line 22 / 462 / 569 burst consistency)
- `OPS.md` (§10.1 partner-key issue runbook + --production example)

---

## Recommendation

**LOCK SPEC-017 v0.1.8 at HEAD `e2eb011`.**

The two LOW observations are surfaced for the consumer's filter and do not block the lock. R3 found no new CRITICAL/HIGH/MEDIUM issues introduced by the r2 fixes. R2's three blockers (CRITICAL sign-off, HIGH AC-17, two MEDIUM doc drifts) are all closed with test evidence and adversarial-probe corroboration.
