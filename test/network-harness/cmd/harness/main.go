// Command harness runs an internal e2e network-behavior scenario against
// a running macprovider stack (local or remote) and writes an artifact
// bundle for phase-A triage. See test/network-harness/README.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/artifact"
	"github.com/augstar/macprovider-network-harness/internal/benchmark"
	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/chaos"
	"github.com/augstar/macprovider-network-harness/internal/invariants"
	"github.com/augstar/macprovider-network-harness/internal/metrics"
	"github.com/augstar/macprovider-network-harness/internal/reconcile"
	"github.com/augstar/macprovider-network-harness/internal/runmeta"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "run":
		if err := cmdRun(os.Args[2:]); err != nil {
			log.Printf("harness: %v", err)
			os.Exit(1)
		}
	case "-h", "--help", "help":
		usage()
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `network-harness — internal e2e scenario runner

usage:
  harness run <scenario.yaml> --out <dir>

flags (for "run"):
  --out string     output directory for artifact bundle (required)
  --dry-run        validate scenario YAML and exit without firing requests

exit codes:
  0   scenario completed, all hard invariants passed
  1   runtime error (cannot reach gateway, malformed scenario, etc.)
  2   usage error
  10  scenario completed but one or more hard invariants failed

The harness is descriptive in phase A: it does not assert routing/priority
behavior beyond the 4 hard invariants (billing reconciliation, no orphan
5xx, no overcharge, no silent hang). Triage the artifact bundle to decide
what to codify in the routing-contract addendum.
`)
}

func cmdRun(args []string) error {
	// Separate the positional scenario path from flags so users can
	// write either order: `run scenarios/foo.yaml --out dir` or
	// `run --out dir scenarios/foo.yaml`. Stdlib flag.Parse requires
	// flags-first, which is a UX trap.
	flagsOnly, positionals := splitFlagsAndPositionals(args)

	fs := flag.NewFlagSet("run", flag.ExitOnError)
	outDir := fs.String("out", "", "output directory for artifact bundle")
	dryRun := fs.Bool("dry-run", false, "validate scenario and exit")
	if err := fs.Parse(flagsOnly); err != nil {
		return err
	}
	if len(positionals) != 1 {
		return fmt.Errorf("expected exactly one scenario file argument; got %d", len(positionals))
	}
	scenarioPath := positionals[0]
	if *outDir == "" {
		return fmt.Errorf("--out is required")
	}

	sc, err := scenario.Load(scenarioPath)
	if err != nil {
		return fmt.Errorf("load scenario %s: %w", scenarioPath, err)
	}
	if err := sc.Validate(); err != nil {
		return fmt.Errorf("validate scenario: %w", err)
	}
	if *dryRun {
		fmt.Printf("scenario %q valid\n", sc.Name)
		return nil
	}

	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		return fmt.Errorf("mkdir out: %w", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	meta := runmeta.New(sc.Name, scenarioPath)

	log.Printf("scenario %q: starting %d buyers, target %s for %s (chaos events: %d)",
		sc.Name, sc.Buyers.Count, sc.Target.GatewayURL, sc.Duration, len(sc.ChaosEvents))

	var chaosRunner *chaos.Runner
	if len(sc.ChaosEvents) > 0 {
		chaosRunner = chaos.NewRunner(sc.ChaosEvents)
		chaosRunner.Start(ctx)
	}

	results, err := buyer.Run(ctx, sc)
	if err != nil {
		return fmt.Errorf("buyer run: %w", err)
	}
	log.Printf("scenario %q: completed %d requests", sc.Name, len(results))
	if chaosRunner != nil {
		chaosRunner.Wait()
	}

	meta.Finish()

	summary := metrics.Aggregate(results)

	var ledger *reconcile.Result
	hasLocalDBs := sc.Target.CoordinatorDBPath != "" && sc.Target.GatewayDBPath != ""
	hasRemoteDBs := sc.Target.CoordinatorDBSSH != "" && sc.Target.GatewayDBSSH != ""
	switch {
	case hasLocalDBs || hasRemoteDBs:
		// Money-path gate: when DBs are configured, the harness asked
		// for reconciliation. If reconcile.Run errors (DB schema
		// mismatch, snapshot fetch failure, etc.) we must NOT silently
		// produce a partial artifact and let invariants run with
		// ledger=nil — checkI1 would then SKIP, producing a green
		// run that hides drift. The sentinel ledger sets ReconcileError,
		// which checkI1 treats as a hard fail signal independent of
		// the per-pair drift signals.
		ledger, err = reconcile.Run(sc, results, meta.StartUTC, meta.EndUTC)
		if err != nil {
			log.Printf("reconcile: %v (failing I1 closed)", err)
			ledger = &reconcile.Result{
				DriftBasis:     "per_matched_pair_v2",
				WindowStartUTC: meta.StartUTC,
				WindowEndUTC:   meta.EndUTC,
				ReconcileError: err.Error(),
			}
		}
	default:
		log.Printf("reconcile: skipped (no coordinator_db_path/_ssh and gateway_db_path/_ssh in target)")
	}

	inv := invariants.Evaluate(sc, results, summary, ledger)

	var bench *benchmark.Result
	if sc.Benchmark.Enabled {
		var pricing *benchmark.Pricing
		if sc.Benchmark.PricingSource != "" {
			// Resolve local pricing paths relative to the scenario YAML
			// dir, so `pricing_source: specs/PRICING.json` works regardless
			// of harness invocation CWD. SSH specs ("host:/path") and
			// absolute paths pass through unchanged.
			pricingPath := resolvePricingPath(sc.Benchmark.PricingSource, scenarioPath)
			p, perr := benchmark.LoadPricing(pricingPath)
			if perr != nil {
				log.Printf("benchmark: pricing load failed (%v) — B6 will SKIP", perr)
			} else {
				pricing = p
				if len(p.Notes) > 0 {
					log.Printf("benchmark: pricing loaded with %d skipped entries", len(p.Notes))
				}
			}
		}
		windowSec := meta.EndUTC.Sub(meta.StartUTC).Seconds()
		runID := meta.StartUTC.Format("20060102T150405Z")
		bench = benchmark.Evaluate(sc, results, summary, ledger, pricing, runID, windowSec)
	}

	var chaosResults []chaos.EventResult
	if chaosRunner != nil {
		chaosResults = chaosRunner.Results()
	}

	bundle := &artifact.Bundle{
		Scenario:     sc,
		ScenarioPath: scenarioPath,
		Results:      results,
		Summary:      summary,
		Reconcile:    ledger,
		Invariants:   inv,
		Benchmark:    bench,
		Meta:         meta,
		ChaosEvents:  chaosResults,
	}
	if err := bundle.Write(*outDir); err != nil {
		return fmt.Errorf("write artifact bundle: %w", err)
	}

	log.Printf("artifact bundle written to %s", filepath.Clean(*outDir))
	logInvariantSummary(inv)
	if bench != nil {
		logBenchmarkSummary(bench)
	}

	if inv.AnyFailed() {
		os.Exit(10)
	}
	return nil
}

// splitFlagsAndPositionals walks args once, peeling off `--name`,
// `-name`, and their attached values into flagsOnly. Everything else
// is positional. Recognizes both `--out=dir` and `--out dir` forms.
// Boolean flags use a small allowlist (must be kept in sync with cmdRun).
func splitFlagsAndPositionals(args []string) (flagsOnly, positionals []string) {
	boolFlags := map[string]bool{"dry-run": true}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if len(a) >= 2 && a[0] == '-' {
			flagsOnly = append(flagsOnly, a)
			name := a
			for len(name) > 0 && name[0] == '-' {
				name = name[1:]
			}
			// `--name=value` consumes nothing more.
			eq := -1
			for j := 0; j < len(name); j++ {
				if name[j] == '=' {
					eq = j
					break
				}
			}
			if eq >= 0 {
				name = name[:eq]
			}
			// String flag with separate value form: `--out dir`. Skip
			// bool-flag names.
			if eq < 0 && !boolFlags[name] && i+1 < len(args) {
				next := args[i+1]
				if len(next) == 0 || next[0] != '-' {
					flagsOnly = append(flagsOnly, next)
					i++
				}
			}
			continue
		}
		positionals = append(positionals, a)
	}
	return flagsOnly, positionals
}

