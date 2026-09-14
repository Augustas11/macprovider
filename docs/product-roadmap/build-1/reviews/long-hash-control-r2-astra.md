# Long hash / short controls r2 — independent Astra architecture gate

Verdict: CHANGES REQUIRED. 0 Critical, 0 High, 1 Medium, 0 Low.

Exact reviewed artifact: `docs/product-roadmap/build-1/long-hash-control-addendum-r2.md`.
SHA-256: `38ed612d0763962587fb28f713de472ae519b58c411ea556f2ceac8320751416`.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`, with current transaction/cleanup implementation inspected for composition. No source edits, subagents or tests run.

## HASH-M1 closure

R2 closes the prior finding at the design level. Short controls explicitly stop recursively deleting or enumerating staging and only set cleanupRequired from bounded staging lstat. Recursive deletion belongs to the existing explicit long-running cleanup owner. Metadata traversal moves outside the global journal lock under exact-operation owner exclusion; final reconciliation uses selector plus unchanged record digest/version checks. Nonblocking/deadline-aware locks and an independent process lifetime prevent hung metadata work from leaving a new runtime worker or holding the global lock throughout the traversal.

The added 100,000-plus staging test correctly checks that status/cancel neither count nor delete entries. Explicit cleanup may conservatively reach its existing limit, preserve data and remain cleanup-required; this is not permission for short controls to bypass the limit. Slow metadata, lock contention, lease expiry, generation replacement, and actual helper lock/PID release are appropriate additional tests.

## HASH-M2 — Root-only final validation cannot provide the promised post-scan content-mutation rejection

Severity: MEDIUM. Confidence: high.

Evidence: r2 intentionally finishes the full seal inventory outside the global journal lock, then under the lock checks the exact operation/record and only bounded root/directory identity. It states that changes since the seal or between control snapshots fail closed. The inherited r1 text also requires rejecting concurrent mutation and before/during/after-hash same-size overwrite.

Counterexample: after the outside-lock scan has checked file F against its seal, an ordinary process of the trusted operator UID overwrites F in place with same-length bytes. The write changes F’s mtime/ctime but leaves the directory inode and its entry metadata unchanged. The final root/directory check and unchanged transaction-record digest both pass. Holding the operation owner lock does not exclude a filesystem writer that does not participate in that lock. No timestamp or inode forgery is required.

Consequence: a metadata result described as proving current unchanged bytes can lead to succeeded despite mutation in the final observation window. The chosen mechanism can establish historical preparation truth under the trusted-UID boundary, but cannot implement the stronger unconditional race-rejection wording or its possible test interpretation. Do not broaden this seal into readiness/adoption authority to close the gap.

Required correction: explicitly define the seal check’s historical observation/linearization boundary and narrow the claim. The simplest compatible design is to use the completed bounded scan as historical evidence of a prior verified publication, with all changes observed during the actual comparisons failing closed; acknowledge that post-observation in-place writes are not detected by root-only revalidation. Such later writes must be caught by independent fresh full-byte verification before readiness, recommendation/adoption or serving, and the app’s terminal-plus-fresh-projection gate must not report prepared/ready from the seal alone. If strict rejection through the final terminal write is required instead, establish an enforced artifact immutability boundary shared by every supported writer; an advisory owner lock alone is insufficient. A new long command is not required for the historical-truth option.

Pin tests on both sides of that boundary: same-size overwrite before/during observed metadata comparisons rejects; inject an overwrite after the last file comparison and before terminal CAS and verify that whichever historical outcome is allowed, fresh discovery/readiness and adoption still reject the corrupt current bytes and no paid authority is produced. Root replacement, generation/config/record replacement and stale cancellation before final CAS must still reject without mutating another operation.

## Remaining sound boundaries

Private seal bytes plus journal digest bind an actual prior full verification under the declared trusted UID; they do not authenticate against that UID rewriting both stores. Complete bounded inventory, device/inode identity, regular ownership/no-follow/no-hardlink checks, high-resolution size/mtime/ctime, rename-aware directory identity, durable seal/intent ordering, and no success from incomplete/expired/missing proof remain necessary. Keep original terminal outcomes distinct from cleanup attempts and use generation-bound CAS for all writes.

R2 does not authorize weakening full canonical artifact verification for future use, adopting from a seal, deleting incumbent/published data, or skipping independent executable-custody/cleanup/final-diff gates. Freeze the small historical-truth clarification before implementation. Physical timing and MLX qualification remain unproven by this plan review.
