// Package providerevents implements the Partial #535 durable provider
// connection-event journal and last-known offline snapshot store.
package providerevents

import (
	"net/url"
	"regexp"
	"strings"
	"time"
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

// AnonymousProviderID is the capped journal bucket for pre-identity failures
// (upgrade failures, pool pressure before a provider_id is known).
const AnonymousProviderID = "_anonymous"

const (
	DefaultMaxDiagnostic  = 256
	DefaultEventsQueryCap = 100
	DefaultPerProviderCap = 2000
	DefaultAnonymousCap   = 5000
	DefaultGlobalCap      = 100000
	DefaultLastKnownCap   = 20000
	DefaultListPageCap    = 200
	DefaultRetention      = 14 * 24 * time.Hour
	FixedUTCLayout        = "2006-01-02T15:04:05.000000000Z"
)

var (
	urlLike  = regexp.MustCompile(`(?i)\b[a-z][a-z0-9+.-]*://[^\s]+`)
	pathLike = regexp.MustCompile(`(^|[\s=])/(Users|Volumes|private|var|tmp|etc|opt)/[^\s,;]+`)
	// secretLike strips credential-shaped substrings. Hyphen/underscore
	// continuations after mpk_ are included so fragments cannot survive.
	secretLike = regexp.MustCompile(`(?i)(bearer\s+\S+|mpk_[a-z0-9_\-]+|token\s*[:=]\s*\S+|"token"\s*:\s*"[^"]+"|provider_token\s*[:=]\s*\S+)`)
	// authorizationLike consumes the remainder of the header/value so
	// "Authorization: Bearer opaque" cannot leave the opaque token behind.
	authorizationLike = regexp.MustCompile(`(?i)"?authorization"?\s*[:=]\s*[^\r\n]+`)
	hex64Token        = regexp.MustCompile(`(?i)\b[a-f0-9]{64}\b`)
	knownReasons      = map[string]struct{}{
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
	knownKinds = map[string]struct{}{
		KindUpgradeFailed:  {},
		KindAuthRejected:   {},
		KindAuthAccepted:   {},
		KindDisconnect:     {},
		KindWarmupFailed:   {},
		KindHeartbeatStale: {},
	}
	knownOutcomes = map[string]struct{}{
		OutcomeSuccess: {},
		OutcomeFailure: {},
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
	case strings.Contains(r, "too_many_unauthenticated") || strings.Contains(r, "too_many_auth_attempts") ||
		strings.Contains(r, "pool_full") || strings.Contains(r, "provisional_pool") ||
		strings.Contains(r, "credential_bootstrap_outstanding_full") || strings.Contains(r, "outstanding_full"):
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
	cleaned := urlLike.ReplaceAllStringFunc(raw, func(value string) string {
		parsed, err := url.Parse(value)
		if err != nil || parsed.Scheme == "" || parsed.Host == "" {
			return "[redacted_url]"
		}
		return parsed.Scheme + "://" + parsed.Host
	})
	cleaned = pathLike.ReplaceAllString(cleaned, "$1[redacted_path]")
	cleaned = authorizationLike.ReplaceAllString(cleaned, "[redacted]")
	cleaned = secretLike.ReplaceAllString(cleaned, "[redacted]")
	cleaned = hex64Token.ReplaceAllString(cleaned, "[redacted]")
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

// LooksLikeCredential reports whether s resembles a bearer/token secret and
// must not be persisted as an identifier.
func LooksLikeCredential(s string) bool {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return false
	}
	lower := strings.ToLower(trimmed)
	if strings.HasPrefix(lower, "mpk_") || strings.HasPrefix(lower, "bearer ") {
		return true
	}
	if len(trimmed) == 64 && hex64Token.MatchString(trimmed) {
		return true
	}
	return secretLike.MatchString(trimmed)
}

// KnownFailureReason reports whether reason is in the closed taxonomy.
func KnownFailureReason(reason string) bool {
	_, ok := knownReasons[reason]
	return ok
}

// KnownKind reports whether kind is in the closed taxonomy.
func KnownKind(kind string) bool {
	_, ok := knownKinds[kind]
	return ok
}

// KnownOutcome reports whether outcome is in the closed taxonomy.
func KnownOutcome(outcome string) bool {
	_, ok := knownOutcomes[outcome]
	return ok
}

// FormatFixedUTC returns a fixed-width UTC timestamp for lexical ordering.
func FormatFixedUTC(t time.Time) string {
	return t.UTC().Format(FixedUTCLayout)
}
