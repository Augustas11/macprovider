# Build 1 pending-offer retry persistence addendum — revision 1

Status: awaiting independent Astra gate; implement no journal changes until
approved. Supplements approved plan-r4/test-spec-r4, base f5edeaeb dependency.

Code evidence: BYOMModelAdmissionRuntime.submitOffer signs a closed offer tuple;
the existing closed model_admission_status.v1 readback omits discovery/evaluation
digests, runtime source, artifact hash and disclosure class. A safe retry cannot
reconstruct the original tuple from status. Expanding that closed wire schema
would break compatibility, while recomputing a new evaluation would not retry
the pending offer. The signed retry endpoint preserves the same tuple and
requires fresh nonce, idempotency key and timestamp.

Add a bounded private local pending-offer journal owned by the CLI alongside
its local discovery namespace (config/test-isolated root, never repo root).
Store only the validated closed signed offer envelope and local lifecycle
metadata, never bearer tokens, private signing material or arbitrary discovery
documents/paths. Directory 0700, file0600, regular files and no symlink traversal,
atomic writes under a per-provider/candidate lock. Key filenames by digest of
provider and candidate identity, not caller path strings. Bound serialized size
to the existing offer payload bound and total journal count (128 records); fail
with actionable storage error rather than silently losing replay recovery.

Write before initial submission, so an ambiguous network result still has the
attempt's exact tuple. Retain the last submitted envelope until confirmed
withdrawal/replacement, and never overwrite an unresolved attempt with a
different tuple as a side effect of retry. Ordinary explicit new offers may
replace through the same lock after preserving an unresolved marker; server
current-event/tuple checks remain final authority. Retry reads status first,
requires a retryable pending state and the original local envelope, checks
provider/candidate and current admission public-key identity, then signs the
unchanged tuple with fresh nonce/time/idempotency. Key rotation or missing/
corrupt/stale/mismatched journal requires a fresh explicit offer, not a guessed
retry. No journal grants authority: server validates signature/current identity,
pending tuple, current state and CAS again. Refuse revoked/withdrawn and never
rewrite status or fabricate successful probe/admission.

Tests: initial submission records before HTTP; timeout after server acceptance
can retry without recomputed tuple; restart recovers exact tuple; missing/corrupt
record fails without retry HTTP; cross-provider/candidate/key/tuple substitutions
fail; two concurrent submission/retry attempts serialize and stale one cannot
overwrite new journal; bounded count/size and symlink/write-failure negatives;
no token/private-key persistence; fresh nonce/time/signature with same protected
tuple. Existing closed readback schema and provider signature/replay tests stay
unchanged. Physical acceptance remains unproven until the full real journey.
