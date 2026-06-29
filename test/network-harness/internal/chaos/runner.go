// Package chaos runs the scenario's ChaosEvents timeline alongside the
// buyer fleet. Each event is a shell command fired at a fixed offset
// from scenario start; result rows feed the artifact bundle so triage
// can correlate "harness killed M1 at t=5s" with what buyers observed.
package chaos

import (
	"context"
	"os/exec"
	"sync"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

// EventResult is one fired chaos event, recorded for the artifact bundle.
type EventResult struct {
	Index       int       `json:"index"`
	Description string    `json:"description"`
	Command     string    `json:"command"`
	ScheduledAt time.Time `json:"scheduled_at"`
	FiredAt     time.Time `json:"fired_at"`
	Skipped     bool      `json:"skipped,omitempty"`
	ExitCode    int       `json:"exit_code"`
	Stdout      string    `json:"stdout,omitempty"`
	Stderr      string    `json:"stderr,omitempty"`
	Err         string    `json:"err,omitempty"`
}

// Runner schedules and reports on chaos events. Start in a goroutine
// before the buyer fleet; call Results() after the fleet returns.
type Runner struct {
	events  []scenario.ChaosEvent
	results []EventResult
	mu      sync.Mutex
	wg      sync.WaitGroup
	start   time.Time
}

func NewRunner(events []scenario.ChaosEvent) *Runner {
	return &Runner{events: events}
}

// Start fires each event at its scheduled offset. It does NOT block —
// it returns immediately and runs the schedule in the background. Call
// Wait() before reading Results().
//
// ctx cancellation aborts pending events (recorded as Skipped). In-flight
// commands run to their natural completion or get killed by exec.Cmd's
// own context handling.
func (r *Runner) Start(ctx context.Context) {
	r.start = time.Now().UTC()
	for i, e := range r.events {
		i, e := i, e
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			scheduledAt := r.start.Add(e.At)
			delay := time.Until(scheduledAt)
			if delay > 0 {
				select {
				case <-time.After(delay):
				case <-ctx.Done():
					r.record(EventResult{
						Index:       i,
						Description: e.Description,
						Command:     e.Command,
						ScheduledAt: scheduledAt,
						Skipped:     true,
						Err:         "cancelled before firing",
					})
					return
				}
			}
			r.fire(ctx, i, e, scheduledAt)
		}()
	}
}

func (r *Runner) fire(ctx context.Context, i int, e scenario.ChaosEvent, scheduledAt time.Time) {
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", e.Command)
	stdout, stderr, err := captureCombined(cmd)
	exitCode := 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		} else {
			exitCode = -1
		}
	}
	res := EventResult{
		Index:       i,
		Description: e.Description,
		Command:     e.Command,
		ScheduledAt: scheduledAt,
		FiredAt:     time.Now().UTC(),
		ExitCode:    exitCode,
		Stdout:      stdout,
		Stderr:      stderr,
	}
	if err != nil && exitCode == 0 {
		res.Err = err.Error()
	}
	r.record(res)
}

func captureCombined(cmd *exec.Cmd) (stdout, stderr string, err error) {
	out, err := cmd.Output()
	stdout = string(out)
	if ee, ok := err.(*exec.ExitError); ok {
		stderr = string(ee.Stderr)
	}
	return stdout, stderr, err
}

// Wait blocks until all scheduled events have either fired or been
// cancelled. Safe to call multiple times.
func (r *Runner) Wait() { r.wg.Wait() }

func (r *Runner) Results() []EventResult {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]EventResult, len(r.results))
	copy(out, r.results)
	return out
}

func (r *Runner) record(e EventResult) {
	r.mu.Lock()
	r.results = append(r.results, e)
	r.mu.Unlock()
}
