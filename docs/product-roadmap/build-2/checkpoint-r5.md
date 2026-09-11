# Product Build 2 planning checkpoint

**Checkpoint revision:** R5
**Status:** R5 correction authored; implementation has not started and remains prohibited pending a fresh independent GPT-5.6 Sol gate with zero Critical, High, and Medium findings
**MacProvider branch/head before this checkpoint:** `codex/product-build-2` / `e2ab2ce221efb2731408f1d852f1e16e1a86b867`
**MacProvider base:** `1d2c930bad81704dd0acc0322226725d8b64aceb`
**Malibu inspected base:** `dc7f425ba7d50c86467f31a82f419df6a0904b13`

## Exact artifacts submitted to the next gate

| Artifact | SHA-256 |
|---|---|
| `prd-implementation-plan-r5.md` | `2a85bc59e8e6c093b71b73506b91d10f52d0fcb649be620ccdb6ea8051399b29` |
| `test-spec-r5.md` | `38f20aa5d785d51464fd0888365fc41b22b1a60baa12a8c0175a44c3b173c98b` |
| `finding-dispositions-r5.md` | `0841782d749adabcf4a596cdfc65975afd39cc6974d7a216c15834f53a1c0fd3` |
| failed predecessor `reviews/plan-r4-sol.md` | `3a2ce35dce0fe1fc4f16168fe19fd06790ed4d07297cc3b0662d29032c3d4f9c` |
| `baseline-assessment-r2.md` | `17abe6f546816929eda655cda7809eb0aa57fad3779c07ea25a2398949f0c3d3` |

Any byte change to the three R5 submission artifacts invalidates these hashes and requires a new checkpoint and gate input.

## R5 corrections

- C3A v3 represents initial create with tagged absent/genesis authority, complete pre-request target, absent cancellation marker, and full create crash/concurrency recovery.
- Go file state uses immutable tails/pointers plus a non-synchronizable Keychain external head. Browser state uses prepared IndexedDB generations plus an authenticated opaque server-head CAS. Mutable-prefix and old-pointer rollback are within the claim.
- C3B defines the signed generation-zero empty root, exact first transition, and domain-separated signer/bundle/profile/pin targets.
- Wallet profile mode requires separately held account and wallet credentials; the API key performs identity/profile/preflight only, and the signed preflight binds the active same-account wallet session.
- Malibu browser acceptance uses an isolated HTTPS static/reverse-proxy harness preserving `/api/mp`, refusing every non-loopback/production target before credentials or sockets, and accurately blocks Safari process-crash evidence without an owned disposable user/VM.
- Recovery first-call math is 263 seconds with four final-batch waves and general non-divisible-shape tests.
- The plan freezes source-callsite error mappings, physical SQLite settings/ceilings/reserves, and bounded global tombstone rates/rows/bytes/pages/checkpoints/kind reserves/pruning.
- Slice 2 is DDL/measurement only and must pass another independent gate before runtime storage implementation.

## Read-only repository evidence

MacProvider source remains pinned to the stated base; this revision changes docs only. Malibu `origin/main` was re-inspected read-only at the stated commit. It still uses `/api/mp`, maps that path to `https://api.streamvc.live` in Vite server proxy, and has no browser-test dependency. Installed Vite 8.0.16 inherits server proxy for preview when preview proxy is absent. The canonical Malibu checkout remains stale with unrelated untracked paths and was not edited.

No `d-inference` source, operator secret, or private key was inspected. No deployment, release, production mutation, economic activation, browser journey, MLX run, or implementation test occurred.

## Resumption sequence

1. Give a fresh independent native GPT-5.6 Sol reviewer the exact hashed R5 artifacts, R4 failed review, baseline, both repository revisions, and prior plan artifacts.
2. Require structured severity/evidence/consequence/required correction plus independent MacProvider and Malibu inspection. Any Critical/High/Medium finding requires R6.
3. If and only if R5 reaches zero, implement normative governance/vectors first, then the DDL/physical measurement slice.
4. Submit the exact DDL and measured capacity artifact to the explicit second gate before coordinator/gateway runtime storage.
5. Keep MacProvider and Malibu implementation in separate worktrees and distinguish dependent from cumulative diffs.
6. Preserve browser, actual MLX, deployed service, and production signing/qualification as separate evidence classes.
