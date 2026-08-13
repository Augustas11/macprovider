// Package journal implements the durable, append-only settlement journal
// behind issue #763 (seam finding P1-2, "settlement not crash-durable").
//
// # WHY A SEPARATE FILE AND NOT A TABLE IN gateway.db
//
// The failure this closes is "the buyer received a committed 200 stream and
// nobody was billed": SettleReservation failed AND the SPEC-006 § 17.7
// EnsureUsageEvent fallback failed, so chat_proxy.settleAfterCommit refunded
// and dropped the audit row. Writing the recovery record into the SAME sqlite
// file that just failed would produce a green test and an unchanged risk —
// every failure class that takes out the settle write (single write
// connection contention, a DB-file pathology, a torn WAL after power loss)
// takes out the journal write with it. A second sqlite file is only
// marginally better: same driver, same page cache, same failure modes.
//
// So the journal is a plain append-only JSONL file with an fsync per EFFECT
// record. That is the only mechanism that survives the whole class: the
// effect is on stable storage before the settle attempt begins, so the
// recovery scan can re-drive it after a logical failure, a process crash, or
// a power loss.
//
// # RECORD MODEL
//
// Three kinds, all keyed by (account_id, request_id, effect):
//
//   - "effect"     — an after-commit money effect is ABOUT to be attempted.
//     Carries the complete billing payload, which must be
//     sufficient to rebuild storage.ReservationSettlement and
//     storage.UsageEvent byte-identically so a re-drive passes
//     EnsureUsageEvent's payload verify (created_at excluded).
//   - "seal"       — the effect reached a terminal, durable outcome
//     ("settled" via the reservation, or "usage_event" via the
//     § 17.7 fallback). A sealed key is never re-driven.
//   - "quarantine" — the re-drive hit an unresolvable conflict
//     (storage.ErrUsageEventConflict) repeatedly. Suppresses
//     further re-drive and pins the segment against pruning so an
//     operator can reconcile from the coordinator request_log.
//
// The journal NEVER contains prompt or response text. It holds account_id,
// request_id, token counts, window date, token source, outcome, and (for
// demo traffic) the demo identity and demo token hash — the same fields the
// gateway already persists in usage_events. Directory 0700, files 0600.
//
// DURABILITY CONTRACT
//
//   - WriteEffect performs a SINGLE write(2) of one line and then fsyncs
//     BEFORE returning. Losing an effect record loses the ability to
//     recover the bill, so it is the one record that must be on stable
//     storage synchronously.
//   - WriteSeal does NOT fsync. A lost seal costs one idempotent re-drive
//     (EnsureUsageEvent matches the existing row and returns nil), never a
//     double bill.
//   - Segment create and unlink fsync the parent directory, so a segment
//     that exists after a crash is visible in the directory entry too.
package journal

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// RecordVersion is stamped into every record. Readers refuse versions they
// do not understand rather than guessing at a payload shape.
const RecordVersion = 1

// Record kinds.
const (
	KindEffect     = "effect"
	KindSeal       = "seal"
	KindQuarantine = "quarantine"
)

// EffectSettle is the only effect kind v1 journals: the after-commit
// settlement performed by chat_proxy.settleAfterCommit. The field is part of
// the record key so a later effect (e.g. the SPEC-022 hold marker) can be
// added without rewriting existing journals.
const EffectSettle = "settle"

// Seal results.
const (
	SealSettled    = "settled"
	SealUsageEvent = "usage_event"
)

// Filesystem contract.
const (
	segmentPrefix = "effects-"
	segmentSuffix = ".jsonl"
	dirMode       = os.FileMode(0o700)
	fileMode      = os.FileMode(0o600)

	// DefaultSegmentMaxBytes bounds one segment file. Small enough that a
	// scan reads it into memory without thought, large enough that rotation
	// is rare on the money path.
	DefaultSegmentMaxBytes int64 = 16 << 20
	// DefaultMaxTotalBytes is the HARD cap across all segments. Past it the
	// journal refuses new records (see ErrFull) instead of filling the disk
	// out from under sqlite. That is a deliberate lesser-harm choice: a
	// refused journal write is fail-open (settlement still runs, the metric
	// and the CRITICAL log fire), whereas a full disk takes the gateway's
	// database with it.
	DefaultMaxTotalBytes int64 = 512 << 20
)

