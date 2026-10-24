package ws

import "errors"

// SPEC-001-R012: the largest coordinator-to-provider text message a provider
// session accepts. A provider WebSocket client tears down the whole session on
// one over-limit message (Foundation's URLSessionWebSocketTask fails the task
// and closes with 1009), so the coordinator never writes one: it refuses the
// frame and keeps the session.
const (
	// LegacyProviderWSMaxMessageBytes is the limit of a provider that does not
	// advertise tier2_capabilities.ws_max_message_bytes: Foundation's default
	// URLSessionWebSocketTask.maximumMessageSize.
	LegacyProviderWSMaxMessageBytes int64 = 1 << 20
	// MaxProviderWSMaxMessageBytes caps an advertised limit. It equals the
	// largest ws.max_frame_bytes the coordinator accepts for the other
	// direction and covers the worst-case encoding of a maximum-size request
	// body (SPEC-001-R012).
	MaxProviderWSMaxMessageBytes int64 = 64 << 20
)

// ErrProviderFrameTooLarge reports a coordinator-to-provider frame larger than
// the session's advertised message limit. Nothing was written and the session
// is still open.
var ErrProviderFrameTooLarge = errors.New("frame exceeds the provider websocket message size limit")

// providerInboundMessageLimit normalizes an advertised limit: absent, invalid or
// below the legacy default means the legacy default; above the cap means the cap.
func providerInboundMessageLimit(advertised int64) int64 {
	switch {
	case advertised < LegacyProviderWSMaxMessageBytes:
		return LegacyProviderWSMaxMessageBytes
	case advertised > MaxProviderWSMaxMessageBytes:
		return MaxProviderWSMaxMessageBytes
	default:
		return advertised
	}
}
