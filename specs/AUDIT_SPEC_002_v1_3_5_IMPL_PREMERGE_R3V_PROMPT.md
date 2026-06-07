# Pre-merge R3 closure-verification audit — SPEC-002 v1.3.5

Operator-paste prompt for Codex GPT-5 to perform a focused
**closure-verification** review of commit `4452c36` (the R3 fix
commit that landed on top of `70a5876`), confirming the CRITICAL
finding from the pre-merge audit at
`.omc/artifacts/ask/codex-execute-the-pre-merge-audit-prompt-at-specs-audit-spec-002-v-2026-06-07T05-26-48-172Z.md`
is genuinely closed AND that the R3 changes themselves did not
introduce new defects.

This is the final gate before squash-merge. Expected outcome:
MERGE-READY.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-25 min
(tightly scoped — 1 CRITICAL closure + regression sniff over the
R3 surface).
This is a **read-only review** — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing a pre-merge R3 closure-verification audit on
commit `4452c36` in /Users/augstar/macprovider-poc, branch
`fix/spec-002-v1-3-5-coordinator`. This commit applies an inline
Claude fix addressing the CRITICAL finding from the full pre-merge
audit on the 12-commit branch (now 13 commits with this R3).

Your task has TWO halves:
  A. Verify the CRITICAL [code:1.1] finding is genuinely closed by
     4452c36.
  B. Sniff for new findings introduced by 4452c36 itself, with
     special attention to the asymmetric initial-stage / proof-stage
     parser behavior the R3 explicitly documents.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Pre-merge audit verdict on c8aba39 (Phase 2E R2) + all prior
commits was BLOCK-MERGE with:
- 1 CRITICAL — AC-K.15 validation oracle drift for
  `supported_models` failures:
  - JSON type drift: parser returned bare badField
    `"supported_models"` instead of the LOCKED
    `"supported_models must be array of strings"` substring;
    bare value did NOT match `isSpec010CatalogBadField`
    allowlist, so JSON-type rejections fell through to the
    generic envelope close (CloseUnrecognizedAuthMessage 4000).
  - Containment drift: parser returned
    `"supported_models missing model_id"` instead of the LOCKED
    `"model_id not in supported_models"` substring.

R3 (4452c36) claims to close both.

## Required reading (in this order)

1. The pre-merge audit artifact at
   `.omc/artifacts/ask/codex-execute-the-pre-merge-audit-prompt-at-specs-audit-spec-002-v-2026-06-07T05-26-48-172Z.md`
   — read the full [code:1.1] Finding section.

2. The R3 commit via `git show 4452c36`. Read the full diff. The
   commit message documents the asymmetry between initial-stage
   (AC-K.15 surfacing) and proof-stage (envelope rejection) that
   R3 preserves intentionally.

3. The locked spec sections:
   - `specs/SPEC-010-model-catalog.md` v1.5 R-3.1.4 (containment
     rule + "model_id not in supported_models" substring), R-3.1.9
     (5-step validation order with all 6 LOCKED substrings).
   - `specs/SPEC-002-coordinator.md` v1.3.5 §11 AC-K.15.

4. The current source after R3:
   - `phase4-coordinator/internal/ws/messages.go`
     - parseAuthInitial (changed)
     - parseAuthProof (UNCHANGED — preserves bare badField)
   - `phase4-coordinator/internal/ws/auth_attempts.go`
     - isSpec010CatalogBadField switch (allowlist updated)
   - `phase4-coordinator/internal/ws/messages_test.go`
     - TestParseAuthInitialRejectsMissingModelID (updated)
     - TestParseAuthInitialRejectsSupportedModelsWrongType (NEW)
   - `phase4-coordinator/internal/ws/server_test.go`
     - TestProviderAuthV2InitialMissingModelIDRejectedOnTheWire (updated)
     - TestProviderAuthV2InitialSupportedModelsWrongTypeRejectedOnTheWire (NEW)

5. The [r2:1.1] R2V regression test that the R3 explicitly
   preserves:
   - `phase4-coordinator/internal/ws/server_test.go`:
     TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath
   — must STILL pass post-R3, demonstrating that proof-stage-first
   frames with malformed supported_models continue to take the
   envelope path (CloseUnrecognizedAuthMessage 4000), not the
   AC-K.15 path. This is the load-bearing asymmetry.

