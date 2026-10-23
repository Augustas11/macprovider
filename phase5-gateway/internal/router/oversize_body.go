package router

import (
	"errors"
	"io"
	"net/http"
	"time"
)

const (
	// oversizeBodyDrainMaxBytes bounds the total request-body bytes the gateway
	// reads before rejecting an oversized body. It matches the api.malibu.tech
	// nginx `client_max_body_size 8M`, so nothing longer arrives through it.
	oversizeBodyDrainMaxBytes int64 = 8 << 20
	// oversizeBodyDrainTimeout bounds how long a slow client can hold the drain
	// when the ResponseWriter supports per-request read deadlines.
	oversizeBodyDrainTimeout = 5 * time.Second
)

// drainOversizeRequestBody reads and discards what is left of a request body
// the handler is about to reject as oversized. Call it only on that reject
// path, before writing the response. If the gateway answers while body bytes
// are still unread, net/http closes the connection and the kernel resets it;
// nginx streams /v1/ bodies upstream (proxy_request_buffering off), sees the
// reset mid-write and answers 502 instead of relaying the 413 (#2107).
// alreadyRead is how many body bytes the caller consumed.
func drainOversizeRequestBody(w http.ResponseWriter, body io.Reader, alreadyRead int64) {
	remaining := oversizeBodyDrainMaxBytes - max(alreadyRead, 0)
	if body == nil || remaining <= 0 {
		return
	}
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(oversizeBodyDrainTimeout))
	n, err := io.Copy(io.Discard, io.LimitReader(body, remaining))
	if err == nil && n < remaining {
		// The body reached EOF, so net/http's background connection read owns
		// the connection now. Clear the drain deadline so it can never cancel
		// the request context while the handler finishes.
		_ = rc.SetReadDeadline(time.Time{})
	}
}

// drainIfMaxBytesExceeded drains the raw request body only when err reports
// that an http.MaxBytesReader limit was hit.
func drainIfMaxBytesExceeded(w http.ResponseWriter, r *http.Request, err error, alreadyRead int64) {
	var maxErr *http.MaxBytesError
	if errors.As(err, &maxErr) {
		drainOversizeRequestBody(w, r.Body, alreadyRead)
	}
}
