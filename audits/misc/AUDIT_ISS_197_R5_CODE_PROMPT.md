You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane, ROUND 5.

R4 returned 0 CRITICAL / 0 HIGH / 0 MEDIUM and 1 LOW (model-sanitize test
was too permissive — accepted "0 rows" as passing). R5 fix: tightened
the test to require exactly 1 buyer-failure row with `model == "modelabc"`
(C1 stripped) and ContainsRune(U+009B) absent. R5 also touched code
in unrelated lanes:

- `phase4-coordinator/internal/ws/messages.go::requireString` now rejects
  C0/DEL/C1 control characters in any provider-supplied required string
  on a hello (provider_id, hostname, model_id, binary_version,
  attestation-related fields). Closes R4 security MEDIUM #1 (provider-
  controlled C1 reaching structured logs via hello.provider_id).
  New test: `TestParseHelloRejectsControlCharsInRequiredStrings` covers
  all four fields × {C0 null, C0 LF, C1 CSI U+009B, C1 low U+0080,
  C1 high U+009F, DEL}.

## Verify

- The tightened model-sanitize test is now strict: 1 row required,
  `model == "modelabc"`. Does any existing test rely on the previous
  loose behavior? Run the full suite to confirm.
- The hello requireString hardening — does it break any legitimate
  provider flow? Check `validHello` fixtures across the test corpus.
- Are there other ws messages where required strings flow into
  structured logs unsanitized? Check ParseAuthInitial /
  ParseAuthResponse / ParseInference / ParseNak — they share
  requireString, so the hardening covers them automatically, but
  verify no other parse function bypasses requireString.
- Full coordinator test suite — `go test ./...` — still green?

## Severity rubric

- **CRITICAL**: regression vs prior versions.
- **HIGH**: an R4 finding still open.
- **MEDIUM**: SPEC↔impl divergence; missed MUST.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
