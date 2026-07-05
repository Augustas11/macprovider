package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/augstar/macprovider-coordinator/internal/stats/billingmirror"
)

func main() {
	var opts billingmirror.Options
	flag.StringVar(&opts.SQLitePath, "sqlite", "", "SQLite coordinator DB path; defaults to STATS_BILLING_MIRROR_SQLITE or /var/lib/macprovider/request-log.sqlite")
	flag.StringVar(&opts.PostgresDSN, "dsn", "", "Postgres DSN; defaults to STATS_BILLING_MIRROR_DSN")
	flag.IntVar(&opts.BatchSize, "batch-size", billingmirror.DefaultBatchSize, "maximum request-credit rows to fetch per batch")
	flag.Int64Var(&opts.OverlapRows, "overlap-rows", billingmirror.DefaultOverlapRows, "number of recent SQLite row IDs to re-read every run")
	flag.IntVar(&opts.SweepRows, "sweep-rows", 0, "historical primary-key sweep rows to refresh per run; defaults to batch-size")
	flag.IntVar(&opts.MaxBatches, "max-batches", 5, "maximum new-row batches to process per run")
	flag.BoolVar(&opts.EnsureSchema, "ensure-schema", true, "create/upgrade the narrow Postgres mirror schema before syncing")
	flag.BoolVar(&opts.DryRun, "dry-run", false, "read SQLite and print counts without writing Postgres")
	flag.Parse()
	opts.Stdout = os.Stdout

	if _, err := billingmirror.Run(context.Background(), opts); err != nil {
		fmt.Fprintf(os.Stderr, "stats-billing-mirror: %v\n", err)
		os.Exit(1)
	}
}
