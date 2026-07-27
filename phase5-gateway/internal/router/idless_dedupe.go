package router

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Id-less retry dedupe (issue #762 / seam finding P1-1).
//
// OpenRouter — and most SDK retry loops — re-send a failed or slow request
// WITHOUT an X-Request-ID. The gateway middleware mints a fresh id per
// attempt, so the durable (account_id, request_id) primary key on
// quota_reservations never matches and every attempt reserves + settles
// independently: one buyer intent, N bills.
//
// This index gives an identical, id-less re-send a chance to REPLAY attempt
// 1's buyer-visible response instead of re-dispatching inference, and to
// COALESCE onto attempt 1 while it is still in flight.
//
// It is deliberately NOT the money invariant. The durable reservation key
// still is: a retry that finds no usable cache entry adopts attempt 1's
// request_id and falls through to the existing duplicate_request_id 409.
// Every miss path (process restart, LRU eviction, oversize body, poisoned
// stream) therefore degrades to a 409, never to a second bill.
//
// Sizing mirrors requestRateLimiter (request_rate_limiter.go): a bounded map
// with a periodic prune and LRU eviction, so a hostile buyer cannot grow the
// gateway's heap by varying request bodies.
const (
	// idlessDedupeFingerprintVersion is mixed into every fingerprint so a
	// future change to the keying inputs can never collide with entries
	// computed by an older build.
	idlessDedupeFingerprintVersion = "mpg-idless-v1"

	idlessDedupeMaxEntries    = 4096
	idlessDedupeMaxEntryBytes = 1 << 20  // 1 MiB per cached response body
	idlessDedupeMaxTotalBytes = 32 << 20 // 32 MiB of cached bodies overall
	idlessDedupePruneInterval = time.Minute
	// idlessDedupeMaxWaiters bounds how many concurrent identical attempts
	// may park on one in-flight request. Waiters hold no quota reservation
	// and no concurrency lease, but they do hold a server goroutine.
	idlessDedupeMaxWaiters = 4

	// idlessDedupeHeader marks a replayed response so buyers (and the
	// harness) can tell a cache replay from a fresh generation.
	idlessDedupeHeader      = "X-MacProvider-Dedupe"
	idlessDedupeHeaderValue = "replay"
)

// idlessRequestFingerprint keys the dedupe index.
//
// The body is hashed as RAW BYTES, not canonicalized JSON: byte-identity is
// upstream-identity, and any normalization would widen the false-positive
// surface (two different requests collapsing onto one answer) in exchange for
// catching retries that no real client emits. The coordinator's request
// hashing takes the same position.
//
// Everything that changes the generated answer is either in those bytes
// (model, messages, stream, max_tokens, response_format) or in the explicit
// key parts below (tenant, demo token, sticky conversation). Transport-level
// headers — Authorization, IP, User-Agent, Accept*, the id headers — are
// deliberately excluded: they vary across a legitimate retry.
func idlessRequestFingerprint(accountID, demoTokenHash, conversationTag string, body []byte) string {
	bodyDigest := sha256.Sum256(body)
	h := sha256.New()
	for _, part := range []string{idlessDedupeFingerprintVersion, accountID, demoTokenHash, conversationTag} {
		h.Write([]byte(part))
		h.Write([]byte{0})
	}
	h.Write(bodyDigest[:])
	return hex.EncodeToString(h.Sum(nil))
}

// idlessDedupeEntry is one fingerprint's slot. It is created by the request
// that WON the claim and is only ever published or dropped by that request
// (ownership is checked on requestID) — see publish/drop.
type idlessDedupeEntry struct {
	// requestID is attempt 1's gateway-minted id. Adopting it is what makes
	// the durable reservation key the real duplicate detector.
	requestID string
	// done is closed exactly once, when the owner reaches a terminal state
	// (published or dropped). Waiters park on it.
	done   chan struct{}
	closed bool

	completed   bool
	status      int
	contentType string
	providerID  string
	// body is the captured buyer-visible response. nil means "replay
	// unavailable" — never cached, or the body was evicted under memory
	// pressure while the fingerprint→requestID mapping was kept.
	body []byte

	terminalAt time.Time
	lastSeen   time.Time
	waiters    int
}

func (e *idlessDedupeEntry) closeLocked() {
	if !e.closed {
		e.closed = true
		close(e.done)
	}
}

// idlessDedupeReplay is an immutable snapshot of a replayable entry, taken
// under the index lock so the writer never touches shared state.
type idlessDedupeReplay struct {
	requestID   string
	status      int
	contentType string
	providerID  string
	body        []byte
}

type idlessDedupeIndex struct {
	mu         sync.Mutex
	entries    map[string]*idlessDedupeEntry
	totalBytes int
	lastPruned time.Time

	replayTotal       atomic.Int64
	inflightWaitTotal atomic.Int64
	conflictTotal     atomic.Int64
	uncacheableTotal  atomic.Int64
}

func newIdlessDedupeIndex() *idlessDedupeIndex {
	return &idlessDedupeIndex{entries: make(map[string]*idlessDedupeEntry)}
}

// claim registers requestID as the owner of fp, or reports that an earlier
// attempt already owns it. adopted=true means the caller must NOT publish or
// drop the entry; it either replays or falls through to the durable 409.
func (x *idlessDedupeIndex) claim(fp, requestID string, now time.Time, window time.Duration) (*idlessDedupeEntry, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if entry := x.entries[fp]; entry != nil {
		// The window is measured from attempt 1's TERMINAL, not its start:
		// a 900s generation must still dedupe a retry sent right after it
		// finishes. In-flight entries never expire — they are bounded by
		// the owning request's own ceiling.
		if entry.completed && now.Sub(entry.terminalAt) > window {
			x.removeLocked(fp, entry)
		} else {
			entry.lastSeen = now
			return entry, true
		}
	}
	x.pruneForInsertLocked(now, window)
	entry := &idlessDedupeEntry{requestID: requestID, done: make(chan struct{}), lastSeen: now}
	x.entries[fp] = entry
	return entry, false
}

// publish records the owner's buyer-visible 2xx response. A no-op unless
// requestID still owns fp (the entry may have been evicted, or replaced by a
// later attempt after eviction).
func (x *idlessDedupeIndex) publish(fp, requestID string, status int, contentType, providerID string, body []byte, now time.Time) {
	x.mu.Lock()
	defer x.mu.Unlock()
	entry := x.entries[fp]
	if entry == nil || entry.requestID != requestID || entry.completed {
		return
	}
	entry.status = status
	entry.contentType = contentType
	entry.providerID = providerID
	if len(body) > 0 && len(body) <= idlessDedupeMaxEntryBytes {
		entry.body = body
		x.totalBytes += len(body)
	}
	entry.completed = true
	entry.terminalAt = now
	entry.lastSeen = now
	entry.closeLocked()
	x.evictBodiesLocked()
}

// drop retires an entry whose owner did NOT produce a replayable response
// (non-2xx, truncated stream, buyer disconnect, oversize body). Parked
// waiters are woken and fall through to the durable 409; later attempts find
// no entry at all and re-dispatch normally.
func (x *idlessDedupeIndex) drop(fp, requestID string) {
	x.mu.Lock()
	defer x.mu.Unlock()
	entry := x.entries[fp]
	if entry == nil || entry.requestID != requestID {
		return
	}
	x.removeLocked(fp, entry)
	x.uncacheableTotal.Add(1)
}

// awaitTerminal parks until the owner reaches a terminal state. It reports
// false when the waiter cap is already reached or ctx expires first, which
// sends the caller to the durable 409 rather than to a second dispatch.
func (x *idlessDedupeIndex) awaitTerminal(ctx context.Context, entry *idlessDedupeEntry) bool {
	x.mu.Lock()
	if entry.closed {
		x.mu.Unlock()
		return true
	}
	if entry.waiters >= idlessDedupeMaxWaiters {
		x.mu.Unlock()
		return false
	}
	entry.waiters++
	x.mu.Unlock()
	x.inflightWaitTotal.Add(1)
	defer func() {
		x.mu.Lock()
		entry.waiters--
		x.mu.Unlock()
	}()
	select {
	case <-entry.done:
		return true
	case <-ctx.Done():
		return false
	}
}

// replaySnapshot returns a replayable copy of entry, or ok=false when the
// entry never completed, was dropped, lost its body to eviction, or fell
// outside the window between the claim and now.
func (x *idlessDedupeIndex) replaySnapshot(entry *idlessDedupeEntry, now time.Time, window time.Duration) (idlessDedupeReplay, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if !entry.completed || entry.body == nil {
		return idlessDedupeReplay{}, false
	}
	if now.Sub(entry.terminalAt) > window {
		return idlessDedupeReplay{}, false
	}
	entry.lastSeen = now
	return idlessDedupeReplay{
		requestID:   entry.requestID,
		status:      entry.status,
		contentType: entry.contentType,
		providerID:  entry.providerID,
		body:        entry.body,
	}, true
}

func (x *idlessDedupeIndex) removeLocked(fp string, entry *idlessDedupeEntry) {
	delete(x.entries, fp)
	if entry.body != nil {
		x.totalBytes -= len(entry.body)
		entry.body = nil
	}
	entry.closeLocked()
}

func (x *idlessDedupeIndex) pruneForInsertLocked(now time.Time, window time.Duration) {
	if len(x.entries) < idlessDedupeMaxEntries {
		if !x.lastPruned.IsZero() && now.Sub(x.lastPruned) < idlessDedupePruneInterval {
			return
		}
		x.pruneExpiredLocked(now, window)
		return
	}
	x.pruneExpiredLocked(now, window)
	for len(x.entries) >= idlessDedupeMaxEntries {
		if !x.evictOldestLocked() {
			// Everything left is in flight: an owner is still running and
			// waiters may be parked on it, so evicting would strand them.
			// The map can only exceed the cap by the number of concurrent
			// in-flight requests, which the concurrency limiter bounds.
			return
		}
	}
}

func (x *idlessDedupeIndex) pruneExpiredLocked(now time.Time, window time.Duration) {
	x.lastPruned = now
	for fp, entry := range x.entries {
		if entry.completed && now.Sub(entry.terminalAt) > window {
			x.removeLocked(fp, entry)
		}
	}
}

// evictOldestLocked drops the least recently seen COMPLETED entry. In-flight
// entries are never evicted (see pruneForInsertLocked).
func (x *idlessDedupeIndex) evictOldestLocked() bool {
	var oldestFP string
	var oldest *idlessDedupeEntry
	for fp, entry := range x.entries {
		if !entry.completed {
			continue
		}
		if oldest == nil || entry.lastSeen.Before(oldest.lastSeen) {
			oldestFP, oldest = fp, entry
		}
	}
	if oldest == nil {
		return false
	}
	x.removeLocked(oldestFP, oldest)
	return true
}

// evictBodiesLocked enforces the total-bytes cap by dropping cached BODIES,
// least recently seen first. The fingerprint→requestID mapping survives, so a
// retry inside the window still adopts attempt 1's id and still gets the
// durable 409 instead of a second bill — losing the replay costs UX, not
// money.
func (x *idlessDedupeIndex) evictBodiesLocked() {
	for x.totalBytes > idlessDedupeMaxTotalBytes {
		var oldest *idlessDedupeEntry
		for _, entry := range x.entries {
			if entry.body == nil {
				continue
			}
			if oldest == nil || entry.lastSeen.Before(oldest.lastSeen) {
				oldest = entry
			}
		}
		if oldest == nil {
			return
		}
		x.totalBytes -= len(oldest.body)
		oldest.body = nil
	}
}

// idlessDedupeWindow is the operator-facing kill switch and blast radius for
// the whole feature: 0 disables id-less dedupe entirely and restores the
// pre-#762 behavior (every id-less retry bills again).
func (s *Server) idlessDedupeWindow() time.Duration {
	return time.Duration(s.cfg.Quotas.IdlessDedupeWindowSeconds) * time.Second
}

// replayIdlessDuplicate serves an adopted retry from attempt 1's cached
// response. It reports false when no replay is possible — in-flight wait cap
// or expiry, dropped entry, evicted body — leaving the caller to fall through
// to ReserveQuota, which returns ErrReservationExists for the adopted id and
// yields the existing duplicate_request_id 409.
//
// Nothing on this path reserves, settles, or holds: a replay is invisible to
// the settlement reconciler by construction, because attempt 1 already booked
// the one and only charge.
func (s *Server) replayIdlessDuplicate(w http.ResponseWriter, r *http.Request, subject usageSubject, dailyQuota int64, entry *idlessDedupeEntry, window time.Duration, deadlines *requestDeadlines) bool {
	if !s.idlessDedupe.awaitTerminal(deadlines.Context(), entry) {
		s.idlessDedupe.conflictTotal.Add(1)
		return false
	}
	snapshot, ok := s.idlessDedupe.replaySnapshot(entry, s.now(), window)
	if !ok {
		s.idlessDedupe.conflictTotal.Add(1)
		return false
	}
	header := w.Header()
	// Header whitelist. Only what identifies the response is replayed;
	// per-attempt settlement telemetry and retry hints are NEVER echoed,
	// because they describe attempt 1's billing transaction, not this one.
	for name := range header {
		if strings.HasPrefix(strings.ToLower(name), "x-macprovider-settlement-") {
			header.Del(name)
		}
	}
	header.Del("Retry-After")
	if snapshot.contentType != "" {
		header.Set("Content-Type", snapshot.contentType)
	}
	if snapshot.providerID != "" {
		header.Set("X-Provider-Id", snapshot.providerID)
	}
	header.Set("X-Request-ID", snapshot.requestID)
	header.Set(idlessDedupeHeader, idlessDedupeHeaderValue)
	// Rate-limit headers are recomputed, never replayed: the buyer's quota
	// moved on between attempt 1 and this retry.
	usageWindow := s.now().UTC().Format("2006-01-02")
	if used, reserved, err := s.readStore().DailyUsage(r.Context(), subject.AccountID, usageWindow); err == nil {
		remaining := dailyQuota - used - reserved
		if remaining < 0 {
			remaining = 0
		}
		setRateLimitHeaders(w, dailyQuota, remaining, resetUnix(usageWindow))
	}
	w.WriteHeader(snapshot.status)
	if _, err := w.Write(snapshot.body); err != nil {
		return true
	}
	if flusher, ok := w.(http.Flusher); ok && strings.HasPrefix(snapshot.contentType, "text/event-stream") {
		flusher.Flush()
	}
	s.idlessDedupe.replayTotal.Add(1)
	return true
}

func (x *idlessDedupeIndex) prometheus() string {
	var b strings.Builder
	b.WriteString("# HELP gateway_idless_dedupe_replay_total Id-less retries served from attempt 1's cached response.\n")
	b.WriteString("# TYPE gateway_idless_dedupe_replay_total counter\n")
	fmt.Fprintf(&b, "gateway_idless_dedupe_replay_total %d\n", x.replayTotal.Load())
	b.WriteString("# HELP gateway_idless_dedupe_inflight_wait_total Id-less retries that parked on an in-flight identical attempt.\n")
	b.WriteString("# TYPE gateway_idless_dedupe_inflight_wait_total counter\n")
	fmt.Fprintf(&b, "gateway_idless_dedupe_inflight_wait_total %d\n", x.inflightWaitTotal.Load())
	b.WriteString("# HELP gateway_idless_dedupe_conflict_total Id-less retries that adopted attempt 1's request id and fell through to the durable duplicate_request_id 409.\n")
	b.WriteString("# TYPE gateway_idless_dedupe_conflict_total counter\n")
	fmt.Fprintf(&b, "gateway_idless_dedupe_conflict_total %d\n", x.conflictTotal.Load())
	b.WriteString("# HELP gateway_idless_dedupe_uncacheable_total Attempts whose terminal response was not replayable (non-2xx, truncated stream, buyer disconnect, oversize body).\n")
	b.WriteString("# TYPE gateway_idless_dedupe_uncacheable_total counter\n")
	fmt.Fprintf(&b, "gateway_idless_dedupe_uncacheable_total %d\n", x.uncacheableTotal.Load())
	return b.String()
}
