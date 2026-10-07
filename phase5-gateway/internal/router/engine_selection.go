package router

import (
	"net/http"
	"strings"
)

// SPEC-006-R016 / SPEC-042-R014 (#1690 M7): buyer engine selection.
const (
	// engineSelectHeader is the inbound buyer-facing engine selector. Like
	// poolSelectHeader it is never forwarded verbatim (copyForwardHeaders
	// allowlists only Accept / X-MacProvider-Retry / Idempotency-Key); the
	// gateway emits engineEmitHeader itself.
	engineSelectHeader = "X-MacProvider-Engine-Select"
	// engineEmitHeader carries the mapped runtime class to the coordinator. It
	// is in the coordinator's X-MacProvider-Internal-* namespace, so it is
	// honored only under the gateway service-token bearer.
	engineEmitHeader = "X-MacProvider-Internal-Engine"
	// engineResponseHeader is the coordinator's served-runtime-class
	// disclosure, forwarded to the buyer through buyerVisibleEngineHeader.
	engineResponseHeader = "X-MacProvider-Engine"
	engineClassNative    = "mlx_cache"
)

// engineRuntimeClasses is the closed selector vocabulary and its SPEC-046-R002
// runtime classes. Matching is exact and case-sensitive.
var engineRuntimeClasses = map[string]string{
	"native":   engineClassNative,
	"llamacpp": "llamacpp_loopback",
	"lmstudio": "lmstudio_loopback",
	"mlxlm":    "mlxlm_loopback",
	"ollama":   "ollama_loopback",
	"omlx":     "omlx_loopback",
}

var (
	errEngineSelectionInvalid = &poolSelectionError{
		status:  http.StatusBadRequest,
		typ:     "invalid_request_error",
		code:    "invalid_engine_selection",
		message: "Invalid engine selection",
	}
	errEngineUnavailable = &poolSelectionError{
		status:  http.StatusServiceUnavailable,
		typ:     "service_unavailable",
		code:    "engine_unavailable",
		message: "Selected engine is available only on a Trusted Pool route that allows it",
	}
)

// resolveEngineSelection returns the runtime class to emit, "" for no
// selection, or a typed rejection. It runs after resolvePoolSelection, so an
// unknown or unauthorized pool has already been answered with the generic
// pool_unavailable and nothing here can confirm a pool exists. A non-native
// class without a pool is refused here, before quota reservation; the
// coordinator enforces the pool's runtime allowlist (SPEC-042-R014).
func resolveEngineSelection(headers http.Header, poolID string) (string, *poolSelectionError) {
	var selector string
	for _, raw := range headers.Values(engineSelectHeader) {
		v := strings.TrimSpace(raw)
		if v == "" {
			continue
		}
		if selector == "" {
			selector = v
		} else if v != selector {
			return "", errEngineSelectionInvalid
		}
	}
	if selector == "" {
		return "", nil
	}
	class, ok := engineRuntimeClasses[selector]
	if !ok {
		return "", errEngineSelectionInvalid
	}
	if class != engineClassNative && poolID == "" {
		return "", errEngineUnavailable
	}
	return class, nil
}

func isEngineResponseHeader(key string) bool {
	return strings.EqualFold(key, engineResponseHeader)
}

// buyerVisibleEngineHeader returns the value only if it is byte-exactly one of
// the runtime classes a buyer can select, else "" (drop), so an upstream can
// never smuggle arbitrary content past the X-MacProvider-* strip.
func buyerVisibleEngineHeader(raw string) string {
	for _, class := range engineRuntimeClasses {
		if raw == class {
			return raw
		}
	}
	return ""
}

// SPEC-006-R018 (#1816) pool-model response disclosure headers.
const (
	poolModelDisclosureResponseHeader    = "X-MacProvider-Model-Disclosure"
	poolManifestCoreDigestResponseHeader = "X-MacProvider-Pool-Manifest-Core-Digest"
	poolModelDisclosureClass             = "pool_attested_unverified"
)

// buyerVisiblePoolModelHeader reports whether key is one of the pool-model
// disclosure headers and returns the value to forward: the disclosure only
// as the exact pool_attested_unverified literal, the manifest digest only as
// 64 lowercase hex; any other value is dropped ("").
func buyerVisiblePoolModelHeader(key string, values []string) (string, bool) {
	switch {
	case strings.EqualFold(key, poolModelDisclosureResponseHeader):
		for _, value := range values {
			if value == poolModelDisclosureClass {
				return value, true
			}
		}
		return "", true
	case strings.EqualFold(key, poolManifestCoreDigestResponseHeader):
		for _, value := range values {
			if isLowerHex64Header(value) {
				return value, true
			}
		}
		return "", true
	}
	return "", false
}

func poolModelDisclosureAllowed(poolID, modelID string, h http.Header) bool {
	return poolID != "" &&
		strings.HasPrefix(modelID, "pool/"+poolID+"/") &&
		poolModelIDRe.MatchString(modelID) &&
		strings.TrimSpace(h.Get("X-MacProvider-Provider")) != ""
}

func isLowerHex64Header(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, ch := range value {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return false
		}
	}
	return true
}
