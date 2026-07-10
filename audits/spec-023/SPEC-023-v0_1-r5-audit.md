# SPEC-023 v0.1 Round 5 Audit

Date: 2026-07-01
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md`
Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

## Result

Round 5 did not pass. The three requested audit lanes reported the following critical/high/medium findings:

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 0 | 1 | 0 | Needs fix pass |
| security | 0 | 0 | 1 | 1 | Needs fix pass |
| architect | 0 | 0 | 0 | 0 | Pass |

## Blocking findings and resolutions

### MEDIUM-CODE-R5-001: bandwidth-tier eligibility was not deterministic

Finding: the spec required `bandwidth_tier` and `min_bandwidth_tier` gates but did not define S/A/B/C ordering or a v0.1 chip-to-tier mapping.

Resolution:
- §3.1 now defines tier order as `S >= A >= B >= C`, with `unknown` treated as `C`.
- §3.1 now includes a v0.1 chip-family mapping table for Ultra/Max/Pro/base/unknown chips.
- Benchmark-derived tier overrides may raise, but not lower, the chip-derived tier only when the benchmark table is compiled into the same binary release.
- §5 now references the §3.1 tier order for `min_bandwidth_tier`.
- AC-35 covers Tier-C failure against Tier-A rows and Tier-A/S success when other gates pass.

### MEDIUM-SEC-R5-001: canonical model hash omitted non-regular file handling

Finding: the artifact-set hash enumerated regular files but did not define symlink, hardlink, special file, absolute path, path escape, or `..` path-segment behavior.

Resolution:
- §3.2 now requires rejecting any downloaded snapshot containing filesystem entries other than regular files or directories.
- Symlinks, hardlinks with link count greater than one, device nodes, sockets, FIFOs, absolute paths, path escapes, and relative paths containing `..` are forbidden.
- The hash algorithm now sorts by normalized POSIX relative path and fails closed before benchmark, recommendation, donor commit, or provider run.
- AC-36 covers malicious/noncanonical filesystem entries.

## Low findings handled opportunistically

- §3.5 now maps stale signed static JSON warnings to the explicit vocabulary: `demand_rank_stale` and `candidate_catalog_stale`.
- The threat model now uses those same warning names.

## Round 6 requirement

Run only the requested three Codex audit lanes again:

- code
- security
- architect

Continue fixing and re-auditing until all three lanes report zero critical, high, and medium findings.
