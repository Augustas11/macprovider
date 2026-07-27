package journal

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testJournal(t *testing.T, mutate func(*Options)) *Journal {
	t.Helper()
	opts := Options{Dir: filepath.Join(t.TempDir(), "settlement-journal"), Fsync: true}
	if mutate != nil {
		mutate(&opts)
	}
	j, err := Open(opts)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = j.Close() })
	return j
}

func effect(requestID string) Record {
	return Record{
		AccountID:        "acct_j",
		RequestID:        requestID,
		WindowDate:       "2026-05-29",
		PromptTokens:     8,
		CompletionTokens: 12,
		TotalTokens:      20,
		MaxTotalTokens:   20,
		TokenSource:      "provider_reported",
		Outcome:          "ok",
	}
}

// recordingFile wraps the REAL segment file and records the call order, so
// the fsync assertion below is about production behavior and not about a
// stubbed-out file.
type recordingFile struct {
	inner fileHandle
	calls *[]string
}

func (f recordingFile) Write(p []byte) (int, error) {
	*f.calls = append(*f.calls, "write")
	return f.inner.Write(p)
}

func (f recordingFile) Sync() error {
	*f.calls = append(*f.calls, "sync")
	return f.inner.Sync()
}

func (f recordingFile) Close() error { return f.inner.Close() }

// TestSettlementJournal_EffectWriteFsyncs pins THE load-bearing property of
// this package: an effect record is on stable storage before WriteEffect
// returns, i.e. before the settle attempt it describes begins. Without it the
// journal degrades to "durable unless the machine actually loses power",
// which is most of the failure classes issue #763 exists to cover.
//
// It also pins the other half of the contract: seals are NOT fsynced. A seal
// costs one idempotent re-drive if lost, so paying a second fsync per billed
// request for it would be a pure latency tax.
//
// This test must never be skipped. If it becomes awkward, the guard to keep
// is "Sync fired, after the write, before the return" — nothing else here is
// load-bearing.
func TestSettlementJournal_EffectWriteFsyncs(t *testing.T) {
	var calls []string
	j := testJournal(t, nil)
	j.wrapFile = func(f fileHandle) fileHandle { return recordingFile{inner: f, calls: &calls} }

	if err := j.WriteEffect(effect("req-fsync")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	if len(calls) != 2 || calls[0] != "write" || calls[1] != "sync" {
		t.Fatalf("WriteEffect call sequence = %v, want [write sync] — the effect record MUST be fsynced "+
			"BEFORE WriteEffect returns, or a power loss between the arm and the settle loses the bill", calls)
	}

	if err := j.WriteSeal(Key{AccountID: "acct_j", RequestID: "req-fsync", Effect: EffectSettle}, SealSettled); err != nil {
		t.Fatalf("WriteSeal: %v", err)
	}
	if len(calls) != 3 || calls[2] != "write" {
		t.Fatalf("WriteSeal call sequence = %v, want a trailing bare write — seals must NOT fsync "+
			"(a lost seal costs one idempotent re-drive, not a bill)", calls)
	}
}

func TestSettlementJournal_DirAndFileModesAreTight(t *testing.T) {
	j := testJournal(t, nil)
	if err := j.WriteEffect(effect("req-modes")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	info, err := os.Stat(j.Dir())
	if err != nil {
		t.Fatalf("stat dir: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("journal dir mode=%o want 0700", got)
	}
	names, err := segmentNames(j.Dir())
	if err != nil || len(names) != 1 {
		t.Fatalf("segmentNames=%v err=%v want exactly one segment", names, err)
	}
	segInfo, err := os.Stat(filepath.Join(j.Dir(), names[0]))
	if err != nil {
		t.Fatalf("stat segment: %v", err)
	}
	if got := segInfo.Mode().Perm(); got != 0o600 {
		t.Fatalf("segment mode=%o want 0600", got)
	}
	// The journal carries billing identity, never conversation content.
	raw, err := os.ReadFile(filepath.Join(j.Dir(), names[0]))
	if err != nil {
		t.Fatalf("read segment: %v", err)
	}
	var rec Record
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(raw))), &rec); err != nil {
		t.Fatalf("segment line is not a v1 record: %v (%s)", err, raw)
	}
	if rec.Version != RecordVersion || rec.Kind != KindEffect || rec.Effect != EffectSettle {
		t.Fatalf("record=%+v want v%d effect/settle", rec, RecordVersion)
	}
	if rec.WrittenAtUnixMS == 0 {
		t.Fatal("record has no write timestamp; the recovery grace window depends on it")
	}
}

