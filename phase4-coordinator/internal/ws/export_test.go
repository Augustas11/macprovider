package ws

import "net/http"

// RemoteIPForUnauthSemaphoreExport exposes remoteIPForUnauthSemaphore for
// external _test packages. M1-4 follow-up regression coverage.
func RemoteIPForUnauthSemaphoreExport(remoteAddr string, header http.Header) string {
	return remoteIPForUnauthSemaphore(remoteAddr, header)
}

// WithBeforeHandshakeAckSendForTest runs fn just before the handshake ack is
// enqueued, so ordering tests can widen the ack-build window.
func WithBeforeHandshakeAckSendForTest(fn func()) Option {
	return func(s *Server) { s.beforeHandshakeAckSend = fn }
}
