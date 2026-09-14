# Build 1 test specification r8 — c944 normative, null, and setter closure

Status: proposed. This revision incorporates r5 SHA-256
`75c942bba7bad61297de5a2567eb06ad436e1944522437f647135023136e6576`,
r6 SHA-256
`69cded9a4aa91c68abccb9bd740f6a78e5c965d571401a8559946cbb9036ffec`,
and r7 SHA-256
`179672cd03554a12eb18393ba520bf560e27f1d6c1f27c84653e10d5c83533d6`.
It pairs with reconciliation r4 and supersedes only the normative-envelope,
numeric-null, and direct-authority-setter coverage below.

## R8-01 — normative governance is executable

Assert the amended SPEC-047 version is the version of record in the document,
README and generated authority/conformance indexes. Its R003/R008 selectors
must select the actual historical-six-field and v2 billing/buyer/WS/integration
tests. Run `scripts/check_spec_governance.py --base-ref origin/main` and the PR
declaration validator against the final diff. Fail on zero selected selectors,
stale version metadata, a hand-edited generated index mismatch, or language that
claims deployment, enforcement, economic activation, or physical qualification.

Golden tests must cite the amended SPEC-047 requirement and prove: exact legacy
six-field canonical bytes/digest from an unmodified c944 fixture; exact v2
discriminator plus 24-field canonical bytes/digest; empty no-extension bytes;
no historical rewrite; and unchanged gateway settlement-policy compatibility.

## R8-02 — numeric null cannot become valid zero

For each of the eight numeric v2 fields—billing configuration snapshot,
prompt rate, cache-hit prompt rate, completion rate, provider share, global
multiplier, authority expiry, and probe expiry—replace the valid token with
literal JSON `null` and assert closed decode fails before canonicalization,
route persistence, debit, credit, or settlement-row creation. Test all eight
individually.

For every numeric field also reject missing, quoted number, fractional number,
exponent form, overflow, boolean, array, and object. Separately prove raw JSON
number `0` succeeds for each rate field whose economics owner permits zero,
while zero remains rejected for positive-only snapshot/expiry fields and range
rules remain enforced for share/multiplier. Include string-field null arms,
duplicate keys, extra keys, trailing tokens, and both catalog-hash spellings.
Record that the failure came from raw-token validation rather than a later
typed-zero relationship mismatch.

## R8-03 — direct authority setter bypass is closed

Under `-race`, table-drive every production and test call site of
`SetModelAdmissionAuthority`, the combined catalog/index publisher, and the new
token-consuming positive publisher.

- Direct/legacy setter use clears or advances authority and cannot install a
  resolver or preparer that returns a positive event.
- A token cannot be default-constructed outside its owner, reused, moved to a
  different server, or consumed after catalog/index replacement, split setter,
  authority clear, session refresh drift, buyer/Tier2/billing generation drift,
  reload, or failed publication.
- The valid production sequence installs exactly one preparer bound to the
  published catalog/index generation and complete epoch.
- Same-package test helpers and cross-package buyer/WS composition tests pass
  only through the same token comparisons; no fixture-only bypass remains.
- `ModelAdmissionAuthorityReady`, preparation, status refresh, route commit,
  and retry all fail closed while the token is absent/stale or publication is
  incomplete.

Pause at catalog/index publication, token return, session refresh, and positive
installation. Race direct setter, feed observer, split catalog/index setter,
disconnect, and reload. Assert one coherent generation or a typed non-paid
failure, bounded sanitized observability, and release of all owners.

## Evidence and gate

R8 is additive to unaffected r5-r7 and upstream c944 tests. Record exact command,
base/head SHA, selected/pass/fail/skip counts, duration, and log hash. Run
targeted race tests before the broader required coordinator, gateway,
integration, Swift, Xcode, dist, vet, lint and governance gates. Skipped,
interrupted, historical, zero-selected, or fixture-only evidence never proves
physical or production acceptance.
