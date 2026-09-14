# Reservation search progress analysis r1

Read-only author assessment, not an approved implementation plan. The unresolved requirement is: preserve exact fresh queued reuse, do not allocate a duplicate while an unseen reusable record exists, and permit capacity restoration across bounded eight-second calls at the supported active/record limits. No runtime change is authorized by this document.

## Evidence

Swift29's full-capacity fixture incorrectly required one call. The corrected Swift30 fixture allows at most eight reservation attempts within a 64-second outer deadline, accepts only busy/capacity, and preserves 1,023 unresolved records. It still failed to obtain a new reservation (78.207 seconds including setup/earlier checks). Source inspection shows `reserveOperation` reads and fully decodes every primary before calling maintenance. Every retry starts that search again. The current evidence supports structural starvation; it does not yet isolate a CPU percentage or prove every failed attempt reached the same UUID.

The active limit is 1,024. Primary evidence accepts up to 4,194,304 bytes and records up to 2,048 events. Event progress/error/warning/emitted-at strings are not constrained to a smaller byte limit by the current record validator, so there are valid-shaped large records inside that file bound. One full reuse search can therefore require close to 4 GiB of bytes plus parsing and filesystem checks. No approved storage-throughput minimum proves this can complete within eight seconds. Making JSON decoding faster does not remove that dependency.

The separate legacy retirement failure (271 remaining after the unchanged finite Swift30 passes) is addressed by `retention-active-index-receipt-r1.md`. That proposal removes repeated full-index decoding but does not make this all-primary search bounded independently of total primary bytes.

## Why the negative-only hint is insufficient

A minimal Decodable hint could safely reject obvious nonmatching `kind`/`target`, non-nil `startedAt`, or true committed/cancel/cleanup flags using the already-read bounded bytes. For any plausible match, the existing duplicate-key check, closed schema/event validation, complete authority tuple, primary/origin/sidecar proof and owner/CAS must still run. Hint decode failure would fall through to full validation; it would never authorize reuse, allocation, retirement or index mutation. Unknown or duplicate fields on a plausible match would be rejected by the full validator. Negative hints on malformed records would leave those records retained, just as the present full-validation failure path does. Every valid reusable record satisfies the hint predicates, so this particular prefilter has no valid-record false negatives.

However, it still reads/parses the complete byte range before maintenance. It could improve the small-record fixture while leaving maximum-size or slower-storage starvation intact. It must not be accepted as the complete correction. No such hint has been implemented.

## Why simple scheduling changes are also insufficient

- Giving maintenance time before the search can restore a slot, but the subsequent full search can still exhaust every call before allocation.
- Rotating a search cursor eventually visits every record, but earlier negative observations are mutable. Without a proof that they remain negative, allocating after an accumulated partial scan could miss a newly reusable or substituted record. A cursor is not authority.
- Allocating after a partial search, shortening the fixture, increasing the operation deadline or retrying without a finite bound violates the required contract.
- Holding all UUID owners or a global lock over a multi-call bulk scan conflicts with owner/watchdog and short-control guarantees.

## Required structural decision

The durable representation must let a request prove queued eligibility or its absence without rereading every historical primary. A viable direction is a bounded per-authority reservation slot or immutable monotonic reuse-exclusion evidence, with authority defined by the exact existing prepare/evaluate tuple. That is a persistence/transition change and requires a separate complete design and independent review, not a silent decoder optimization.

For a slot design, every new allocation must atomically bind the one eligible queued UUID/generation/origin to the authority before exposing it. A later request reads and fully validates that referenced primary; only a proven non-reusable referenced operation permits replacing the slot with a fresh reservation. Start/cancel need not silently erase history. Allocation-intent/record/origin/slot ordering and every crash recovery observation must be explicit. Concurrent allocations cannot bypass the slot's exact CAS.

Migration is the difficult part: existing allocated journals may include several matching queued candidates or unfinished operations. New slots cannot be derived from an untrusted lossy hint, guessed epoch or incomplete scan. A resumable migration must conservatively retain every potentially reusable original, establish durable eligibility/exclusion evidence under exact owner/primary/origin guards, and refuse new allocation while an unresolved candidate could still be reusable. Any exclusion must remain authoritative even if a mutable primary is rolled back; merely caching `startedAt != nil` across calls is insufficient. Existing protected/legacy outcomes remain read-only and never gain generated authority. All new sidecars/index references require the same file safety, deletion/substitution protection and immutable archive policy as the approved binding contract.

This direction is intentionally not presented as an implementation-ready schema. The lead should assign a bounded architecture decision for queued reservation representation and migration while the independent active-index receipt correction proceeds. The selected design must include finite-progress tests using 1,024 maximum-shape records and controlled slow outside-lock reads, queued candidates placed last, competing allocations/start/cancel, corrupt/duplicate/unknown-key records, real crash points, unchanged eight-second budgets, and a proof that unseen candidates cannot produce duplicate allocation.
