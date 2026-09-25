package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"testing"
	"time"
)

// #1690 review L-5b: after the first SIGTERM starts the drain, a second
// SIGTERM terminates the process at once. The helper process runs the same
// waitForShutdownSignal the gateway main does, then "drains" for a minute.
func TestSecondSignalDuringDrainExitsImmediately(t *testing.T) {
	if os.Getenv("GATEWAY_SIGNAL_HELPER") == "1" {
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		_, _ = os.Stdout.WriteString("ready\n")
		waitForShutdownSignal(ctx, stop)
		_, _ = os.Stdout.WriteString("draining\n")
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestSecondSignalDuringDrainExitsImmediately$")
	cmd.Env = append(os.Environ(), "GATEWAY_SIGNAL_HELPER=1")
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	readLine := func(want string) {
		t.Helper()
		buf := make([]byte, 0, 64)
		one := make([]byte, 1)
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			n, err := out.Read(one)
			if n == 1 {
				if one[0] == '\n' {
					if string(buf) == want {
						return
					}
					buf = buf[:0]
					continue
				}
				buf = append(buf, one[0])
			}
			if err != nil {
				break
			}
		}
		_ = cmd.Process.Kill()
		t.Fatalf("helper never printed %q", want)
	}
	readLine("ready")
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	readLine("draining")
	if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			t.Fatalf("helper exited with %v, want termination by the second SIGTERM", err)
		}
		if status, ok := exitErr.Sys().(syscall.WaitStatus); !ok || !status.Signaled() || status.Signal() != syscall.SIGTERM {
			t.Fatalf("helper exit %v, want killed by SIGTERM", err)
		}
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("a second SIGTERM during the drain did not terminate the process")
	}
}