// Sentinel errors.
var (
	// ErrFull is returned once the journal has reached its hard size cap.
	ErrFull = fmt.Errorf("settlement journal is full")
	// ErrClosed is returned by writes issued after Close.
	ErrClosed = fmt.Errorf("settlement journal is closed")
)

// Key identifies one money effect. Every record carries it; seals and
// quarantines refer back to the effect they resolve.
type Key struct {
	AccountID string
	RequestID string
	Effect    string
}

// Record is one JSONL line.
//
// Field-shape rule: everything needed to rebuild storage.ReservationSettlement
// AND storage.UsageEvent must be here, because the recovery ladder writes
// both. created_at is deliberately NOT journaled — EnsureUsageEvent excludes
// it from the payload verify, and re-deriving it at re-drive time keeps the
// record free of a value that would otherwise look authoritative.
type Record struct {
	Version         int    `json:"v"`
	Kind            string `json:"kind"`
	AccountID       string `json:"account_id"`
	RequestID       string `json:"request_id"`
	Effect          string `json:"effect"`
	WrittenAtUnixMS int64  `json:"written_at_unix_ms"`

	// Effect payload (kind == KindEffect).
	WindowDate       string `json:"window_date,omitempty"`
	PromptTokens     int64  `json:"prompt_tokens,omitempty"`
	CompletionTokens int64  `json:"completion_tokens,omitempty"`
	TotalTokens      int64  `json:"total_tokens,omitempty"`
	MaxTotalTokens   int64  `json:"max_total_tokens,omitempty"`
	TokenSource      string `json:"token_source,omitempty"`
	Outcome          string `json:"outcome,omitempty"`
	DemoIdentity     string `json:"demo_identity,omitempty"`
	DemoTokenHash    string `json:"demo_token_hash,omitempty"`
	WalletSessionID  string `json:"wallet_session_id,omitempty"`

	// Seal payload (kind == KindSeal): SealSettled or SealUsageEvent.
	Result string `json:"result,omitempty"`

	// Quarantine payload (kind == KindQuarantine).
	Reason   string `json:"reason,omitempty"`
	Attempts int    `json:"attempts,omitempty"`
}

// Key returns the record's (account, request, effect) identity.
func (r Record) Key() Key {
	return Key{AccountID: r.AccountID, RequestID: r.RequestID, Effect: r.Effect}
}

// WrittenAt is the record's write time in UTC.
func (r Record) WrittenAt() time.Time {
	return time.UnixMilli(r.WrittenAtUnixMS).UTC()
}

// TokensConsistent reports whether the journaled totals agree. A record that
// fails this can never settle (the store rejects total != prompt+completion),
// so the recovery ladder quarantines it instead of retrying forever.
func (r Record) TokensConsistent() bool {
	if r.PromptTokens < 0 || r.CompletionTokens < 0 || r.TotalTokens < 0 {
		return false
	}
	return r.TotalTokens == r.PromptTokens+r.CompletionTokens
}

// Options configures Open.
type Options struct {
	// Dir is the journal directory. Created 0700 if missing.
	Dir string
	// Fsync enables the per-effect fsync. It defaults to ON via config;
	// the escape hatch exists only for throwaway environments and is
	// rejected by config.Validate in the production posture.
	Fsync bool
	// SegmentMaxBytes bounds one segment file (0 → DefaultSegmentMaxBytes).
	SegmentMaxBytes int64
	// MaxTotalBytes is the hard cap across all segments
	// (0 → DefaultMaxTotalBytes).
	MaxTotalBytes int64
	// Now overrides the clock (tests).
	Now func() time.Time
}

// fileHandle is the narrow view of a segment file the journal writes
// through. It exists so TestSettlementJournal_EffectWriteFsyncs can wrap the
// REAL file and observe that WriteEffect issued Sync before returning —
// without that seam, "we fsync effects" is an unverifiable claim, and it is
// the single property this whole package exists to provide.
type fileHandle interface {
	Write(p []byte) (int, error)
	Sync() error
	Close() error
}

