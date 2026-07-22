// Package providerevents implements the Partial #535 durable provider
// connection-event journal and last-known offline snapshot store.
package providerevents

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// Closed failure taxonomy from issue #535. Unknown close strings map to
// ReasonOther so Prometheus label cardinality stays bounded.
const (
	ReasonInvalidToken                  = "invalid_token"
	ReasonInvalidAuthRequest            = "invalid_auth_request"
	ReasonNoCommonAEADSuite             = "no_common_aead_suite"
	ReasonTier2AttestationFailed        = "tier2_attestation_failed"
	ReasonVersionUnsupported            = "version_unsupported"
	ReasonWarmupFailed                  = "warmup_failed"
	ReasonHeartbeatStale                = "heartbeat_stale"
	ReasonProviderWebsocketDisconnected = "provider_websocket_disconnected"
	ReasonUpgradeFailed                 = "upgrade_failed"
	ReasonUnrecognizedAuthMessage       = "unrecognized_auth_message"
	ReasonPoolFull                      = "pool_full"
	ReasonOther                         = "other"
)

const (
	KindUpgradeFailed  = "upgrade_failed"
	KindAuthRejected   = "auth_rejected"
	KindAuthAccepted   = "auth_accepted"
	KindDisconnect     = "disconnect"
	KindWarmupFailed   = "warmup_failed"
	KindHeartbeatStale = "heartbeat_stale"
)

const (
	OutcomeSuccess = "success"
	OutcomeFailure = "failure"
)

const (
	AuthStageUpgrade      = "upgrade"
	AuthStageFirstMessage = "first_message"
	AuthStageProof        = "proof"
	AuthStagePostAuth     = "post_auth"
	AuthStageWarmup       = "warmup"
	AuthStageLiveness     = "liveness"
)

const (
	MessageFamilyHello       = "hello"
	MessageFamilyAuthRequest = "auth_request"
	MessageFamilyMissing     = "missing"
	MessageFamilyOther       = "other"
	MessageFamilyNone        = "none"
)

const (
	DefaultMaxDiagnostic  = 256
	DefaultEventsQueryCap = 100
	DefaultPerProviderCap = 2000
)

var (
	secretLike   = regexp.MustCompile(`(?i)(bearer\s+[a-z0-9._\-+=/]+|mpk_[a-z0-9]+|authorization\s*[:=]\s*\S+|token\s*[:=]\s*\S+)`)
	knownReasons = map[string]struct{}{
		ReasonInvalidToken:                  {},
		ReasonInvalidAuthRequest:            {},
		ReasonNoCommonAEADSuite:             {},
		ReasonTier2AttestationFailed:        {},
		ReasonVersionUnsupported:            {},
		ReasonWarmupFailed:                  {},
		ReasonHeartbeatStale:                {},
		ReasonProviderWebsocketDisconnected: {},
		ReasonUpgradeFailed:                 {},
		ReasonUnrecognizedAuthMessage:       {},
		ReasonPoolFull:                      {},
		ReasonOther:                         {},
	}
)

// NormalizeFailureReason maps a WS close reason or internal reason string onto
// the closed taxonomy. Never returns attacker-controlled free text.
func NormalizeFailureReason(reason string) string {
	r := strings.ToLower(strings.TrimSpace(reason))
	if r == "" {
		return ReasonOther
	}
	switch {
	case r == ReasonInvalidToken || strings.HasPrefix(r, "invalid_token"):
		return ReasonInvalidToken
	case strings.HasPrefix(r, "version_unsupported"):
		return ReasonVersionUnsupported
	case r == ReasonNoCommonAEADSuite || strings.Contains(r, "no_common_aead"):
		return ReasonNoCommonAEADSuite
	case strings.Contains(r, "attestation"):
		return ReasonTier2AttestationFailed
	case r == ReasonWarmupFailed || strings.Contains(r, "warmup_failed"):
		return ReasonWarmupFailed
	case r == ReasonHeartbeatStale || strings.Contains(r, "heartbeat stale") || strings.Contains(r, "inactive past threshold"):
		return ReasonHeartbeatStale
	case r == ReasonProviderWebsocketDisconnected || strings.Contains(r, "websocket disconnected") || strings.Contains(r, "provider_disconnected"):
		return ReasonProviderWebsocketDisconnected
	case r == ReasonUpgradeFailed || strings.Contains(r, "upgrade failed"):
		return ReasonUpgradeFailed
	case strings.Contains(r, "unrecognized auth") || r == "unrecognized auth message":
		return ReasonUnrecognizedAuthMessage
	case strings.Contains(r, "invalid_hello") || strings.Contains(r, "invalid_auth"):
		return ReasonInvalidAuthRequest
	case strings.Contains(r, "too_many_unauthenticated") || strings.Contains(r, "pool_full") || strings.Contains(r, "provisional_pool"):
		return ReasonPoolFull
	}
	if _, ok := knownReasons[r]; ok {
		return r
	}
	return ReasonOther
}

// RedactDiagnostic removes secret-shaped substrings and bounds length.
func RedactDiagnostic(raw string, maxRunes int) string {
	if maxRunes <= 0 {
		maxRunes = DefaultMaxDiagnostic
	}
	cleaned := secretLike.ReplaceAllString(raw, "[redacted]")
	cleaned = strings.ToValidUTF8(cleaned, "")
	cleaned = strings.TrimSpace(cleaned)
	if cleaned == "" {
		return ""
	}
	if utf8.RuneCountInString(cleaned) <= maxRunes {
		return cleaned
	}
	runes := []rune(cleaned)
	return string(runes[:maxRunes])
}

// KnownFailureReason reports whether reason is in the closed taxonomy.
func KnownFailureReason(reason string) bool {
	_, ok := knownReasons[reason]
	return ok
}
