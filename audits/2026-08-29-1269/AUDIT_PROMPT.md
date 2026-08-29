You are auditing a money-path SPEC + implementation change to the MacProvider
provider CLI (Epic #1235 / #1269). Full change = single commit at HEAD
(origin/main..HEAD); diff at audits/2026-08-29-1269/full-diff.patch. Read the
actual files.

## What it does
Redefines the paid-recommendation thermal veto from "any single throttling sample"
to "SUSTAINED thermal throttle", so the install-time recommendation probe (which
runs while the Mac is hot from unpacking/verifying/signing) no longer hard-rejects
an otherwise-capable Mac on a lone transient throttle and rolls it back at upgrade.

Changed:
- specs/SPEC-023-installer-autotune-recommend.md: v0.9.3 -> v0.9.4. thermal_throttle_detected
  amended (line ~220 field table, line ~640 gate, + changelog) to require >=2 readable
  thermal samples throttling (.serious/.critical) AND >=50% of readable samples throttling;
  fail-closed only when the WHOLE thermal series is unreadable. Mirrors the v0.9.0/#742
  swap_detected redefinition.
- phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift: ProbeSafetyAssessment.assess
  thermal branch rewritten from `!thermalKnown || anyThrottle` to the sustained rule.
- phase3-binary/Tests/.../AutotuneRecommendTests.swift: 5 new regression tests.
- specs/CONFORMANCE.json + specs/README.md: version sync.

## Audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM. Focus on:

MONEY-PATH SAFETY (most important):
1. Does the new rule STILL hard-block a genuinely thermally-throttled node? A relaxed
   thermal veto that lets a truly-throttled Mac become a paid provider is a money-path
   regression (bad TTFT/throughput for buyers). Verify the sustained rule (>=2 AND >=50%
   of readable) cannot be gamed by a node that throttles most of the probe.
2. Fail-open risk: any input series where a real throttle now yields
   thermal_throttle_detected == false when it should be true? Consider: mostly-throttling
   with interspersed unreadable samples (does the readable-denominator handle it like
   swap does?); exactly-2 short probe; 50% boundary.
3. Does the SPEC text EXACTLY match the code (>=2, >=50% of READABLE, whole-series-unreadable
   fail-closed)? Any SPEC-vs-code drift? Compare to the swap_detected wording/impl it mirrors.

CORRECTNESS:
4. The code: `readableThermal = samples.compactMap(\.thermalState)`; `throttleCount = readableThermal.filter{shouldThrottle}.count`; `if readableThermal.isEmpty { true } else { throttleCount >= 2 && throttleCount*2 >= readableThermal.count }`. Is `throttleCount*2 >= readableThermal.count` the correct >=50% test (matches swap's `criticalCount*2 >= readable.count`)? Off-by-one?
5. shouldThrottle == (.serious || .critical) — confirm only genuine throttle states count.
6. Behavior change vs old: the OLD rule failed closed if ANY sample was unreadable
   (thermalKnown = allSatisfy non-nil). The new rule only fails closed if ALL are
   unreadable. Is that intentional and consistent with the SPEC amendment + the swap
   fail-closed narrowing? Any case where dropping the any-unknown fail-close is unsafe?
7. Tests: do the 5 new tests actually pin the SPEC rule (transient-no-block, sustained-block,
   short-probe-block, unknown-dilution, lone-spike-no-block)? Any missing boundary (exactly
   50%, exactly 2)? Do the 2 pre-existing thermal assertions still hold?

SCOPE:
8. Confirm this ONLY changes the thermal veto semantics — no change to swap_detected,
   ttft ceiling, RAM/bandwidth gates, catalog integrity, or the wire/evidence schema.
9. Does the amendment stay within SPEC-023's locked-spec amendment convention (version
   bump, changelog, manifest sync)? Is v0.9.4 the right bump?

Report severity-ranked with file:line + concrete failure scenario. If handled correctly,
say so. Do not invent findings. NOTE: a pre-existing spec-index error on
CONFORMANCE.json requirements[9] (verifyProviderModelIdentity / SPEC-010-R005) is
unrelated to this change (it exists on origin/main) — do not report it.
