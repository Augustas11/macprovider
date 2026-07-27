package pool

// Provider-reported capacity is a claim, not a measurement: `max_concurrency`,
// `slots_total`, and `slots_free` all arrive verbatim from the provider binary
// on hello and on every heartbeat. Before issue #764 they were granted as-is,
// so a box reporting 9999 was handed 9999 admission slots — it out-ranked the
// honest fleet and absorbed traffic it could not serve. The clamp below is the
// ingest-side ceiling; it runs upstream of pool.Registry so every downstream
// consumer (routing, relay admission, /poolz capacity, stats) sees only the
// clamped numbers.

// ClampedCapacity is the effective capacity after the operator ceiling has been
// applied to one provider-reported triple.
type ClampedCapacity struct {
	MaxConcurrency int
	SlotsTotal     int
	SlotsFree      int
	// OverClaimed reports that the provider claimed capacity ABOVE the ceiling
	// — the tripwire condition. It is deliberately narrower than "something
	// changed": a coherence-only repair (slots_total above max_concurrency but
	// both under the ceiling) is a provider bug, not an over-claim.
	OverClaimed bool
	// ReportedMax is the raw claim, retained for the tripwire log line.
	ReportedMax int
}

// ClampCapacity applies ceiling to a provider-reported (max_concurrency,
// slots_total, slots_free) triple.
//
// Coherence rules, in order:
//
//  1. effective max_concurrency = min(reported, ceiling)
//  2. slots_total may never exceed the effective max_concurrency
//  3. the used/free relationship is preserved: used = total - free is carried
//     across the clamp, and free is re-derived as total - used. A provider that
//     claims 9999 total / 9999 free (idle) stays fully free after clamping;
//     one that claims 9999 total / 0 free (saturated) stays fully busy.
//
// A ceiling <= 0 disables the clamp and passes the triple through untouched, so
// an operator can restore pre-#764 behavior without a code change. Negative or
// absent reported values are left alone rather than invented: capacity is
// clamped here, never fabricated.
func ClampCapacity(maxConcurrency, slotsTotal, slotsFree, ceiling int) ClampedCapacity {
	out := ClampedCapacity{
		MaxConcurrency: maxConcurrency,
		SlotsTotal:     slotsTotal,
		SlotsFree:      slotsFree,
		ReportedMax:    maxConcurrency,
	}
	if ceiling <= 0 {
		return out
	}
	out.OverClaimed = maxConcurrency > ceiling || slotsTotal > ceiling
	if out.MaxConcurrency > ceiling {
		out.MaxConcurrency = ceiling
	}
	if out.MaxConcurrency < 0 {
		// A negative claim is nonsense the ceiling cannot clamp, and the slot
		// repair below would only propagate it. Leave the triple untouched.
		return out
	}
	// used is computed from the RAW pair so a saturated provider stays
	// saturated after the ceiling shrinks its total.
	used := slotsTotal - slotsFree
	if used < 0 {
		used = 0
	}
	if out.SlotsTotal > out.MaxConcurrency {
		out.SlotsTotal = out.MaxConcurrency
	}
	if out.SlotsTotal < 0 {
		out.SlotsTotal = 0
	}
	if used > out.SlotsTotal {
		used = out.SlotsTotal
	}
	if free := out.SlotsTotal - used; free < out.SlotsFree {
		out.SlotsFree = free
	}
	if out.SlotsFree < 0 {
		out.SlotsFree = 0
	}
	return out
}