// Journal is a single-writer append-only settlement journal. All methods are
// safe for concurrent use.
type Journal struct {
	dir             string
	fsync           bool
	segmentMaxBytes int64
	maxTotalBytes   int64
	now             func() time.Time

	mu           sync.Mutex
	file         fileHandle
	segmentName  string
	segmentBytes int64
	totalBytes   int64
	closed       bool

	// wrapFile decorates a freshly opened segment file. Identity in
	// production; tests substitute a recorder.
	wrapFile func(fileHandle) fileHandle

	metrics metrics
}

// Open prepares the journal directory and returns a ready journal. It does
// NOT create a segment: segments appear on the first write, so a gateway that
// never bills never litters the directory.
//
// Open fails closed. cmd/gateway exits on error rather than serving with
// settlement durability silently disabled.
func Open(opts Options) (*Journal, error) {
	dir := strings.TrimSpace(opts.Dir)
	if dir == "" {
		return nil, fmt.Errorf("settlement journal: dir must be set")
	}
	if err := os.MkdirAll(dir, dirMode); err != nil {
		return nil, fmt.Errorf("settlement journal: create dir %s: %w", dir, err)
	}
	// An inherited directory may be group/world readable; the journal holds
	// account ids and token counts, so tighten it every boot.
	if err := os.Chmod(dir, dirMode); err != nil {
		return nil, fmt.Errorf("settlement journal: chmod dir %s: %w", dir, err)
	}
	probe, err := os.CreateTemp(dir, ".writable-*")
	if err != nil {
		return nil, fmt.Errorf("settlement journal: dir %s is not writable: %w", dir, err)
	}
	probeName := probe.Name()
	_ = probe.Close()
	_ = os.Remove(probeName)

	j := &Journal{
		dir:             dir,
		fsync:           opts.Fsync,
		segmentMaxBytes: opts.SegmentMaxBytes,
		maxTotalBytes:   opts.MaxTotalBytes,
		now:             opts.Now,
		wrapFile:        func(f fileHandle) fileHandle { return f },
	}
	if j.segmentMaxBytes <= 0 {
		j.segmentMaxBytes = DefaultSegmentMaxBytes
	}
	if j.maxTotalBytes <= 0 {
		j.maxTotalBytes = DefaultMaxTotalBytes
	}
	if j.now == nil {
		j.now = func() time.Time { return time.Now().UTC() }
	}
	j.metrics.init()
	bytes, err := dirBytes(dir)
	if err != nil {
		return nil, err
	}
	j.totalBytes = bytes
	j.metrics.setBytes(bytes)
	return j, nil
}

// Dir returns the journal directory.
func (j *Journal) Dir() string { return j.dir }

// WriteEffect durably records an effect that is about to be attempted: one
// write(2), then fsync, before returning.
func (j *Journal) WriteEffect(rec Record) error {
	rec.Kind = KindEffect
	if rec.Effect == "" {
		rec.Effect = EffectSettle
	}
	if err := j.append(rec, j.fsync); err != nil {
		return err
	}
	j.metrics.incEffects()
	return nil
}

// WriteSeal records that an effect reached a durable terminal. Deliberately
// NOT fsynced: a lost seal costs one idempotent re-drive, never a bill.
func (j *Journal) WriteSeal(key Key, result string) error {
	if err := j.append(Record{
		Kind:      KindSeal,
		AccountID: key.AccountID,
		RequestID: key.RequestID,
		Effect:    key.Effect,
		Result:    result,
	}, false); err != nil {
		return err
	}
	j.metrics.incSeals()
	return nil
}

// WriteQuarantine records that an effect cannot be re-driven. Like a seal it
// suppresses further re-drive, but unlike a seal it pins its segment against
// pruning and raises a gauge, because the money outcome is UNRESOLVED and an
// operator has to reconcile it from the coordinator request_log.
func (j *Journal) WriteQuarantine(key Key, reason string, attempts int) error {
	if err := j.append(Record{
		Kind:      KindQuarantine,
		AccountID: key.AccountID,
		RequestID: key.RequestID,
		Effect:    key.Effect,
		Reason:    reason,
		Attempts:  attempts,
	}, j.fsync); err != nil {
		return err
	}
	j.metrics.incQuarantines()
	return nil
}

