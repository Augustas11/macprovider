# AUDIT: Dead-code removal of `internal/testfaults/`

## Change under review

Branch: `fix/deadcode-cleanup` (base `origin/main` a01b05a).

Diffstat:

```
 phase4-coordinator/internal/testfaults/README.md                     | 26 ---
 phase4-coordinator/internal/testfaults/doc.go                        |  1 -
 phase4-coordinator/internal/testfaults/panic_endpoint_testfaults.go  |  9 --
 phase4-coordinator/internal/testfaults/relay.go                      | 38 -----
 4 files changed, 74 deletions(-)
```

Nothing else changes. No production wiring is touched; no callers, tests, or
imports are modified.

## Removed symbols

- `func PanicHandler(w http.ResponseWriter, r *http.Request)` — an HTTP
  handler that intentionally panics. Was **never registered on any mux** in
  `cmd/` or elsewhere.
- `func DeadMidInferenceRelay(ctx, provider, requestID, body, stream) (*providerws.RelayStream, error)` — a
  provider-relay stub for simulating provider disconnection mid-inference.
- `type SlowReader struct { …; func (r SlowReader) Read(p []byte) (int, error) }` — an
  `io.Reader` that returns a byte per call with delay.

## Evidence that the module is unused

From a fresh clean worktree at the change:

```
$ grep -rn "internal/testfaults" --include="*.go" .
# (no output — no importers in production or test code)

$ grep -rn "PanicHandler\|DeadMidInferenceRelay\|SlowReader" --include="*.go" .
# hits ONLY inside phase4-coordinator/internal/testfaults/ itself (declarations)
```

Both Go modules build clean and full test suites pass after the deletion:

- `phase4-coordinator`: `go build ./...` OK, `go test ./...` all packages
  PASS (including `internal/buyer`, `internal/ws`, `internal/billing`,
  `internal/requestlog`, `internal/spec015contract`).
- `phase5-gateway`: `go build ./...` OK, `go test ./...` all packages PASS.

## What I am asking each lane to check

Three independent codex lanes: **code**, **security**, **architect**.
Each should return a report with severity-labeled findings
(CRITICAL / HIGH / MEDIUM / LOW / INFO). Convergence bar: 0 CRITICAL, 0 HIGH,
0 MEDIUM. LOW/INFO may be documented in the PR body.

### Lane A — code

Correctness questions:

1. Are there ANY reachable code paths, build tags, or `//go:build`
   constraints under which `PanicHandler`, `DeadMidInferenceRelay`, or
   `SlowReader` could be imported and used (e.g. an integration-test-only
   binary, a debug build tag, a fuzz harness, a wire-up in
   `cmd/coordinator/main.go` guarded by an env var)? Please prove or refute
   with a citation.
2. Do any dashboards, runbooks, or scripts under `dist/`, `scripts/`,
   `beta/`, `audits/`, or top-level shell scripts reference `testfaults`,
   the `/panic` endpoint, or the `SlowReader` helper?
3. Does deleting `panic_endpoint_testfaults.go` orphan any registered route
   in the coordinator HTTP mux, or lose fault-injection coverage that
   existing tests silently depend on?
4. Are `RelayStream` or `providerws` interface expectations affected by
   removing `DeadMidInferenceRelay` (i.e. was it acting as a compile-time
   satisfy check that keeps the interface signature honest)?

### Lane B — security

Threat-model questions:

1. Does removing an intentional-panic handler reduce or increase attack
   surface? Was it ever mounted such that an unauthenticated caller could
   have triggered it in production?
2. Are there any fault-injection safety tests (e.g. verifying the
   coordinator does NOT expose `/panic` when a config flag is off) that
   depend on the code existing?
3. Does the removal touch any code paths that gate authorization, session
   admission, or receipt integrity? (Expected answer: no — the module is
   never imported. Please confirm.)

### Lane C — architect

Design questions:

1. Is `testfaults/` referenced in any current SPEC (specs/SPEC-NNN-*.md),
   architecture doc, or decision-log entry (`beta/DECISION_CRITERIA.md`)?
   If so, the SPEC needs a companion update; if not, deletion is
   unblocking.
2. Is there a planned near-term feature (fault-injection harness for
   SPEC-010, chaos-test rig, streaming-downgrade regression suite) that
   would want this module and is now blocked?
3. Is the coordinator losing a canonical example of how to write a
   fault-inject relay that future tests would naturally have grown from?
   If yes, propose the minimal replacement (e.g. keep `SlowReader` as
   `internal/testutil/slowio.go`); if no, deletion stands.

## Deliverable per lane

Return a plain-text audit report with:

- **Verdict**: `PASS 0 CRITICAL / 0 HIGH / 0 MEDIUM` or a list of findings.
- **Findings**: for each, `SEVERITY | file:line | one-sentence claim | evidence`.
- **Recommendation**: `merge` / `merge after LOW fixes` / `hold`.

Do NOT re-audit unchanged files outside the deleted directory unless a
finding requires citing them for context.