DO NOT inspect any file under `phase3-binary/.build/checkouts/`.

## Part A — CRITICAL closure verification

### A1 — [code:1.1] CRITICAL — AC-K.15 substring drift (both halves)

**R1 finding (pre-merge audit):** Two LOCKED SPEC-010 v1.5 R-3.1.9
substrings were drifted in the implementation:
- Step 1 (JSON type): parser returned bare badField
  "supported_models" instead of "supported_models must be array
  of strings"; bare value did not match isSpec010CatalogBadField,
  so JSON-type failures took the generic envelope close path.
- Step 5 (containment): parser returned
  "supported_models missing model_id" instead of
  "model_id not in supported_models".

**R3 claimed fix:**
- parseAuthInitial JSON-type error: badField + fieldError now
  use "supported_models must be array of strings" verbatim
  (lines around messages.go:411-415).
- parseAuthInitial containment error: badField + fieldError now
  use "model_id not in supported_models" verbatim (line around
  messages.go:442).
- isSpec010CatalogBadField allowlist: now includes
  "supported_models must be array of strings" and
  "model_id not in supported_models"; removed
  "supported_models missing model_id". Ordered to mirror
  R-3.1.9 validation order.
- 2 new tests pin the new substrings end-to-end + at the parser
  level.

**Verify (run shell commands):**
- Grep the spec for the binding substrings:
    grep -n '"model_id not in supported_models"' specs/SPEC-010-model-catalog.md
    grep -n '"supported_models must be array of strings"' specs/SPEC-010-model-catalog.md
  Both MUST appear in R-3.1.9 / R-3.1.4 context.
- Grep the implementation for each LOCKED substring on the wire
  path:
    grep -rn '"supported_models must be array of strings"' \
      phase4-coordinator/internal/ws/messages.go \
      phase4-coordinator/internal/ws/auth_attempts.go \
      phase4-coordinator/internal/ws/messages_test.go \
      phase4-coordinator/internal/ws/server_test.go
    grep -rn '"model_id not in supported_models"' \
      phase4-coordinator/internal/ws/messages.go \
      phase4-coordinator/internal/ws/auth_attempts.go \
      phase4-coordinator/internal/ws/messages_test.go \
      phase4-coordinator/internal/ws/server_test.go
  Each MUST appear at minimum in:
    (a) the parser badField return,
    (b) the isSpec010CatalogBadField allowlist,
    (c) at least one parser unit test,
    (d) at least one end-to-end test.
- Confirm the OLD drifted substrings are GONE from the
  production code:
    grep -rn '"supported_models missing model_id"' phase4-coordinator/
  Should appear NOWHERE except possibly in commit-message
  archives or this audit prompt itself. Production code +
  tests MUST NOT use it.
- Run the new tests:
    cd phase4-coordinator && go test -race -count=1 -v \
      -run 'TestParseAuthInitialRejectsSupportedModelsWrongType|TestProviderAuthV2InitialSupportedModelsWrongTypeRejectedOnTheWire|TestParseAuthInitialRejectsMissingModelID|TestProviderAuthV2InitialMissingModelIDRejectedOnTheWire' \
      ./internal/ws/...
  All 4 MUST pass.
- Read messages.go around the JSON-unmarshal error path. Verify
  the `if err := json.Unmarshal(v, &req.SupportedModels);
  err != nil` branch returns the LOCKED substring as badField
  too — NOT a bare "supported_models". A common drift would be
  to fix the null-check path but forget the unmarshal-error
  path.

## Part B — R3 regression sniff

### B1 — Proof-stage asymmetry preservation (load-bearing)

The R3 commit explicitly preserves proof-stage parseAuthProof's
bare "supported_models" badField. This is intentional: the
[r2:1.1] R2V regression test
TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath
requires proof-stage-first frames with malformed supported_models
to take CloseUnrecognizedAuthMessage (4000), NOT the AC-K.15
CloseInvalidHello (4001) path.

Verify:
- Read parseAuthProof in messages.go. The badField for both
  null and json.Unmarshal-error paths is still bare
  "supported_models" (NOT the locked substring).