func (j *Journal) append(rec Record, sync bool) error {
	rec.Version = RecordVersion
	if rec.WrittenAtUnixMS == 0 {
		rec.WrittenAtUnixMS = j.now().UTC().UnixMilli()
	}
	line, err := json.Marshal(rec)
	if err != nil {
		j.metrics.incWriteFailures()
		return fmt.Errorf("settlement journal: marshal record: %w", err)
	}
	line = append(line, '\n')

	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		j.metrics.incWriteFailures()
		return ErrClosed
	}
	if j.totalBytes+int64(len(line)) > j.maxTotalBytes {
		j.metrics.incWriteFailures()
		// CRITICAL, not Warn: durability is off until an operator drains the
		// directory. Refusing the write is the lesser harm — see
		// DefaultMaxTotalBytes.
		slog.Error("CRITICAL gateway settlement journal is full; refusing new records",
			"dir", j.dir,
			"total_bytes", j.totalBytes,
			"max_total_bytes", j.maxTotalBytes,
			"account_id", rec.AccountID,
			"request_id", rec.RequestID,
			"kind", rec.Kind,
		)
		return ErrFull
	}
	if err := j.ensureSegmentLocked(int64(len(line))); err != nil {
		j.metrics.incWriteFailures()
		return err
	}
	n, err := j.file.Write(line)
	j.segmentBytes += int64(n)
	j.totalBytes += int64(n)
	j.metrics.setBytes(j.totalBytes)
	if err != nil {
		j.metrics.incWriteFailures()
		return fmt.Errorf("settlement journal: write record: %w", err)
	}
	if sync {
		if err := j.file.Sync(); err != nil {
			j.metrics.incWriteFailures()
			return fmt.Errorf("settlement journal: fsync record: %w", err)
		}
	}
	return nil
}

func (j *Journal) ensureSegmentLocked(need int64) error {
	if j.file != nil && j.segmentBytes+need <= j.segmentMaxBytes {
		return nil
	}
	if j.file != nil {
		if err := j.file.Close(); err != nil {
			return fmt.Errorf("settlement journal: close segment %s: %w", j.segmentName, err)
		}
		j.file = nil
	}
	name := segmentName(j.now(), os.Getpid())
	path := filepath.Join(j.dir, name)
	// O_EXCL: two segments minted inside the same millisecond by the same
	// pid would otherwise silently share a file.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY|os.O_APPEND, fileMode)
	if err != nil {
		if !os.IsExist(err) {
			return fmt.Errorf("settlement journal: create segment %s: %w", path, err)
		}
		f, err = os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, fileMode)
		if err != nil {
			return fmt.Errorf("settlement journal: open segment %s: %w", path, err)
		}
	}
	// A segment that exists but whose directory entry is not durable is a
	// segment a crash can lose whole.
	if err := fsyncDir(j.dir); err != nil {
		_ = f.Close()
		return err
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return fmt.Errorf("settlement journal: stat segment %s: %w", path, err)
	}
	j.file = j.wrapFile(f)
	j.segmentName = name
	j.segmentBytes = info.Size()
	return nil
}

// Close flushes and closes the active segment. Subsequent writes return
// ErrClosed; Scan still works (it reads the directory, not the handle).
func (j *Journal) Close() error {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.closed = true
	if j.file == nil {
		return nil
	}
	err := j.file.Close()
	j.file = nil
	j.segmentName = ""
	j.segmentBytes = 0
	return err
}

// SegmentState is one segment's recovery-relevant shape.
type SegmentState struct {
	Name string
	// Effects is how many effect records the segment holds.
	Effects int
	// Unsealed counts this segment's effects that have no seal ANYWHERE in
	// the journal (a seal commonly lands in a later segment).
	Unsealed int
	// Quarantined counts this segment's effects that carry a quarantine.
	Quarantined int
	ModTime     time.Time
}

