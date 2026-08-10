package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	_ "github.com/lib/pq"
)

func main() {
	var dsn string
	var candidateSHA string
	var minGeneratedAtRaw string
	var asOfRaw string
	var outputPath string
	var timeout time.Duration
	flag.StringVar(&dsn, "dsn", envString("STATS_AUTOTUNE_GATE_MATRIX_DSN", envString("STATS_HARDWARE_VERIFIER_DSN", "")), "Postgres DSN with stats_hardware_verifier-compatible read access")
	flag.StringVar(&candidateSHA, "candidate-catalog-sha256", envString("STATS_AUTOTUNE_GATE_MATRIX_CANDIDATE_SHA256", ""), "expected signed autotune candidate catalog SHA-256")
	flag.StringVar(&minGeneratedAtRaw, "min-generated-at", envString("STATS_AUTOTUNE_GATE_MATRIX_MIN_GENERATED_AT", ""), "minimum evidence generated_at timestamp, RFC3339")
	flag.StringVar(&asOfRaw, "as-of", envString("STATS_AUTOTUNE_GATE_MATRIX_AS_OF", ""), "maximum evidence/export timestamp, RFC3339")
	flag.StringVar(&outputPath, "output", "-", "output path, or - for stdout")
	flag.DurationVar(&timeout, "timeout", 30*time.Second, "maximum wall-clock time for the export")
	flag.Parse()

	if dsn == "" {
		fmt.Fprintln(os.Stderr, "stats-autotune-gate-matrix: -dsn or STATS_AUTOTUNE_GATE_MATRIX_DSN is required")
		os.Exit(2)
	}
	minGeneratedAt, err := parseTime(minGeneratedAtRaw, "min-generated-at")
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats-autotune-gate-matrix: %v\n", err)
		os.Exit(2)
	}
	asOf, err := parseTime(asOfRaw, "as-of")
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats-autotune-gate-matrix: %v\n", err)
		os.Exit(2)
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats-autotune-gate-matrix: open database: %v\n", err)
		os.Exit(2)
	}
	defer db.Close()
	if err := db.PingContext(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "stats-autotune-gate-matrix: database smoke failed: %v\n", err)
		os.Exit(2)
	}
	store := autotune.NewPGEvidenceStore(db)
	matrix, err := store.ExportGateMatrix(ctx, candidateSHA, minGeneratedAt, asOf)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats-autotune-gate-matrix: export failed: %v\n", err)
		os.Exit(1)
	}
	if len(matrix.Providers) == 0 {
		fmt.Fprintln(os.Stderr, "stats-autotune-gate-matrix: no verified provider evidence matched the requested catalog/cutoff")
		os.Exit(1)
	}
	if err := writeJSON(outputPath, matrix); err != nil {
		fmt.Fprintf(os.Stderr, "stats-autotune-gate-matrix: write output: %v\n", err)
		os.Exit(1)
	}
}

func parseTime(raw, label string) (time.Time, error) {
	if raw == "" {
		return time.Time{}, fmt.Errorf("%s is required", label)
	}
	parsed, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("%s must be RFC3339: %w", label, err)
	}
	return parsed.UTC(), nil
}

func writeJSON(path string, value any) error {
	var target *os.File
	if path == "-" {
		target = os.Stdout
	} else {
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
		if err != nil {
			return err
		}
		defer file.Close()
		target = file
	}
	encoder := json.NewEncoder(target)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}

func envString(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
