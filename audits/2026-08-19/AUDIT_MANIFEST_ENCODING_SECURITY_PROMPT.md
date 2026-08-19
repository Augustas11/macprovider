# Codex audit — SPEC-042 R001 manifest canonical encoding — SECURITY lane

Foundational crypto-encoding library for the SPEC-042 pool manifest (phase4,
Go), plus the SPEC amendment that specifies it. Review the FULL slice diff.

Diff: `audits/2026-08-19/manifest-encoding-fulldiff.patch` (one commit on main).
Read `phase4-coordinator/internal/poolmanifest/manifest.go` + `_test.go`, the
design doc `docs/design/spec-042-r001-slice1-manifest-encoding.md`, and the
SPEC-042 R001 "Canonical encoding" paragraph. This slice is encoding + pool_id /
manifest_core_digest derivation + golden vectors ONLY — no signing, authority
log, persistence, or wiring.

## Focus (Critical/High/Medium/Low/Info, file:line + concrete failing scenario)
1. **Injectivity / canonicalization completeness** — the whole point. Can TWO
   distinct logical inputs ever produce identical canonical bytes (a collision
   that would let a policy core be reinterpreted)? Check every field: are all
   length-prefixed so no two adjacent fields can "slide" bytes between them? Any
   field NOT length-prefixed or delimited where concatenation is ambiguous? Is
   the set-ordered allowlist normalization free of collisions (sort + dup
   rejection)? Give a concrete colliding pair if one exists.
2. **Determinism** — same input always same bytes across runs/platforms
   (map iteration, slice aliasing, int width). Any nondeterminism.
3. **Domain separation** — identity-core vs policy-core tags; can an identity-core
   preimage ever equal a policy-core preimage or a prefix of one?
4. **Derivation correctness** — pool_id = base64url(SHA256(...)[0:16]) unpadded;
   manifest_core_digest = SHA256(policy core). Golden vectors correct and actually
   pinning the bytes (not tautological)?
5. **Error handling / edge cases** — empty strings, nil vs empty slices, max
   u32 length, prev-hash length check, duplicate allowlist. Any panic or silent
   wrong output.
6. **SPEC↔code consistency** — does the R001 SPEC paragraph match the code's
   field order and framing exactly? Any drift.

Be adversarial and concrete. Report 0 findings if clean.