func logInvariantSummary(inv *invariants.Result) {
	for _, r := range inv.Checks {
		mark := "PASS"
		if !r.Passed {
			mark = "FAIL"
		}
		log.Printf("invariant %s [%s]: %s — %s", r.ID, mark, r.Title, r.Detail)
	}
	if !inv.AnyFailed() {
		log.Printf("all %d hard invariants passed", len(inv.Checks))
		return
	}
	log.Printf("HARD INVARIANT FAILURE — triage %s", time.Now().UTC().Format(time.RFC3339))
}

// logBenchmarkSummary mirrors logInvariantSummary for the B-invariants.
// Unlike I1-I4, FAIL does not change the process exit code in v0.1 —
// the benchmark suite reports, it does not gate. Triage decides.
func logBenchmarkSummary(b *benchmark.Result) {
	for _, v := range b.Verdicts {
		log.Printf("benchmark %s [%s]: %s — %s", v.ID, v.Status, v.Title, v.Detail)
	}
}

// resolvePricingPath canonicalizes a pricing_source value:
//   - SSH spec ("host:/path") and absolute paths pass through unchanged
//   - relative local paths are resolved against the scenario YAML's directory
//
// This matches the principle of least surprise: a scenario authored with
// `pricing_source: specs/PRICING.json` works whether the harness is
// invoked from the repo root or from anywhere else.
func resolvePricingPath(source, scenarioPath string) string {
	// SSH spec: "host:/path" — has a colon but is not an absolute path.
	if !filepath.IsAbs(source) && strings.Contains(source, ":") {
		return source
	}
	if filepath.IsAbs(source) {
		return source
	}
	return filepath.Join(filepath.Dir(scenarioPath), source)
}
