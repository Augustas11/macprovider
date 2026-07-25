# #742 R1 audit tally (full-fix diff)

| Lane | Verdict | C | H | M | L | I |
|------|---------|---|---|---|---|---|
| code | FAIL | 0 | 1 | 0 | 0 | 0 |
| security | PASS | 0 | 0 | 0 | 1 | 0 |
| architect | FAIL | 0 | 0 | 2 | 1 | 0 |

## R1 findings addressed in R2

1. **CODE HIGH** — accept `--gate-ttft-ms 0` as disabled; reject only negatives.
2. **ARCH MEDIUM** — path-dependent default: classic Stage1/2 keeps SPEC-013 60s when omitted; paid `--recommend` defaults to disabled (0).
3. **ARCH MEDIUM / SEC LOW** — SPEC-023 §8 donor text no longer lists no-swap as non-bypassable; swap advisory for donor.
4. **ARCH LOW** — §5/AC-12 wording narrowed: emit `swap_observed_under_load` when swap causes no paid row.

Artifacts:
- `.omc/artifacts/ask/codex-audit-742-*-code-*.md`
- `.omc/artifacts/ask/codex-audit-742-*-securi-*.md`
- `.omc/artifacts/ask/codex-audit-742-*-archit-*.md`
