package router

import (
	"bufio"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
	"time"
)

// eventChunkReader delivers one SSE event per Read call, the way a
// coordinator stream typically arrives off the wire: each TCP read
// carries a whole "data: ...\n\n" frame.
type eventChunkReader struct {
	events []string
	i      int
}

func (r *eventChunkReader) Read(p []byte) (int, error) {
	if r.i >= len(r.events) {
		return 0, io.EOF
	}
	n := copy(p, r.events[r.i])
	r.i++
	return n, nil
}

func (r *eventChunkReader) Close() error { return nil }

func sseEvents(n int) []string {
	events := make([]string, n)
	for i := range events {
		events[i] = `data: {"choices":[{"delta":{"content":"tok"}}]}` + "\n\n"
	}
	return events
}

func drainStream(tb testing.TB, events []string) int {
	tb.Helper()
	src := &eventChunkReader{events: events}
	reader := bufio.NewReaderSize(src, maxStreamingLineBytes)
	deadline := time.Now().Add(time.Minute)
	lines := 0
	for {
		_, err := readStreamingLineWithIdleTimeout(context.Background(), reader, deadline, func() {}, src)
		if errors.Is(err, io.EOF) {
			return lines
		}
		if err != nil {
			tb.Fatalf("read: %v", err)
		}
		lines++
	}
}

func BenchmarkStreamingReadIdleTimeout(b *testing.B) {
	events := sseEvents(1000)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		drainStream(b, events)
	}
}

type nopStreamCloser struct{}

func (nopStreamCloser) Close() error { return nil }

// A line already buffered by bufio cannot block, so reading it must not pay
// for the deadline race (goroutine, channel, timer): zero allocations. The
// first read fills the buffer through the timed path.
func TestStreamingReadBufferedLineAllocatesNothing(t *testing.T) {
	reader := bufio.NewReaderSize(strings.NewReader(strings.Repeat("data: x\n", 5000)), maxStreamingLineBytes)
	deadline := time.Now().Add(time.Minute)
	if _, err := readStreamingLineWithIdleTimeout(context.Background(), reader, deadline, func() {}, nopStreamCloser{}); err != nil {
		t.Fatalf("priming read: %v", err)
	}
	allocs := testing.AllocsPerRun(1000, func() {
		line, err := readStreamingLineWithIdleTimeout(context.Background(), reader, deadline, func() {}, nopStreamCloser{})
		if err != nil || string(line) != "data: x\n" {
			t.Fatalf("line=%q err=%v", line, err)
		}
	})
	if allocs != 0 {
		t.Fatalf("buffered line read allocated %.1f times per call; want 0 (no reader goroutine)", allocs)
	}
}

// Timeout semantics must be unchanged: a stalled upstream still
// cancels, closes the body and reports errStreamingIdleTimeout even
// when the previous line was served from the buffer.
func TestStreamingReadIdleTimeoutStillFiresAfterBufferedLine(t *testing.T) {
	pr, pw := io.Pipe()
	defer pw.Close()
	go func() { _, _ = pw.Write([]byte("data: x\n\n")) }()
	reader := bufio.NewReaderSize(pr, maxStreamingLineBytes)
	cancelled := false
	cancel := func() { cancelled = true }
	deadline := time.Now().Add(150 * time.Millisecond)
	for i := 0; i < 2; i++ {
		if _, err := readStreamingLineWithIdleTimeout(context.Background(), reader, deadline, cancel, pr); err != nil {
			t.Fatalf("line %d: %v", i, err)
		}
	}
	start := time.Now()
	_, err := readStreamingLineWithIdleTimeout(context.Background(), reader, deadline, cancel, pr)
	if !errors.Is(err, errStreamingIdleTimeout) {
		t.Fatalf("err = %v, want errStreamingIdleTimeout", err)
	}
	if !cancelled {
		t.Fatal("upstream was not cancelled on idle timeout")
	}
	if waited := time.Since(start); waited > 2*time.Second {
		t.Fatalf("timeout took %v", waited)
	}
}

// An already-expired deadline must still time out even when a full
// line is sitting in the buffer (pre-change behaviour).
func TestStreamingReadExpiredDeadlineWinsOverBufferedLine(t *testing.T) {
	src := &eventChunkReader{events: sseEvents(2)}
	reader := bufio.NewReaderSize(src, maxStreamingLineBytes)
	if _, err := readStreamingLineWithIdleTimeout(context.Background(), reader, time.Now().Add(time.Minute), func() {}, src); err != nil {
		t.Fatalf("first read: %v", err)
	}
	_, err := readStreamingLineWithIdleTimeout(context.Background(), reader, time.Now().Add(-time.Second), func() {}, src)
	if !errors.Is(err, errStreamingIdleTimeout) {
		t.Fatalf("err = %v, want errStreamingIdleTimeout", err)
	}
}
