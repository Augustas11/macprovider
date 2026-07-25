# #742 final audit tally

Full-fix audits of `origin/main...HEAD` for the complete #742 change.

| Round | Lane | Verdict | C | H | M | L | I |
|-------|------|---------|---|---|---|---|---|
| R1 | code | FAIL | 0 | 1 | 0 | 0 | 0 |
| R1 | security | PASS | 0 | 0 | 0 | 1 | 0 |
| R1 | architect | FAIL | 0 | 0 | 2 | 1 | 0 |
| R2 | code | PASS | 0 | 0 | 0 | 0 | 0 |
| R2 | security | PASS | 0 | 0 | 0 | 0 | 0 |
| R2 | architect | FAIL | 0 | 0 | 1 | 0 | 0 |
| R3 | architect | PASS | 0 | 0 | 0 | 0 | 0 |

**Final: 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.**

## R1 → fixes

1. CODE HIGH: accept `--gate-ttft-ms 0` as disabled; reject only negatives.
2. ARCH MEDIUM: path-dependent default — classic Stage1/2 omit → 60s (SPEC-013); paid `--recommend` omit → disabled (AC-3).
3. ARCH MEDIUM / SEC LOW: SPEC-023 §8 donor no longer lists no-swap as non-bypassable.
4. ARCH LOW: §5/AC-12 warn wording narrowed to no-paid fallthrough.

## R2 → fixes

1. ARCH MEDIUM: §7.2 + AC-21 allow conditional swap diagnostic in donor transcript.

## Carried LOW/INFO

None remaining after R3.
