# Gate A5 OPoI counter audit

Date: 2026-09-26

Scope: the complete uncommitted Gate A5 diff against `9448c7af2`, including
the offline schema-v4 counter, its regression suite, SPEC-032/SPEC-038,
conformance metadata, generated SPEC index, and the enable-gate runbook.

## Result

The three-round audit cap was exhausted without convergence. Round 3 still
reported HIGH and MEDIUM findings, so this audit is **not** a clean Gate A5
audit and must not be represented as 0 CRITICAL/HIGH/MEDIUM.

The round-3 findings were fixed after the cap. Per the campaign rule, no fourth
audit round was run; validation moved to tests and Mac Studio e2e. The final
counter therefore has strong regression and real-Mac execution evidence, but
retains the process risk that the post-round-3 remediation was not independently
re-audited.

| Lane | R1 | R2 | R3 (final audit round) |
| --- | --- | --- | --- |
| Code | request changes | request changes | request changes: HIGH candidate-frame sampling; MEDIUM companion row semantics |
| Security | request changes | request changes | request changes: HIGH verifier PATH hijack; HIGH raw assertions; MEDIUM randomized sampling |
| Architecture | request changes | request changes | request changes: HIGH raw assertions; MEDIUM companion exclusion, frame sampling, per-stratum order, signer custody, and missing SPEC dependency |

## Post-cap remediation

The final implementation:

- pins `/usr/bin/ssh-keygen`;
- binds a signed canonical candidate frame and recomputes the actual ranked
  selection without replacement;
- balances arm order inside every stratum;
- derives focal events from bounded raw source captures containing challenge
  payloads, response transcripts, evaluator output, runtime/provenance fields,
  complete forward membership, and companion rows;
- derives `opoi_pass` only from the closed evaluator output;
- requires a pre-window independent-reviewer receipt and a post-run signed
  source review under separate namespaces;
- requires distinct plan-author, reviewer, and evidence-custodian keys;
- validates exact source identity membership, companion bindings, unique
  forwards, and the final measurement;
- defines the measured metric as focal row zero only, with companion outcomes
  retained as membership and audit evidence; and
- adds the required SPEC-032 dependency and records reviewer custody, review
  quality, seed commitment, and append-only timing as external manual trust
  assumptions.

## Verification after the final remediation

- Local regression suite: `56` tests passed, `0` failed.
- Python compilation: passed.
- Mac Studio regression suite: `56` tests ran, `0` failed, `1` skipped. The
  skipped test is the repository-only `Package.resolved` guard because the two
  exact files were copied to an isolated non-Git directory.
- Local and Studio counter SHA-256:
  `a3c5dd7f0dff0cda021e2754cca00b191c575ab5642bc462279c4e137a0e8310`.
- Local and Studio test SHA-256:
  `5bcca6b1586d08cfa72165e1266d66ea1cfe95be191e177dba7db4aa6cf71f4d`.
- Full Swift suite: `3545` tests executed, `55` skipped, `0` failures.
- Swift package lock check: passed; `Package.resolved` stayed byte-identical to
  `HEAD` with SHA-256
  `e844140818c6b134b4efabca73dfc1024fffb8a12fb5ea8131e0d85c59b20356`.
- `git diff --check`: passed.
- The Studio exercise was isolated and offline. The live provider was not
  paused, restarted, or modified.

This proves counter portability and fail-closed fixture behavior on the Mac
Studio. It does not supply a real signed Gate A5 measurement and does not make
Gate A5 green.
