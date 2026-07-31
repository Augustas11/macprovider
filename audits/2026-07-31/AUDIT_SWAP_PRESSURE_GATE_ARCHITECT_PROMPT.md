# Codex ARCHITECT audit — swap-gate → memory-pressure fix (branch fix/swap-pressure-gate)

You are an architecture/design auditor. Judge design soundness and regression risk; DO NOT edit any files.

## What to read
- Full fix diff: `/Users/augstar/macprovider-poc/scratchpad/swap-pressure-fulldiff.patch`
- Source: `/Users/augstar/macprovider-swap-pressure-gate/phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
- Spec: `/Users/augstar/macprovider-swap-pressure-gate/specs/SPEC-023-installer-autotune-recommend.md` (§5 gate, AC-12, the swap bullets), `specs/CONFORMANCE.json`

## Context
Goal: unblock legitimate provider self-onboarding (network growth) by fixing a gate that false-rejected ~100% of genuine 8GB installs on first try, WITHOUT regressing PR #742's protection against a real 32GB thrash incident. The old signal (`vm_stat` Pageouts delta, machine-wide, zero threshold, sampled once before/after) is replaced by `kern.memorystatus_vm_pressure_level`, interval-sampled, blocking only on sustained CRITICAL; WARNING-majority is advisory. The `swap_detected` wire field is preserved (its meaning tightens) to avoid a coordinator contract change.

## Audit focus (rate CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line + rationale)
1. **#742 preservation:** does sustained-CRITICAL still block the exact incident #742 was added for (a 32GB Mac thrashing on qwen3-coder-30b)? Is the regression test now MEANINGFUL (it previously encoded the incident as pageouts 10→11, delta=1)? Is there a realistic thrash scenario that now slips through where the old gate would have caught it, and does that matter given the growth goal?
2. **Threshold defensibility:** is ">=3 samples AND >=50% critical" defensible without a measured incident-magnitude corpus, or is it arbitrary? Is the conservative-ship-now-plus-telemetry-to-calibrate approach sound? Is 500ms/3-samples the right cadence, or should it be time-based (e.g. sustained for N seconds) rather than count-based?
3. **Semantic overloading:** is it sound to keep the wire field named `swap_detected` while changing its meaning to "sustained memory-pressure thrash"? Does any consumer (coordinator, evidence reconciliation, stats) rely on the old "pageout" meaning such that the tightened semantics cause drift? Should the SPEC/field be renamed instead (bigger change) — flag the tradeoff.
4. **Coupling / buyer-UX architecture:** the design leans implicitly on `buyerTTFTCeilingExceeded` as the real buyer-quality gate, but that defaults to disabled (0). Is it an architectural gap that the primary buyer-protection is off by default, and does this fix make that gap materially worse? Should the fix also set/recommend a default ceiling, or is that out of scope?
4b. **Per-tier consistency:** the gate now behaves identically across all RAM tiers. Is there any tier (e.g. 32GB/64GB) where sustained-CRITICAL is TOO permissive or TOO strict relative to intent?
5. **Spec conformance:** does the SPEC-023 v0.9.0 amendment accurately and completely describe the new behavior (all touched bullets: §5 gate, field table, eligibility bullet, AC-12)? Any spec/code drift? Is bumping to v0.9.0 (vs v0.8.7) appropriate for a behavior change of this size? Are requirement IDs handled correctly (none invented)?
6. **Blast radius:** any downstream (telemetry consumers, dashboards, donor-mode path, hardware-evidence submission) that silently changes behavior because swap now fires far less often?

## Output
Ranked, most-severe first: severity, file:line, one-sentence issue, rationale. If zero C/H/M, say so explicitly. Distinguish NEW regressions introduced by this diff from pre-existing conditions.
