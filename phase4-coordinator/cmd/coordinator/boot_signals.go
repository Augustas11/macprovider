package main

import (
	"bufio"
	"errors"
	"io/fs"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"

	"github.com/rs/zerolog"
)

// bootSIGHUPGuard catches SIGHUP from process start until the main signal
// loop owns it (#1693 E2 V8). Without it a SIGHUP that arrives while the
// coordinator boots hits Go's default disposition and terminates the process,
// and systemd records a SIGHUP death as a clean exit, so Restart=on-failure
// does not restart it. A SIGHUP before ready is ignored with a log line: the
// boot applies whatever config is on disk, and senders signal only a
// coordinator that answers /healthz (the main loop registers before the
// listeners start).
type bootSIGHUPGuard struct {
	ch     chan os.Signal
	done   chan struct{}
	handed atomic.Bool
}

func installBootSIGHUPGuard(logger zerolog.Logger) *bootSIGHUPGuard {
	g := &bootSIGHUPGuard{ch: make(chan os.Signal, 8), done: make(chan struct{})}
	signal.Notify(g.ch, syscall.SIGHUP)
	go func() {
		defer close(g.done)
		for range g.ch {
			if g.handed.Load() {
				continue
			}
			logger.Warn().
				Str("event", "coordinator_sighup_before_ready").
				Msg("SIGHUP received before the coordinator finished booting; ignored (boot applies the on-disk config; signal again once /healthz answers)")
		}
	}()
	return g
}

// handOff releases SIGHUP to the main signal loop. Call it only after the main
// loop's signal.Notify includes SIGHUP, so no SIGHUP reaches the default
// disposition in between.
func (g *bootSIGHUPGuard) handOff() {
	g.handed.Store(true)
	signal.Stop(g.ch)
	close(g.ch)
	<-g.done
}

// Pricing recovery wiring (#1693 E2 V10). A pre-#1693 deploy script (even one
// that aborts) reinstalls its own recovery unit and guard drop-in at its step
// 1, which drops the pricing pre-start (journal restore before boot) and the
// post-start closer. Once the pricing runtime floor marker exists a pricing
// journal may exist, so running on that wiring is reported loudly at boot and
// on every SIGHUP. It is never a refusal: refusing to start would turn an
// aborted old deploy into an outage. The fix is to re-run the enabling deploy
// (docs/runbooks/catalog-release-decision-tree.md, runtime floor rule).
var (
	pricingRecoveryUnitPath   = "/etc/systemd/system/macprovider-coordinator-deploy-recovery.service"
	pricingGuardDropInPath    = "/etc/systemd/system/macprovider-coordinator.service.d/10-deploy-transaction-guard.conf"
	pricingRuntimeFloorMarker = ".pricing-runtime-floor"
)

const (
	pricingPreStartLine = "ExecStart=/usr/bin/python3 -I /opt/macprovider/coordinator-pricing-recover --pre-start"
	pricingCloserLine   = "Wants=macprovider-coordinator-pricing-close.service"
)

func unitHasLine(path, want string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if strings.TrimSpace(sc.Text()) == want {
			return true, nil
		}
	}
	return false, sc.Err()
}

// pricingRecoveryWiringProblems returns nil when no pricing runtime floor
// marker exists beside the base config, or when the recovery unit carries the
// pricing pre-start and the guard drop-in wants the closer.
func pricingRecoveryWiringProblems(configDir string) []string {
	if _, err := os.Lstat(filepath.Join(configDir, pricingRuntimeFloorMarker)); errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	var problems []string
	for _, c := range []struct{ path, line, what string }{
		{pricingRecoveryUnitPath, pricingPreStartLine, "the pricing journal pre-start"},
		{pricingGuardDropInPath, pricingCloserLine, "the pricing closer"},
	} {
		ok, err := unitHasLine(c.path, c.line)
		switch {
		case err != nil:
			problems = append(problems, c.path+" is unreadable ("+err.Error()+"): cannot prove "+c.what+" is wired")
		case !ok:
			problems = append(problems, c.path+" lacks "+c.what+" ("+c.line+")")
		}
	}
	return problems
}

func checkPricingRecoveryWiring(logger zerolog.Logger, configDir string) {
	problems := pricingRecoveryWiringProblems(configDir)
	if len(problems) == 0 {
		return
	}
	logger.Error().
		Str("event", "pricing_recovery_wiring_missing").
		Strs("problems", problems).
		Str("runbook", "docs/runbooks/catalog-release-decision-tree.md §Enabling rollout and pricing (runtime floor rule)").
		Msg("pricing recovery is DISABLED on this host (a pre-#1693 deploy reinstalled its recovery units); re-run the enabling deploy before any pricing transaction or restart")
}
