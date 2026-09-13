# Build 1 preparation private store plan v1 — Sol adversarial review

Reviewer: native Codex subagent `gpt-5.6-sol`, high reasoning.
Result: rejected. Gate criterion was not met: 0 Critical, 1 High, 3 Medium, 2 Low/Info.

## High

- H-1: `root.identity` temp recovery contradicted the no-temp-authority rule. Required correction: remove temp promotion/recovery for `root.identity`; create root identity atomically from fresh descriptor-observed root facts or fail closed when final is absent and temps exist; add tests proving a valid raw temp with no final is not promoted.

## Medium

- M-1: authority-root/artifact-root binding was underspecified. Required correction: specify store initialization with exact authority/artifact roots, namespace layout, descriptor identities, and invariant tying lock custody, root locator, and state operations to the same opened descriptor chain.
- M-2: new-file ACL inheritance was not covered strongly enough. Required correction: require and test inherited ACL stripping, zero-length descriptor verification, and no sensitive bytes before ACL-empty verification.
- M-3: over-budget temp recovery behavior was contradictory. Required correction: define one deterministic rule; preferred over-budget recognized temps fail closed with no mutation.

## Low

- L-1: generation zero was not explicitly forbidden at store boundary. Required correction: state whether generation 0 is valid and test it.
- L-2: verification commands were inconsistent between plan and test spec. Required correction: align plan acceptance commands with the test spec and include codec tests as required targeted gate.

## Disposition in v2

- H-1 resolved by forbidding `root.identity` temp promotion and adding a root-temp negative test.
- M-1 resolved by specifying constructor roots and descriptor/root/lock custody invariants.
- M-2 resolved by before-first-sensitive-byte ACL stripping and verification requirements/tests.
- M-3 resolved by making over-budget recovery no-mutation fail-closed.
- L-1 resolved by rejecting store generation 0.
- L-2 resolved by requiring `ModelPreparationPrivateCodecTests` in plan acceptance.