func TestSettlementJournal_TornTailLineIgnored(t *testing.T) {
	j := testJournal(t, nil)
	if err := j.WriteEffect(effect("req-a")); err != nil {
		t.Fatalf("WriteEffect a: %v", err)
	}
	if err := j.WriteEffect(effect("req-b")); err != nil {
		t.Fatalf("WriteEffect b: %v", err)
	}
	names, _ := segmentNames(j.Dir())
	path := filepath.Join(j.Dir(), names[0])
	// A crash mid-append: a partial line with no terminating newline. The
	// fsync'd prefix is intact; only the tail is garbage.
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open segment: %v", err)
	}
	if _, err := f.WriteString(`{"v":1,"kind":"effect","account_id":"acct_j","req`); err != nil {
		t.Fatalf("write torn tail: %v", err)
	}
	_ = f.Close()

	scan, err := j.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if scan.TornTails != 1 {
		t.Fatalf("TornTails=%d want 1", scan.TornTails)
	}
	if scan.Malformed != 0 {
		t.Fatalf("Malformed=%d want 0 — a torn FINAL line is the expected crash signature, not corruption", scan.Malformed)
	}
	if len(scan.Unsealed) != 2 {
		t.Fatalf("Unsealed=%d want 2 — the intact prefix must still be recoverable", len(scan.Unsealed))
	}
}

func TestSettlementJournal_MalformedMidFileLineIsSkippedLoudly(t *testing.T) {
	j := testJournal(t, nil)
	if err := j.WriteEffect(effect("req-a")); err != nil {
		t.Fatalf("WriteEffect a: %v", err)
	}
	names, _ := segmentNames(j.Dir())
	path := filepath.Join(j.Dir(), names[0])
	f, _ := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	if _, err := f.WriteString("{not json}\n"); err != nil {
		t.Fatalf("write garbage: %v", err)
	}
	_ = f.Close()
	if err := j.WriteEffect(effect("req-b")); err != nil {
		t.Fatalf("WriteEffect b: %v", err)
	}

	scan, err := j.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if scan.Malformed != 1 {
		t.Fatalf("Malformed=%d want 1", scan.Malformed)
	}
	if len(scan.Unsealed) != 2 {
		t.Fatalf("Unsealed=%d want 2 — one bad line must not strand the other recoverable effects", len(scan.Unsealed))
	}
}

func TestSettlementJournal_SegmentRotationAndPrune(t *testing.T) {
	// One record is ~250 bytes, so a 300-byte cap rotates on every write.
	j := testJournal(t, func(o *Options) { o.SegmentMaxBytes = 300 })
	keys := []Key{}
	for _, id := range []string{"req-1", "req-2", "req-3"} {
		if err := j.WriteEffect(effect(id)); err != nil {
			t.Fatalf("WriteEffect %s: %v", id, err)
		}
		keys = append(keys, Key{AccountID: "acct_j", RequestID: id, Effect: EffectSettle})
		// Segment names carry a millisecond stamp; keep them distinct so the
		// oldest→newest scan order is unambiguous.
		time.Sleep(2 * time.Millisecond)
	}
	scan, err := j.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(scan.Segments) < 3 {
		t.Fatalf("segments=%d want >=3 — the segment cap did not rotate", len(scan.Segments))
	}
	if len(scan.Unsealed) != 3 {
		t.Fatalf("Unsealed=%d want 3", len(scan.Unsealed))
	}
	// Scan order must be oldest→newest: recovery re-drives in the order the
	// effects were armed.
	for i, want := range []string{"req-1", "req-2", "req-3"} {
		if scan.Unsealed[i].RequestID != want {
			t.Fatalf("Unsealed[%d]=%s want %s (segments must scan oldest→newest)", i, scan.Unsealed[i].RequestID, want)
		}
	}

	// Nothing is prunable while effects are unsealed, however old.
	if pruned, err := j.Prune(time.Now().Add(time.Hour)); err != nil || pruned != 0 {
		t.Fatalf("Prune with unsealed effects pruned=%d err=%v, want 0 — an unsealed effect is an unrecovered bill", pruned, err)
	}
	for _, key := range keys[:2] {
		if err := j.WriteSeal(key, SealSettled); err != nil {
			t.Fatalf("WriteSeal: %v", err)
		}
	}
	// req-3 is still unsealed, and the seals landed in the ACTIVE segment,
	// so only the two sealed non-active segments may go.
	pruned, err := j.Prune(time.Now().Add(time.Hour))
	if err != nil {
		t.Fatalf("Prune: %v", err)
	}
	if pruned != 2 {
		t.Fatalf("pruned=%d want 2 (the two fully-sealed, non-active segments)", pruned)
	}
	scan, err = j.Scan()
	if err != nil {
		t.Fatalf("Scan after prune: %v", err)
	}
	if len(scan.Unsealed) != 1 || scan.Unsealed[0].RequestID != "req-3" {
		t.Fatalf("after prune Unsealed=%+v want only req-3", scan.Unsealed)
	}
	if snapshot := j.MetricsSnapshot(); snapshot.Bytes <= 0 {
		t.Fatalf("bytes gauge=%d want >0 after prune", snapshot.Bytes)
	}
}

