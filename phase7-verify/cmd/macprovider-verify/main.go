package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/augstar/macprovider/phase7-verify/internal/version"
)

const (
	defaultCoordinator = "coordinator.streamvc.live"
	exitUsage          = 64
)

type options struct {
	version     bool
	help        bool
	bundle      string
	receipt     string
	promptHash  string
	outputHash  string
	pubkey      string
	providerID  string
	json        bool
	offline     bool
	quiet       bool
	coordinator string
	explain     bool
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr, os.Getenv))
}

func run(args []string, stdout, stderr io.Writer, getenv func(string) string) int {
	opts := options{}
	coordinatorDefault := defaultCoordinator
	// TODO: Step 5 — MACPROVIDER_COORDINATOR becomes the resolver host fallback.
	if envCoordinator := getenv("MACPROVIDER_COORDINATOR"); envCoordinator != "" {
		coordinatorDefault = envCoordinator
	}

	fs := flag.NewFlagSet("macprovider-verify", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.BoolVar(&opts.version, "version", false, "print version and SPEC compatibility")
	fs.BoolVar(&opts.help, "help", false, "print usage")
	fs.StringVar(&opts.bundle, "bundle", "", "path to receipt bundle JSON, or - for stdin")
	fs.StringVar(&opts.receipt, "receipt", "", "X-MacProvider-Receipt header value")
	fs.StringVar(&opts.promptHash, "prompt-hash", "", "expected canonical prompt SHA-256 hex")
	fs.StringVar(&opts.outputHash, "output-hash", "", "expected canonical output SHA-256 hex")
	fs.StringVar(&opts.pubkey, "pubkey", "", "explicit 44-character base64 ed25519 public key")
	fs.StringVar(&opts.providerID, "provider-id", "", "provider identifier for resolver lookup")
	fs.BoolVar(&opts.json, "json", false, "emit one-line JSON output")
	fs.BoolVar(&opts.offline, "offline", false, "disable live coordinator fetches")
	fs.BoolVar(&opts.quiet, "quiet", false, "suppress stderr diagnostics and warnings")
	fs.StringVar(&opts.coordinator, "coordinator", coordinatorDefault, "coordinator host for /v1/receipt-keys")
	fs.BoolVar(&opts.explain, "explain", false, "print SPEC-015 trust-boundary explanation after valid results")

	fs.Usage = func() {
		printUsage(stdout)
	}

	if err := fs.Parse(args); err != nil {
		return exitUsage
	}

	if opts.version {
		fmt.Fprintf(stdout, "macprovider-verify %s (verifies up to SPEC-015 v%s)\n", version.BinaryVersion, version.MaxSPECVersion)
		return 0
	}
	if opts.help {
		printUsage(stdout)
		return 0
	}

	// TODO: Step 3 — parse --receipt and --pubkey values for receipt verification.
	// TODO: Step 4 — use --prompt-hash and --output-hash in canonical hash checks.
	// TODO: Step 5 — apply --provider-id, --offline, --coordinator, and cache/resolver behavior.
	// TODO: Step 6 — route --bundle inputs through the verification algorithm.
	// TODO: Step 7 — enforce CLI flag interactions, --quiet behavior, and dispatch.
	// TODO: Step 8 — emit --json output shape.
	// TODO: Step 10 — wire --explain to the final SPEC-015 trust-boundary text.
	_ = opts
	fmt.Fprintln(stderr, "TODO: Step 7 — verification dispatch is not implemented yet")
	return exitUsage
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: macprovider-verify [flags]")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Verifies SPEC-015 receipt inputs. Verification logic lands in later IMPL steps.")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Flags:")
	fmt.Fprintln(w, "  --version              print version and SPEC compatibility")
	fmt.Fprintln(w, "  --help                 print this usage")
	fmt.Fprintln(w, "  --bundle <path|->      verify a receipt bundle JSON file, or stdin with -")
	fmt.Fprintln(w, "  --receipt <value>      verify an X-MacProvider-Receipt header value")
	fmt.Fprintln(w, "  --prompt-hash <hex>    expected canonical prompt SHA-256 hex")
	fmt.Fprintln(w, "  --output-hash <hex>    expected canonical output SHA-256 hex")
	fmt.Fprintln(w, "  --pubkey <base64>      explicit 44-character base64 ed25519 public key")
	fmt.Fprintln(w, "  --provider-id <id>     provider identifier for resolver lookup")
	fmt.Fprintln(w, "  --json                 emit one-line JSON output")
	fmt.Fprintln(w, "  --offline              disable live coordinator fetches")
	fmt.Fprintln(w, "  --quiet                suppress stderr diagnostics and warnings")
	fmt.Fprintln(w, "  --coordinator <host>   coordinator host for /v1/receipt-keys")
	fmt.Fprintln(w, "  --explain              print SPEC-015 trust-boundary explanation after valid results")
}
