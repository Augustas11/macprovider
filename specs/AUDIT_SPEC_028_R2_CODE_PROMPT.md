# AUDIT_SPEC_028_R2_CODE_PROMPT

You are auditing `specs/SPEC-028-mlx-speculative-decoding.md` from the CODE lane.

Audit target: SPEC-028 v0.2-draft only. Treat the current branch as a
research/spec branch: do not propose executable code, and do not audit unrelated
repository changes.

Controlling context:

- `specs/SPEC-028-mlx-speculative-decoding.md`
- `docs/research/spec-decode-integration-2026-07.md`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
- `phase3-binary/Sources/MacProviderCore/Config.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Package.swift`
- `phase3-binary/Package.resolved`

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Is every FR implementable against the current Swift runtime and config
  layering?
- Do `--draft-model`, `--num-draft-tokens`, YAML, and env precedence match
  existing serve-knob patterns?
- Is FR-4's capacity/headroom refresh concrete enough to implement and test?
- Does FR-5's greedy-only gate avoid accidental speculative decoding for
  stochastic buyer requests?
- Are FR-8 telemetry fields and AC-7/AC-8 precise enough for unit/integration
  tests?
- Are warm-swap snapshot and counter-reset requirements implementable without
  races?
- Are AC-10 and AC-11 runnable in a future implementation PR, including the
  baseline/spec ratio measurement?
- Does the SPEC leave any code path ambiguous enough that two reasonable
  implementers would produce incompatible behavior?

Output format:

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity:

- `CODE-C-1`, `CODE-H-1`, `CODE-M-1`, `CODE-L-1`, etc.
- Each finding must cite the SPEC section and concrete repo/spec evidence.
- Do not include Critical/High/Medium findings unless they should block LOCK.
- Low findings may be left for later; the stop bar is 0 C/H/M.