// ScanResult is the whole-journal view the recovery pass works from.
type ScanResult struct {
	// Unsealed holds every effect with no seal and no quarantine, in append
	// order (oldest first) — the re-drive queue.
	Unsealed []Record
	Effects  int
	Seals    int
	// Quarantined counts distinct quarantined effect keys.
	Quarantined int
	// Malformed counts lines that failed to parse or carried an unknown
	// version, ANYWHERE except a torn final line.
	Malformed int
	// TornTails counts segments whose last line lacked a terminating
	// newline — the expected shape of a crash mid-append.
	TornTails int
	Segments  []SegmentState
}

// Scan reads every segment oldest→newest and reduces it to the unsealed set.
//
// Corruption policy: a torn FINAL line in a segment is the normal crash
// signature (the fsync'd prefix is intact, the tail is not) — warn and skip.
// A parse failure anywhere ELSE means real corruption; log loudly and skip
// the line rather than aborting the pass, so one bad byte cannot strand every
// other recoverable bill.
func (j *Journal) Scan() (ScanResult, error) {
	names, err := segmentNames(j.dir)
	if err != nil {
		return ScanResult{}, err
	}
	var result ScanResult
	sealed := map[Key]bool{}
	quarantined := map[Key]bool{}
	effects := map[Key]Record{}
	var order []Key
	segmentKeys := map[string][]Key{}

	for _, name := range names {
		path := filepath.Join(j.dir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue // pruned by a concurrent pass
			}
			return ScanResult{}, fmt.Errorf("settlement journal: read segment %s: %w", path, err)
		}
		state := SegmentState{Name: name}
		if info, statErr := os.Stat(path); statErr == nil {
			state.ModTime = info.ModTime()
		}
		lines := strings.Split(string(data), "\n")
		// strings.Split leaves a trailing "" for a well-terminated file; a
		// non-empty last element is a torn append.
		if last := lines[len(lines)-1]; last != "" {
			result.TornTails++
			slog.Warn("gateway settlement journal segment has a torn final line (crash signature); skipping it",
				"segment", name, "bytes", len(last))
		}
		lines = lines[:len(lines)-1]
		for i, line := range lines {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var rec Record
			if err := json.Unmarshal([]byte(line), &rec); err != nil || rec.Version != RecordVersion {
				result.Malformed++
				slog.Error("gateway settlement journal record is unreadable; skipping it (money effect may be unrecoverable)",
					"segment", name, "line", i+1, "version", rec.Version, "error", err)
				continue
			}
			key := rec.Key()
			switch rec.Kind {
			case KindEffect:
				result.Effects++
				state.Effects++
				if _, seen := effects[key]; !seen {
					effects[key] = rec
					order = append(order, key)
				}
				segmentKeys[name] = append(segmentKeys[name], key)
			case KindSeal:
				result.Seals++
				sealed[key] = true
			case KindQuarantine:
				quarantined[key] = true
			default:
				result.Malformed++
				slog.Error("gateway settlement journal record has an unknown kind; skipping it",
					"segment", name, "line", i+1, "kind", rec.Kind)
			}
		}
		result.Segments = append(result.Segments, state)
	}

	for _, key := range order {
		if sealed[key] || quarantined[key] {
			continue
		}
		result.Unsealed = append(result.Unsealed, effects[key])
	}
	for i := range result.Segments {
		for _, key := range segmentKeys[result.Segments[i].Name] {
			if quarantined[key] {
				result.Segments[i].Quarantined++
				continue
			}
			if !sealed[key] {
				result.Segments[i].Unsealed++
			}
		}
	}
	result.Quarantined = len(quarantined)
	return result, nil
}

