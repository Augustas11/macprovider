package main

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// #1690 review (F-8 restart race): the deploy's in-flight count is a
// pre-check; what protects a request admitted after it is the SIGTERM
// drain. The drain must be long enough for a normal request to finish and
// below the unit's TimeoutStopSec, so systemd never SIGKILLs mid-drain.
func TestGracefulShutdownFitsTheSystemdStopTimeout(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "dist", "macprovider-gateway.service"))
	if err != nil {
		t.Fatal(err)
	}
	stop := time.Duration(0)
	for _, line := range strings.Split(string(raw), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "TimeoutStopSec="); ok {
			n, err := strconv.Atoi(v)
			if err != nil {
				t.Fatalf("TimeoutStopSec=%q: %v", v, err)
			}
			stop = time.Duration(n) * time.Second
		}
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "KillSignal="); ok && v != "SIGTERM" {
			t.Fatalf("KillSignal=%s, want SIGTERM so a restart drains", v)
		}
	}
	if stop == 0 {
		t.Fatal("the gateway unit sets no TimeoutStopSec")
	}
	if gracefulShutdownTimeout < 30*time.Second {
		t.Fatalf("drain %s is too short to let in-flight requests settle", gracefulShutdownTimeout)
	}
	if gracefulShutdownTimeout > stop-2*time.Second {
		t.Fatalf("drain %s does not fit TimeoutStopSec %s with margin", gracefulShutdownTimeout, stop)
	}
}

// A request in flight when the drain starts completes; a new connection
// after it is refused.
func TestDrainHTTPServerFinishesInFlightRequests(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	srv := newHTTPServer(ln.Addr().String(), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		_, _ = io.WriteString(w, "settled")
	}))
	go func() { _ = srv.Serve(ln) }()
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := io.WriteString(conn, "GET / HTTP/1.1\r\nHost: x\r\n\r\n"); err != nil {
		t.Fatal(err)
	}
	<-started
	drained := make(chan struct{})
	go func() {
		drainHTTPServer(srv, 5*time.Second)
		close(drained)
	}()
	time.Sleep(100 * time.Millisecond)
	if c, err := net.DialTimeout("tcp", ln.Addr().String(), time.Second); err == nil {
		_ = c.Close()
		t.Fatal("the listener still accepted a connection during the drain")
	}
	close(release)
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("in-flight request was cut by the drain: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK || string(body) != "settled" {
		t.Fatalf("in-flight response=%d %q", resp.StatusCode, body)
	}
	select {
	case <-drained:
	case <-time.After(5 * time.Second):
		t.Fatal("drain did not return after the last request finished")
	}
}
