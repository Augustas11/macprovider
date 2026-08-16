# SPEC-017 v0.1.8 — Round 2 Adversarial Audit (Claude Subagent)

HEAD reviewed: `264a606`
Worktree: `/Users/augstar/macprovider-spec017-step1/`

## Verdict

**REQUEST CHANGES** — round-1 code fixes verify clean, but the
round-1 fix introduced a NEW SPEC↔IMPL drift in §5.9 that nobody
closed, and a parallel BUILD prompt drift at line 462. Lock bar
(0C/0H/0M) is not met because of the §5.9 drift.

`Blocking count: 0 CRITICAL / 0 HIGH / 2 MEDIUM / 1 LOW / 2 INFO`

## Round-1 fix verification

### Fix 1 — 304 CORS omission (round-1 HIGH): **PASS**

- `phase4-coordinator/internal/stats/handlers.go:710` calls
  `writeCORSHeaders(...)` BEFORE the 304 branch at line 711-719.
  CORS headers land on both 304 and 200 paths.
- `phase4-coordinator/internal/stats/handlers_integration_test.go:379-408`
  test `TestAC12_304IfNoneMatch_CORSHeadersPresent` exercises
  both `/v1/stats/overview` and `/v1/stats/leaderboard` with
  `Origin: https://console.malibu.tech` and asserts
  `Access-Control-Allow-Origin` on the 304 response. Both
  subtests PASS on a clean run.
- Sanity check inside the test also asserts the 200 response
  carries ACAO before going to 304 — protects against silent
  regressions of the 200 path.
- `TestAC13_OptionsPreflight` PASS — the CORS placement change
  does NOT break the OPTIONS preflight path.

### Fix 2 — `burst=59` SPEC erratum (round-1 MEDIUM): **PASS WITH CAVEAT**

- `specs/SPEC-017-network-stats-api.md:1125-1156` v0.1.8 erratum
  is honest. It openly admits the earlier "no `burst=` parameter"
  text was incorrect on nginx semantics, names the mechanically
  correct production directive `burst=59 nodelay`, and explains
  why "no burst absorption" only refers to long-term throughput
  amplification.
- `specs/SPEC-017-network-stats-api.md` §0 changelog updated.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md:22` top-of-file erratum
  bullet updated.
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md:569` §4.B nginx directive
  text updated.
- **CAVEAT (NEW MEDIUM finding below)**:
  `specs/BUILD_SPEC_017_IMPL_PROMPT.md:462` was NOT updated and
  still tells the implementer "Hard 60 req/min per (IP,
  endpoint) tuple; **no burst absorption**" — inconsistent with
  the erratum.

### Fix 3 — AC-12 test exercises `/leaderboard` not `/overview` (round-1 MEDIUM): **PASS**

- `handlers_integration_test.go:381` covers BOTH endpoints in a
  `for _, path := range []string{...}` loop. Both subtests PASS.

## New findings (Round 2)

### [MEDIUM] SPEC §5.9 says 304 carries "only RFC 7232 headers" — now contradicted by the round-1 fix

**File**: `specs/SPEC-017-network-stats-api.md:1292-1294`

§5.9 says: "304 Not Modified is exempt: it MUST be returned with
an empty body and only the headers required by RFC 7232 (ETag,
Cache-Control, Vary)." The round-1 fix in `handlers.go:710` now
also writes `Access-Control-Allow-Origin` to the 304 response.
The implementation now violates the literal SPEC text.

**Fix**: Update §5.9 to acknowledge that the 304 carries the
§5.7 projection-aware CORS headers in addition to the RFC 7232
headers, OR add an explicit 304-CORS sentence in §5.7. One-line
patch.

### [MEDIUM] BUILD_SPEC_017_IMPL_PROMPT.md §4.B (line 462) still says "no burst absorption"

A future implementer re-running this prompt would read line 462
(the actionable instruction) and follow "no burst absorption",
contradicting the erratum at line 22 and the nginx directive at
line 569.

**Fix**: Append `(short-term bucket capacity burst=59 nodelay
required for AC-8's 60-immediate contract; see §5.6 erratum)` or
replace "no burst absorption" with "no LONG-TERM burst
absorption".

### [LOW] Partner-projection 304 path is not exercised by the new test

`TestAC12_304IfNoneMatch_CORSHeadersPresent` sends an Origin but
no Authorization → public projection path only. The
`writeCORSHeaders` partner branch (with "NEVER ACAO: *"
invariant) is not exercised for 304. Low risk because the
branch is identical between 200 and 304.

### [INFO] `redactErrMsg` misses non-postgres DSN schemes, JWTs, PEM keys, base64 secrets

Confirmed gaps via 12-probe sweep: `mysql://`, JWT,
`-----BEGIN PEM-----`, base64 secrets, lib/pq kv-form
`password=hunter2` all pass through. No production rollup code
path produces those forms; the gap is theoretical for v0.1.8.

### [INFO] `redactErrMsg` truncates AFTER regex — a non-matched secret at byte 200-256 survives intact

Pattern-mismatch + truncate is a defense-in-depth gap, not an
active leak.

## What I tried to refute this round

1. **Did the round-1 CORS fix break the 200 path or OPTIONS preflight?** No — all 4 subtests pass; sanity check inside the test catches 200-path regressions; full integration suite PASS in 146s.
2. **Is the SPEC erratum mechanically honest?** Yes — math is sound; wording is honest about the trade-off.
3. **Does `redactErrMsg` miss realistic production secrets?** Yes for theoretical forms, but production rollup only handles postgres URI form which IS caught.
4. **`boundedHealthCtx` race with `Runner.Wait()`?** No — Wait() is bounded to ≤5s per outstanding tick.
5. **Does the SPEC body remain internally consistent?** No — §5.9 still says "only RFC 7232" (new MEDIUM).
6. **Are OPS.md §10 commands mechanically executable?** Yes — all four sub-verbs accept --config.
7. **Does `isLoopbackHost` close the bind-loopback guard fully?** Yes — only loopback hosts pass; error message names `partner_key_id` and `enumeration oracle`.
8. **Does the BUILD prompt stay internally consistent?** No — line 462 still has unqualified "no burst absorption" (new MEDIUM).

## Final recommendation

**REQUEST CHANGES** for two doc-only fixes:

1. `specs/SPEC-017-network-stats-api.md` §5.9 around line 1292-1294
2. `specs/BUILD_SPEC_017_IMPL_PROMPT.md:462`

After both doc patches, the lock bar (0C/0H/0M) is met. The Go
code on HEAD `264a606` is correct as-is. No code changes
required.

(This audit's deliverable file was authored by the parent
agent after the subagent's read-only tool constraint prevented
direct Write; content is preserved verbatim from the
subagent's final response per the system instructions.)
