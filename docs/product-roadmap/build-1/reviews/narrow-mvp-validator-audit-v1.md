# Build 1 narrow MVP evidence-validator implementation audit v1

Scope: `scripts/validate-build1-narrow-mvp-evidence.py`, `scripts/tests/test_build1_narrow_mvp_evidence.py`, and the Build 1 narrow MVP planning artifacts under `docs/product-roadmap/build-1/`.

Base/dependency: `codex/build1-mvp-narrow` is a dependent branch on `origin/codex/build1-v2-storage-projection` / PR #1510. This record does not claim PR #1510 is merged.

Approved plan artifacts:

- `docs/product-roadmap/build-1/narrow-mvp-plan-v6.md` — `80f401fb62b78b49afca84932d63483e6997646d6873795f4be6a536b168939d`
- `docs/product-roadmap/build-1/narrow-mvp-test-spec-v6.md` — `073c31b623d981e9d9051f8f14d41d5576df2ed2b3eb9daa225407e06d67f44b`

## Local verification

Last local verification commands:

```bash
python3 -m unittest scripts.tests.test_build1_narrow_mvp_evidence
python3 -m py_compile scripts/validate-build1-narrow-mvp-evidence.py scripts/tests/test_build1_narrow_mvp_evidence.py
python3 scripts/validate-build1-narrow-mvp-evidence.py <generated-valid-fixture.json>
shasum -a 256 docs/product-roadmap/build-1/narrow-mvp-plan-v6.md docs/product-roadmap/build-1/narrow-mvp-test-spec-v6.md
git diff --check
```

Results:

- Unit tests: 57 tests passed.
- Python compilation: passed.
- CLI smoke on the generated valid fixture: printed `schema-valid` and exited 0.
- Approved v6 digests matched the recorded plan-gate values.
- Whitespace check: passed.

## Independent GPT-5.6 Sol audit lanes

Earlier audit rounds correctly found blocking issues in fractional settlement math, stale/self-authored physical provenance, redaction diagnostics, current provider-output compatibility, route-time freshness, nested overclaim surfaces, unrestricted provenance strings, boolean-as-zero settlement fields, and tainted diagnostic value echoes. Those issues were corrected before this record was finalized.

Final passing lanes on the 57-test snapshot:

- Code review: `/root/b1_mvp_final_code_audit_sol_v16` reported 0 Critical, 0 High, and 0 Medium findings.
- Security review: `/root/b1_mvp_final_security_audit_sol_v16` reported 0 Critical, 0 High, and 0 Medium findings.
- Architecture review: `/root/b1_mvp_final_arch_audit_sol_v16` reported 0 Critical, 0 High, and 0 Medium findings.

Carried Low finding:

- `narrow-mvp-plan-v6.md` records the operator-provided historical source path `/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`. This remains only a Low local-path hygiene issue because changing v6 would invalidate the independently approved digest. Redact only if the plan gate is deliberately reopened or the artifact is polished for broader publication.

## What the validator now rejects

The validator rejects weak or mislabeled Build 1 physical-acceptance bundles, including:

- fixture, skipped, timed-out, zero-selected, historical, or operator-claimed physical acceptance evidence, including nested and variant spellings;
- raw URLs, raw private paths, endpoint-shaped coordinator/gateway/host values, localhost/IP/single-label endpoints, and common cloud/API credential values;
- secret-bearing keys including API, auth, bearer, private-key, payout/wallet/hot-wallet, KEK, and separator/camel-case variants;
- production activation, readiness, qualification, rewards, payout, release, or enforcement claims;
- non-physical providers, served-count-only correlation, missing source-capture digests, or provider/request/settlement identity drift;
- untrusted artifact-feed signer, stale/unmeasured feed authority, wrong primary artifact, artifact binding drift, missing BYOM admission binding, wrong route-snapshot policy, and digest substitution;
- non-SPEC-015 v0.4 usage, receipt-version, attempt, route snapshot, and coordinator half-even integer settlement math mismatches.

## Non-claims

This slice is a structural evidence-bundle validator only. A `schema-valid` result does not by itself complete Build 1 physical acceptance. Physical qualification still requires independent review of the referenced redacted source captures plus the real staging run. This slice does not enable production enforcement and does not activate rewards or payouts.
