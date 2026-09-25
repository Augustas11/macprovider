package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// The helper process plays the coordinator's main signal loop with real
// signals. Its first reload blocks until the parent writes a line to stdin,
// like a reload stuck behind a slow SQLite write (#1693 E2 V4). Mode "legacy"
// is the pre-fix loop (one capacity-1 channel for SIGINT/SIGTERM/SIGHUP, the
// reload run inline), kept to prove the test reproduces the dropped SIGTERM.
func TestCoordinatorSignalLoopHelperProcess(t *testing.T) {
	mode := os.Getenv("MACPROVIDER_SIGNAL_LOOP_HELPER")
	if mode == "" {
		t.Skip("helper process only")
	}
	release := make(chan struct{})
	go func() {
		_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
		close(release)
	}()
	var n atomic.Int32
	reload := func() {
		k := n.Add(1)
		fmt.Printf("reload-start %d\n", k)
		if k == 1 {
			<-release
		}
		fmt.Printf("reload-done %d\n", k)
	}
	if mode == "legacy" {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
		fmt.Println("ready")
		for sig := range signals {
			if sig == syscall.SIGHUP {
				reload()
				continue
			}
			fmt.Printf("shutdown-begin %s\n", sig)
			os.Exit(0)
		}
	}
	signals := notifyCoordinatorSignals()
	reloads := startSIGHUPReloader(signals.hup, reload)
	fmt.Println("ready")
	sig := <-signals.term
	fmt.Printf("shutdown-begin %s\n", sig)
	reloads.halt()
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if reloads.wait(ctx) {
		fmt.Println("reloads-idle")
	} else {
		fmt.Println("reload-abandoned")
	}
	os.Exit(0)
}

type signalLoopHelper struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	lines chan string
	seen  []string
}

func startSignalLoopHelper(t *testing.T, mode string) *signalLoopHelper {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestCoordinatorSignalLoopHelperProcess$")
	cmd.Env = append(os.Environ(), "MACPROVIDER_SIGNAL_LOOP_HELPER="+mode)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	h := &signalLoopHelper{cmd: cmd, stdin: stdin, lines: make(chan string, 64)}
	go func() {
		sc := bufio.NewScanner(out)
		for sc.Scan() {
			h.lines <- strings.TrimSpace(sc.Text())
		}
		close(h.lines)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	h.expect(t, "ready", 10*time.Second)
	return h
}

// expect waits for the line want; lines before it are recorded.
func (h *signalLoopHelper) expect(t *testing.T, want string, within time.Duration) {
	t.Helper()
	deadline := time.After(within)
	for {
		select {
		case line, ok := <-h.lines:
			if !ok {
				t.Fatalf("helper exited before %q (saw %v)", want, h.seen)
			}
			h.seen = append(h.seen, line)
			if line == want {
				return
			}
		case <-deadline:
			t.Fatalf("no %q within %s (saw %v)", want, within, h.seen)
		}
	}
}

// quiet fails when any line arrives within d.
func (h *signalLoopHelper) quiet(t *testing.T, d time.Duration, why string) {
	t.Helper()
	select {
	case line, ok := <-h.lines:
		if ok {
			t.Fatalf("%s: unexpected %q (saw %v)", why, line, h.seen)
		}
	case <-time.After(d):
	}
}

func (h *signalLoopHelper) signal(t *testing.T, sigs ...syscall.Signal) {
	t.Helper()
	for _, s := range sigs {
		if err := h.cmd.Process.Signal(s); err != nil {
			t.Fatal(err)
		}
		// Let each signal land before the next, as separate senders would.
		time.Sleep(50 * time.Millisecond)
	}
}

func (h *signalLoopHelper) release(t *testing.T) {
	t.Helper()
	if _, err := io.WriteString(h.stdin, "go\n"); err != nil {
		t.Fatal(err)
	}
}

// The E2 V4 condition on the pre-fix loop: a lane SIGHUP starts a slow reload,
// a rollback re-HUP fills the shared capacity-1 channel, and the SIGTERM that
// follows is dropped: shutdown never begins, even after the reload finishes.
func TestLegacySignalLoopDropsSIGTERMBehindQueuedSIGHUP(t *testing.T) {
	h := startSignalLoopHelper(t, "legacy")
	h.signal(t, syscall.SIGHUP)
	h.expect(t, "reload-start 1", 5*time.Second)
	h.signal(t, syscall.SIGHUP, syscall.SIGHUP, syscall.SIGTERM)
	h.quiet(t, time.Second, "legacy loop is blocked in the reload")
	h.release(t)
	h.expect(t, "reload-done 1", 5*time.Second)
	h.expect(t, "reload-done 2", 5*time.Second)
	h.quiet(t, 2*time.Second, "the pre-fix loop must reproduce the dropped SIGTERM")
}

// HUP, HUP, TERM while a reload is blocked: shutdown begins promptly, the
// SIGTERM is never lost, and the blocked reload does not hold up the exit.
func TestSIGTERMDuringBlockedReloadShutsDownPromptly(t *testing.T) {
	h := startSignalLoopHelper(t, "split")
	h.signal(t, syscall.SIGHUP)
	h.expect(t, "reload-start 1", 5*time.Second)
	start := time.Now()
	h.signal(t, syscall.SIGHUP, syscall.SIGHUP, syscall.SIGTERM)
	h.expect(t, "shutdown-begin terminated", 2*time.Second)
	h.expect(t, "reload-abandoned", 2*time.Second)
	done := make(chan error, 1)
	go func() { done <- h.cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("helper must exit cleanly: %v (saw %v)", err, h.seen)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("helper did not exit after SIGTERM (saw %v)", h.seen)
	}
	if elapsed := time.Since(start); elapsed > 4*time.Second {
		t.Fatalf("shutdown took %s behind a blocked reload", elapsed)
	}
	for _, line := range h.seen {
		if line == "reload-start 2" {
			t.Fatalf("no reload may start once shutdown began (saw %v)", h.seen)
		}
	}
}

// Repeated SIGHUPs during a reload coalesce into exactly one follow-up
// reload, and a later SIGTERM still shuts down once reloads are idle.
func TestSIGHUPsDuringReloadCoalesceIntoOneFollowUp(t *testing.T) {
	h := startSignalLoopHelper(t, "split")
	h.signal(t, syscall.SIGHUP)
	h.expect(t, "reload-start 1", 5*time.Second)
	h.signal(t, syscall.SIGHUP, syscall.SIGHUP, syscall.SIGHUP)
	time.Sleep(200 * time.Millisecond)
	h.release(t)
	h.expect(t, "reload-done 1", 5*time.Second)
	h.expect(t, "reload-start 2", 5*time.Second)
	h.expect(t, "reload-done 2", 5*time.Second)
	h.quiet(t, time.Second, "three SIGHUPs during one reload must coalesce into one follow-up")
	h.signal(t, syscall.SIGTERM)
	h.expect(t, "shutdown-begin terminated", 2*time.Second)
	h.expect(t, "reloads-idle", 2*time.Second)
}
