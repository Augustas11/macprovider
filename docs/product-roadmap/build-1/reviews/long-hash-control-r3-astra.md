# Long hash / short controls r3 — independent Astra architecture gate

Verdict: APPROVED for this focused design. 0 Critical, 0 High, 0 Medium, 0 Low.

Exact reviewed artifact: `docs/product-roadmap/build-1/long-hash-control-addendum-r3.md`.
SHA-256: `19286de938b886e788792ec0d2f3d8e9ec019f8ba26501e400c78d953659db4e`.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Review: r3 clarification against the r1/r2 findings and previously inspected transaction/store/publication/control paths. No source edits, subagents or tests run. This is a plan approval, not implementation or timing acceptance.

## Findings closed

HASH-M1 remains closed by r2’s explicit removal of recursive staging work and full content hashing from short controls, nonblocking/deadline-aware locks, outside-global-lock metadata capture, exact-operation owner exclusion and selector/record CAS. Interrupted recovery only identifies owned staging and exposes the existing explicit long cleanup. Its 100,000-plus-entry, blocked metadata, contended lock and real process-lease tests remain mandatory.

HASH-M2 is closed by the explicit r3 override. Historical transaction success records that the exact owned object underwent actual full byte verification and publication; it is not a claim that descendants remain unchanged at the terminal write. Root identity revalidation proves continued path/object association only. The plan explicitly permits an undetected post-capture in-place mutation to coexist with historical success while requiring fresh full canonical checks to reject present-byte readiness and every subsequent evaluation/adoption/use. It no longer promises root-only rejection of mutations the mechanism cannot observe.

## Implementation acceptance constraints

- Seal material must originate from the actual verifier’s opened descriptors and stable pre/post-read metadata; no argv/env/config override may supply a positive seal. Bind its private digest and authenticated artifact tuple to the exact transaction/generation/context. Missing/corrupt/oversized/misbound proof, extra inventory, detected changes, wrong root/object, absent publication, or deadline cannot fabricate success.
- Keep metadata capture outside the global journal lock, retain exact per-operation exclusion, and reload selector plus record digest/version under the final short lock before mutation. A newer generation, cancellation or context replacement must not be overwritten by an older verification result. No recursive lock acquisition or filesystem traversal is reintroduced in short controls.
- Preserve atomic no-replace publication and original incumbent data. Existing-destination reuse must use its own actual full verification/object evidence; a seal from an unpublished temporary directory cannot substitute for the existing inode. Crash ordering must persist the verified seal binding and intent before publication and recognize the exact destination object after rename, including loss before post-rename bookkeeping.
- Keep historical terminal, current readiness and cleanup outcome distinct. The app must still require terminal plus a fresh projection, and must not unlock prepared/evaluate/adopt controls from historical success alone. Fresh discovery, evaluation and adoption must reject corrupt current bytes even when the recovered historical transaction succeeded.
- Run the three separately asserted race windows from r3: mutation before metadata capture; detected mutation during capture; and same-size in-place mutation after capture but before terminal CAS. The last may preserve historical success, but must reject fresh readiness/evaluation/adoption and produce no artifact-derived paid authority. Also retain root/context/generation replacement negatives and actual helper lease/OS-lock release evidence.

The plan’s explicit trusted-operator-UID boundary remains unchanged: private seal/journal integrity does not claim resistance to that UID rewriting both. Full integrity verification before present use is not weakened. Silent hardware corruption or changes outside metadata observation likewise cannot turn a seal into current-byte verification.

## Scope and remaining gates

Approval applies to this exact r3 historical-proof/short-control design. It does not waive the separate executable-custody or cleanup-selector contracts, the final combined implementation audit, required owner/storage/control/app tests, or physical MLX and release qualification. Fixture deadlines and source analysis do not establish actual large-artifact timing; report that independently. No new background verifier, runtime owner, recovery command, production activation or operator-secret access is authorized by this design.