func TestSettlementJournal_QuarantinedSegmentIsNotPruned(t *testing.T) {
	j := testJournal(t, func(o *Options) { o.SegmentMaxBytes = 300 })
	if err := j.WriteEffect(effect("req-q")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	time.Sleep(2 * time.Millisecond)
	key := Key{AccountID: "acct_j", RequestID: "req-q", Effect: EffectSettle}
	if err := j.WriteQuarantine(key, "usage_event_conflict", 10); err != nil {
		t.Fatalf("WriteQuarantine: %v", err)
	}
	if pruned, err := j.Prune(time.Now().Add(time.Hour)); err != nil || pruned != 0 {
		t.Fatalf("pruned=%d err=%v want 0 — a quarantined effect must stay on disk for the operator", pruned, err)
	}
	scan, err := j.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if scan.Quarantined != 1 {
		t.Fatalf("Quarantined=%d want 1", scan.Quarantined)
	}
	if len(scan.Unsealed) != 0 {
		t.Fatalf("Unsealed=%d want 0 — a quarantine suppresses re-drive", len(scan.Unsealed))
	}
}

func TestSettlementJournal_ReopenAfterCloseRecovers(t *testing.T) {
	// Process-crash proxy (failure class C4): everything written before the
	// close must be visible to the next process.
	dir := filepath.Join(t.TempDir(), "settlement-journal")
	first, err := Open(Options{Dir: dir, Fsync: true})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := first.WriteEffect(effect("req-crash")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := first.WriteEffect(effect("req-after-close")); err != ErrClosed {
		t.Fatalf("write after Close err=%v want ErrClosed", err)
	}

	second, err := Open(Options{Dir: dir, Fsync: true})
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer second.Close()
	scan, err := second.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(scan.Unsealed) != 1 || scan.Unsealed[0].RequestID != "req-crash" {
		t.Fatalf("reopened journal Unsealed=%+v want the pre-crash effect", scan.Unsealed)
	}
	if scan.Unsealed[0].TotalTokens != 20 || scan.Unsealed[0].TokenSource != "provider_reported" {
		t.Fatalf("reopened effect lost its billing payload: %+v", scan.Unsealed[0])
	}
	if err := second.WriteSeal(scan.Unsealed[0].Key(), SealUsageEvent); err != nil {
		t.Fatalf("WriteSeal: %v", err)
	}
	scan, _ = second.Scan()
	if len(scan.Unsealed) != 0 {
		t.Fatalf("after seal Unsealed=%d want 0", len(scan.Unsealed))
	}
}

func TestSettlementJournal_HardSizeCapRefusesWrites(t *testing.T) {
	// The lesser-harm choice: refusing a journal record is fail-open for
	// billing (settlement still runs), while filling the disk takes sqlite —
	// and therefore the whole money path — down with it.
	j := testJournal(t, func(o *Options) { o.MaxTotalBytes = 300; o.SegmentMaxBytes = 300 })
	if err := j.WriteEffect(effect("req-1")); err != nil {
		t.Fatalf("first WriteEffect: %v", err)
	}
	err := j.WriteEffect(effect("req-2"))
	if err != ErrFull {
		t.Fatalf("second WriteEffect err=%v want ErrFull", err)
	}
	snapshot := j.MetricsSnapshot()
	if snapshot.WriteFailures != 1 {
		t.Fatalf("write_failures=%d want 1", snapshot.WriteFailures)
	}
	if snapshot.Effects != 1 {
		t.Fatalf("effects=%d want 1 (the refused write must not count)", snapshot.Effects)
	}
	scan, _ := j.Scan()
	if len(scan.Unsealed) != 1 {
		t.Fatalf("Unsealed=%d want 1 — the accepted effect must still be recoverable", len(scan.Unsealed))
	}
}

func TestSettlementJournal_OpenFailsClosedOnUnwritableDir(t *testing.T) {
	root := t.TempDir()
	locked := filepath.Join(root, "locked")
	if err := os.Mkdir(locked, 0o500); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o700) })
	if _, err := Open(Options{Dir: filepath.Join(locked, "settlement-journal"), Fsync: true}); err == nil {
		t.Fatal("Open on an unwritable path returned nil error; cmd/gateway would boot with durability silently disabled")
	}
}

func TestSettlementJournal_MetricsSnapshotRenders(t *testing.T) {
	j := testJournal(t, nil)
	if err := j.WriteEffect(effect("req-m")); err != nil {
		t.Fatalf("WriteEffect: %v", err)
	}
	j.RecordRecovered(RecoveredUsageEvent)
	j.SetPending(3, 1)
	out := j.MetricsSnapshot().Prometheus()
	for _, want := range []string{
		"gateway_settlement_journal_effects_total 1",
		"gateway_settlement_journal_recovered_total{result=\"usage_event\"} 1",
		"gateway_settlement_journal_unsealed 3",
		"gateway_settlement_journal_quarantined 1",
		"gateway_settlement_journal_bytes",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("metrics output missing %q:\n%s", want, out)
		}
	}
}
