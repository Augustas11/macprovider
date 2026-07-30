// Package versionfloor owns the coordinator's binary-version comparison and
// the per-model minimum-binary-version gate (issue #768).
//
// It is deliberately a dependency-free leaf so every gate that must share the
// SAME verdict can import it: the public routing filter (internal/buyer via
// internal/routing), the self-route / hard-pin preflight path (internal/buyer),
// and the warm-pool candidate gates (internal/ws). "We never warm a box we
// won't route to" only holds if all three call one implementation.
//
// Compare is the single version comparator in the coordinator — the global
// `required_binary_version` admission floor (internal/ws) and the per-model
// floors both use it, so a version string can never mean two different things
// at two different gates.
package versionfloor

import (
	"strconv"
	"strings"
)

// Compare orders two dotted numeric version strings ("1.8.65", "v1.8", "2").
// It returns -1/0/1 and a validity flag; the flag is false when EITHER side is
// not a bare 1-to-3 component numeric version. Callers MUST treat an invalid
// parse as "does not satisfy the floor" — see Check.
func Compare(lhs, rhs string) (int, bool) {
	left, okLeft := parts(lhs)
	right, okRight := parts(rhs)
	if !okLeft || !okRight {
		return 0, false
	}
	n := len(left)
	if len(right) > n {
		n = len(right)
	}
	for i := 0; i < n; i++ {
		var l, r int
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			r = right[i]
		}
		switch {
		case l < r:
			return -1, true
		case l > r:
			return 1, true
		}
	}
	return 0, true
}

// Valid reports whether value parses as a bare numeric version. Used by config
// validation so a typo in an operator-authored floor is rejected at load time
// rather than silently fencing an entire model at runtime.
func Valid(value string) bool {
	_, ok := parts(value)
	return ok
}

func parts(value string) ([]int, bool) {
	value = strings.TrimLeft(strings.TrimSpace(value), "vV")
	if value == "" {
		return nil, false
	}
	fields := strings.Split(value, ".")
	if len(fields) > 3 {
		return nil, false
	}
	out := make([]int, 0, len(fields))
	for _, field := range fields {
		field = strings.TrimSpace(field)
		if field == "" {
			return nil, false
		}
		for _, r := range field {
			if r < '0' || r > '9' {
				return nil, false
			}
		}
		n, err := strconv.Atoi(field)
		if err != nil {
			return nil, false
		}
		out = append(out, n)
	}
	for len(out) < 3 {
		out = append(out, 0)
	}
	return out, true
}

// Result is the verdict of one per-model floor evaluation.
//
// Floor is the configured minimum for the model, empty when none is configured
// (in which case Allowed is always true — an unconfigured map is byte-identical
// to pre-#768 behavior). Malformed marks the fail-safe case: a floor IS
// configured for the model and the provider's reported binary version could not
// be parsed. A provider that reports an unparseable version while a floor is in
// force is suspect, so it is gated out and the caller logs it.
type Result struct {
	Allowed   bool
	Floor     string
	Malformed bool
}

// Check is THE per-model minimum-binary-version gate. Every call site — public
// routing, self-route preflight, warm-pool candidate selection — must go
// through it so the three can never diverge.
//
// Semantics, in order:
//
//	no floors configured, or no floor for this model -> allowed (no behavior change)
//	provider version unparseable                     -> DENIED, Malformed=true (fail safe)
//	configured floor unparseable                     -> DENIED, Malformed=true (defense in
//	                                                    depth; config.Validate rejects these
//	                                                    at load so this is unreachable in prod)
//	provider version < floor                         -> DENIED
//	otherwise                                        -> allowed
func Check(floors map[string]string, modelID, binaryVersion string) Result {
	if len(floors) == 0 {
		return Result{Allowed: true}
	}
	floor := lookup(floors, modelID)
	if floor == "" {
		return Result{Allowed: true}
	}
	cmp, ok := Compare(binaryVersion, floor)
	if !ok {
		return Result{Allowed: false, Floor: floor, Malformed: true}
	}
	if cmp < 0 {
		return Result{Allowed: false, Floor: floor}
	}
	return Result{Allowed: true, Floor: floor}
}

// lookup resolves the floor for modelID. Exact hit first (the hot path), then a
// case-insensitive fallback so operator-authored YAML keys match the same way
// buyer-side model comparison does (strings.EqualFold).
func lookup(floors map[string]string, modelID string) string {
	if v, ok := floors[modelID]; ok {
		return strings.TrimSpace(v)
	}
	target := strings.ToLower(strings.TrimSpace(modelID))
	if target == "" {
		return ""
	}
	for k, v := range floors {
		if strings.ToLower(strings.TrimSpace(k)) == target {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