// Prune unlinks segments that are fully sealed, hold no quarantined effect,
// and were last written before `before`. The ACTIVE segment is never pruned.
func (j *Journal) Prune(before time.Time) (int, error) {
	scan, err := j.Scan()
	if err != nil {
		return 0, err
	}
	j.mu.Lock()
	active := j.segmentName
	j.mu.Unlock()

	pruned := 0
	for _, seg := range scan.Segments {
		if seg.Name == active || seg.Unsealed > 0 || seg.Quarantined > 0 {
			continue
		}
		if seg.ModTime.IsZero() || !seg.ModTime.Before(before) {
			continue
		}
		path := filepath.Join(j.dir, seg.Name)
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		if err := os.Remove(path); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return pruned, fmt.Errorf("settlement journal: prune segment %s: %w", path, err)
		}
		if err := fsyncDir(j.dir); err != nil {
			return pruned, err
		}
		pruned++
		j.mu.Lock()
		j.totalBytes -= info.Size()
		if j.totalBytes < 0 {
			j.totalBytes = 0
		}
		j.metrics.setBytes(j.totalBytes)
		j.mu.Unlock()
	}
	return pruned, nil
}

// RecordRecovered counts one re-drive outcome for /metrics.
func (j *Journal) RecordRecovered(result string) { j.metrics.incRecovered(result) }

// SetPending publishes the current unsealed / quarantined gauges.
func (j *Journal) SetPending(unsealed, quarantined int64) {
	j.metrics.setPending(unsealed, quarantined)
}

// MetricsSnapshot returns a consistent copy of the journal counters.
func (j *Journal) MetricsSnapshot() Snapshot { return j.metrics.snapshot() }

func segmentName(now time.Time, pid int) string {
	return fmt.Sprintf("%s%d-%d%s", segmentPrefix, now.UTC().UnixMilli(), pid, segmentSuffix)
}

// segmentNames returns the segment file names sorted oldest→newest by the
// millisecond stamp in the name (NOT lexicographically, and NOT by mtime:
// mtime moves when a seal lands in an older segment... which it cannot, but
// relying on the name keeps the ordering a pure function of the writer).
func segmentNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("settlement journal: read dir %s: %w", dir, err)
	}
	type seg struct {
		name  string
		stamp int64
	}
	segs := make([]seg, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasPrefix(name, segmentPrefix) || !strings.HasSuffix(name, segmentSuffix) {
			continue
		}
		trimmed := strings.TrimSuffix(strings.TrimPrefix(name, segmentPrefix), segmentSuffix)
		stampRaw, _, _ := strings.Cut(trimmed, "-")
		stamp, err := strconv.ParseInt(stampRaw, 10, 64)
		if err != nil {
			slog.Warn("gateway settlement journal segment has an unparseable name; scanning it last", "segment", name)
			stamp = 1<<62 - 1
		}
		segs = append(segs, seg{name: name, stamp: stamp})
	}
	sort.Slice(segs, func(a, b int) bool {
		if segs[a].stamp != segs[b].stamp {
			return segs[a].stamp < segs[b].stamp
		}
		return segs[a].name < segs[b].name
	})
	names := make([]string, 0, len(segs))
	for _, s := range segs {
		names = append(names, s.name)
	}
	return names, nil
}

func dirBytes(dir string) (int64, error) {
	names, err := segmentNames(dir)
	if err != nil {
		return 0, err
	}
	var total int64
	for _, name := range names {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		total += info.Size()
	}
	return total, nil
}

// fsyncDir makes a create/unlink of a segment durable. On platforms where a
// directory cannot be opened for sync this is a no-op rather than a failure —
// the record write itself is still fsynced.
func fsyncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("settlement journal: open dir %s: %w", dir, err)
	}
	defer d.Close()
	if err := d.Sync(); err != nil {
		// Some filesystems reject directory fsync outright (EINVAL/ENOTSUP);
		// that is a platform quirk, not a durability failure, and is safe to
		// ignore. Any OTHER error means the new segment's directory entry may
		// not survive power loss — propagate it so WriteEffect reports the
		// failure instead of returning a false durability promise (audit R1,
		// code MEDIUM).
		if errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOTSUP) {
			slog.Warn("gateway settlement journal directory fsync unsupported on this filesystem", "dir", dir, "error", err)
			return nil
		}
		return fmt.Errorf("settlement journal: fsync dir %s: %w", dir, err)
	}
	return nil
}
