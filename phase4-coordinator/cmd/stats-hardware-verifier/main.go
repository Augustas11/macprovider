package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
)

func main() {
	var dsn string
	var limit int
	var timeout time.Duration
	flag.StringVar(&dsn, "dsn", envString("STATS_HARDWARE_VERIFIER_DSN", ""), "Postgres DSN for stats_hardware_verifier")
	flag.IntVar(&limit, "limit", envInt("STATS_HARDWARE_VERIFIER_LIMIT", 100), "maximum pending jobs to process in one run")
	flag.DurationVar(&timeout, "timeout", 30*time.Second, "maximum wall-clock time for one verification pass")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	store, err := hardwareverify.Open(dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats-hardware-verifier: %v\n", err)
		os.Exit(2)
	}
	defer store.Close()
	if err := store.Smoke(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "stats-hardware-verifier smoke failed: %v\n", err)
		os.Exit(2)
	}
	processed, err := store.ProcessPending(ctx, limit)
	if err != nil {
		fmt.Fprintf(os.Stderr, "stats-hardware-verifier process failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("stats-hardware-verifier: verified=%d rejected=%d waiting=%d\n", processed.Verified, processed.Rejected, processed.Waiting)
}

func envString(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed <= 0 {
		return fallback
	}
	return parsed
}
