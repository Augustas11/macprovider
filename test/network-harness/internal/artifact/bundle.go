// Package artifact writes the phase-A artifact bundle to disk. The
// bundle is the only persistent output of a harness run — everything
// triage decides comes from reading these files.
package artifact

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/augstar/macprovider-network-harness/internal/benchmark"
	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/chaos"
	"github.com/augstar/macprovider-network-harness/internal/invariants"
	"github.com/augstar/macprovider-network-harness/internal/metrics"
	"github.com/augstar/macprovider-network-harness/internal/reconcile"
	"github.com/augstar/macprovider-network-harness/internal/runmeta"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

type Bundle struct {
	Scenario     *scenario.Scenario
	ScenarioPath string
	Results      []buyer.Result
	Summary      *metrics.Summary
	Reconcile    *reconcile.Result
	Invariants   *invariants.Result
	Benchmark    *benchmark.Result
	Meta         *runmeta.Meta
	ChaosEvents  []chaos.EventResult
}

// Write produces:
//
//	scenario.yaml          — verbatim copy of the input
//	run_meta.json          — scenario name, UTC window, git sha
//	per_request.jsonl      — one row per request (the raw evidence)
//	metrics_summary.json   — aggregated histograms + route distribution
//	ledger_reconcile.json  — three-way diff (omitted when skipped)
//	invariants.json        — the 4 hard verdicts
func (b *Bundle) Write(outDir string) error {
	if err := copyFile(b.ScenarioPath, filepath.Join(outDir, "scenario.yaml")); err != nil {
		return fmt.Errorf("copy scenario.yaml: %w", err)
	}
	if err := writeJSON(filepath.Join(outDir, "run_meta.json"), b.Meta); err != nil {
		return err
	}
	if err := writeJSONL(filepath.Join(outDir, "per_request.jsonl"), b.Results); err != nil {
		return err
	}
	if err := writeJSON(filepath.Join(outDir, "metrics_summary.json"), b.Summary); err != nil {
		return err
	}
	if b.Reconcile != nil {
		if err := writeJSON(filepath.Join(outDir, "ledger_reconcile.json"), b.Reconcile); err != nil {
			return err
		}
	}
	if err := writeJSON(filepath.Join(outDir, "invariants.json"), b.Invariants); err != nil {
		return err
	}
	if b.Benchmark != nil && b.Benchmark.Summary != nil {
		if err := writeJSON(filepath.Join(outDir, "benchmark_summary.json"), b.Benchmark.Summary); err != nil {
			return err
		}
		if err := writeJSON(filepath.Join(outDir, "benchmark_verdict.json"), b.Benchmark.Verdicts); err != nil {
			return err
		}
	}
	if len(b.ChaosEvents) > 0 {
		if err := writeJSON(filepath.Join(outDir, "chaos_events.json"), b.ChaosEvents); err != nil {
			return err
		}
	}
	return nil
}

func writeJSON(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func writeJSONL(path string, results []buyer.Result) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	for i := range results {
		if err := enc.Encode(results[i]); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}