- Read the comment block above parseAuthProof's supported_models
  block. Confirm it documents the asymmetry intent (initial-stage
  surfaces AC-K.15, proof-stage takes envelope rejection).
- Run the regression test:
    cd phase4-coordinator && go test -race -count=1 -v \
      -run TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath \
      ./internal/ws/...
  MUST pass.
- Confirm `isSpec010CatalogBadField` does NOT include bare
  "supported_models" in its exact-match list. The proof-stage
  bare value must NOT match.

### B2 — All 6 R-3.1.9 LOCKED substrings reach the wire

Run a single command verifying each substring is present in the
implementation:

  for s in \
    "supported_models must be array of strings" \
    "supported_models cannot be empty" \
    "supported_models entry exceeds 256 bytes" \
    "supported_models exceeds 64 entries" \
    "supported_models contains duplicate entries" \
    "model_id not in supported_models"; do
    echo "== $s =="
    grep -rn "\"$s\"" phase4-coordinator/internal/ws/ | wc -l
  done

Each substring MUST have a count > 0 (production + tests
combined). Zero for any = CRITICAL regression.

### B3 — Edit budget

The R3 commit modifies messages.go, auth_attempts.go,
messages_test.go, server_test.go, plus the audit prompt
artifact. Confirm via
`git diff --name-only HEAD~1 -- phase4-coordinator/` that no
unrelated files changed.

### B4 — Build / vet / race / suite cleanliness

Run:
  cd phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/ ./cmd/
  go test -race -count=1 ./...
All MUST exit 0.

For the gateway:
  cd phase5-gateway
  go test -count=1 ./...
MUST exit 0 (R3 doesn't touch the gateway; this confirms no
indirect breakage).

## Output format

```
# SPEC-002 v1.3.5 pre-merge R3 closure-verification — Codex GPT-5

## Verdict

<one-line: MERGE-READY | FIX-THEN-PROCEED | BLOCK-MERGE>

## R1 closure

| Finding | R1 severity | R3 verdict | Test/file proof |
|---|---|---|---|
| code:1.1 (AC-K.15 substring drift, both halves) | CRITICAL | CLOSED/NOT-CLOSED/PARTIAL | <file:line + 4 test names> |

## New findings introduced by R3

(zero is the expected/desired result)

[r3:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation>

## All-6-substring wire-presence check

| LOCKED substring | Production hits | Test hits |
|---|---|---|
| "supported_models must be array of strings" | <N> | <N> |
| "supported_models cannot be empty" | <N> | <N> |
| "supported_models entry exceeds 256 bytes" | <N> | <N> |
| "supported_models exceeds 64 entries" | <N> | <N> |
| "supported_models contains duplicate entries" | <N> | <N> |
| "model_id not in supported_models" | <N> | <N> |

## Asymmetry preservation check

- proof-stage parser bare badField "supported_models": PRESENT / ABSENT
- isSpec010CatalogBadField allowlist excludes bare "supported_models": YES / NO
- TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath: PASS / FAIL

## Build / vet / race / suite evidence

(paste the commands' outputs)

## Cross-cutting observations

<patterns spanning the closure verdict or new findings>
```

## Discipline

- A closure is CLOSED only when BOTH the production fix AND a
  covering test exist AND all 6 LOCKED substrings have non-zero
  hits in the implementation.
- New-finding severity follows the same scale.
- A regression in TestProviderAuthV2ProofStageFirstWithMalformedCatalogTakesEnvelopePath
  is CRITICAL (load-bearing asymmetry).
- Zero new findings is the expected/desired result.
- Cite file:line for every claim.

You may run shell commands (git, grep, go build/vet/test). You
MUST NOT modify any file.

You may take up to 25 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes

- Expected outcome: MERGE-READY, zero new findings. The R3 surface
  is small (~50 LOC across 4 files) and the fix is mechanical
  (substring update + allowlist update + new test).
- If MERGE-READY, the next step is operator-driven: push branch,
  open PR, squash-merge, deploy coordinator + gateway, tag v1.3.0
  binary release.
- If new findings or NOT-CLOSED: iterate inline until clean before
  push.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7).
