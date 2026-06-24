// Package cli implements the macprovider-verify command-line contract.
package cli

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/augstar/macprovider/phase7-verify/internal/cache"
	"github.com/augstar/macprovider/phase7-verify/internal/receipt"
	"github.com/augstar/macprovider/phase7-verify/internal/verify"
	"github.com/augstar/macprovider/phase7-verify/internal/version"
)

const (
	exitValid        = 0
	exitInvalid      = 1
	exitInconclusive = 2
	exitUsage        = 64
	exitDataErr      = 65
	exitSoftware     = 70

	defaultCoordinator = "coordinator.streamvc.live"
	maxCacheLineBytes  = 1 * 1024 * 1024
)

var providerIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

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
	// SPEC-015 v0.3 §M.3.1 catalog flags.
	catalog           string // path to local signed catalog
	catalogURL        string // remote catalog URL
	catalogPubkey     string // base64.RawURLEncoding catalog pubkey
	catalogPubkeyURL  string // remote pubkey URL
	requireModelHash  bool   // §M.3.1.2 fail-closed on null model_hash
}

type runConfig struct {
	httpClient *http.Client
	cache      *cache.Cache
	now        func() time.Time
}

type bundleInput struct {
	BundleVersion *int           `json:"bundle_version"`
	Receipt       string         `json:"receipt"`
	Request       map[string]any `json:"request"`
	Response      map[string]any `json:"response"`
	ProviderID    *string        `json:"provider_id"`
}

type cliUsageError struct{ err error }
type cliInputFormatError struct{ err error }

func (e *cliUsageError) Error() string       { return "usage error: " + e.err.Error() }
func (e *cliInputFormatError) Error() string { return "input format error: " + e.err.Error() }

// Run parses CLI flags, executes verification, writes output, and returns the
// process exit code.
func Run(args []string, stdin io.Reader, stdout io.Writer, stderr io.Writer, getenv func(string) string) (exit int) {
	return run(args, stdin, stdout, stderr, getenv, runConfig{})
}

func run(args []string, stdin io.Reader, stdout io.Writer, stderr io.Writer, getenv func(string) string, cfg runConfig) (exit int) {
	defer func() {
		if recover() != nil {
			fmt.Fprintln(stderr, "internal error")
			exit = exitSoftware
		}
	}()

	opts, err := parseOptions(args, stdout, stderr, getenv)
	if err != nil {
		writeErr(stderr, false, err)
		return exitUsage
	}
	if opts.help {
		printUsage(stdout)
		return exitValid
	}
	if opts.version {
		fmt.Fprintf(stdout, "macprovider-verify %s (verifies up to SPEC-015 v%s)\n", version.BinaryVersion, version.MaxSPECVersion)
		return exitValid
	}

	input, verifyOpts, err := optionsToVerifyArgs(opts, stdin, getenv, cfg)
	if err != nil {
		writeErr(stderr, opts.quiet, err)
		return exitForError(err)
	}

	result, err := verify.Verify(input, verifyOpts)
	if err != nil {
		writeErr(stderr, opts.quiet, err)
		return exitForError(err)
	}

	if err := emitResult(stdout, result, opts.json); err != nil {
		writeErr(stderr, opts.quiet, err)
		return exitSoftware
	}
	if !opts.quiet {
		renderWarningsToStderr(stderr, result.Warnings)
	}
	if opts.explain && !opts.quiet && result.Result == "valid" {
		fmt.Fprintln(stderr, explainText)
	}
	return exitForResult(result)
}

func parseOptions(args []string, stdout, stderr io.Writer, getenv func(string) string) (options, error) {
	opts := options{coordinator: defaultCoordinator}
	if envCoordinator := getenv("MACPROVIDER_COORDINATOR"); envCoordinator != "" {
		opts.coordinator = envCoordinator
	}

	fs := flag.NewFlagSet("macprovider-verify", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.BoolVar(&opts.version, "version", false, "print version")
	fs.BoolVar(&opts.help, "help", false, "print usage")
	fs.StringVar(&opts.bundle, "bundle", "", "path to receipt bundle JSON, or - for stdin")
	fs.StringVar(&opts.receipt, "receipt", "", "X-MacProvider-Receipt header value")
	fs.StringVar(&opts.promptHash, "prompt-hash", "", "expected canonical prompt SHA-256 hex")
	fs.StringVar(&opts.outputHash, "output-hash", "", "expected canonical output SHA-256 hex")
	fs.StringVar(&opts.pubkey, "pubkey", "", "explicit base64 ed25519 public key")
	fs.StringVar(&opts.providerID, "provider-id", "", "provider identifier for resolver lookup")
	fs.BoolVar(&opts.json, "json", false, "emit one-line JSON output")
	fs.BoolVar(&opts.offline, "offline", false, "disable live coordinator fetches")
	fs.BoolVar(&opts.quiet, "quiet", false, "suppress stderr diagnostics and warnings")
	fs.StringVar(&opts.coordinator, "coordinator", opts.coordinator, "coordinator host for /v1/receipt-keys")
	fs.BoolVar(&opts.explain, "explain", false, "print SPEC-015 trust-boundary explanation after valid results")
	// SPEC-015 v0.3 §M.3.1 catalog flags.
	fs.StringVar(&opts.catalog, "catalog", "", "path to local signed catalog file (mutually exclusive with --catalog-url)")
	fs.StringVar(&opts.catalogURL, "catalog-url", "", "URL to fetch signed catalog (mutually exclusive with --catalog; incompatible with --offline)")
	fs.StringVar(&opts.catalogPubkey, "catalog-pubkey", "", "base64.RawURLEncoding (43 ASCII chars) ed25519 catalog signing pubkey")
	fs.StringVar(&opts.catalogPubkeyURL, "catalog-pubkey-url", "", "URL to fetch the catalog signing pubkey (incompatible with --offline)")
	fs.BoolVar(&opts.requireModelHash, "require-model-hash", false, "§M.3.1.2: fail-closed (exit 1) when receipt model_hash is null")
	fs.Usage = func() { printUsage(stdout) }

	if err := fs.Parse(args); err != nil {
		return opts, &cliUsageError{err: err}
	}
	if fs.NArg() == 1 && fs.Arg(0) == "-" && opts.bundle == "" {
		opts.bundle = "-"
	} else if fs.NArg() != 0 {
		return opts, &cliUsageError{err: fmt.Errorf("unexpected positional argument %q", fs.Arg(0))}
	}
	_ = stderr
	return opts, nil
}

func optionsToVerifyArgs(opts options, stdin io.Reader, getenv func(string) string, cfg runConfig) (verify.VerifyInput, verify.VerifyOpts, error) {
	if opts.bundle != "" && opts.receipt != "" {
		return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: errors.New("--bundle and --receipt are mutually exclusive")}
	}

	pubkey, err := parseOptionalPubkey(opts.pubkey)
	if err != nil {
		return verify.VerifyInput{}, verify.VerifyOpts{}, err
	}
	if opts.providerID != "" && !providerIDPattern.MatchString(opts.providerID) {
		return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: fmt.Errorf("--provider-id must match ^[A-Za-z0-9_-]+$")}
	}

	var input verify.VerifyInput
	var bundleProviderID string
	switch {
	case opts.bundle != "":
		bundle, err := readBundle(opts.bundle, stdin)
		if err != nil {
			return verify.VerifyInput{}, verify.VerifyOpts{}, err
		}
		input.Header = bundle.Receipt
		input.Request = bundle.Request
		input.Response = bundle.Response
		if bundle.ProviderID != nil {
			bundleProviderID = *bundle.ProviderID
		}
		if bundleProviderID != "" && !providerIDPattern.MatchString(bundleProviderID) {
			return verify.VerifyInput{}, verify.VerifyOpts{}, &cliInputFormatError{err: errors.New("bundle provider_id has invalid format")}
		}
		if opts.providerID != "" && bundleProviderID != "" && opts.providerID != bundleProviderID {
			return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: errors.New("--provider-id does not match bundle provider_id")}
		}
	case opts.receipt != "":
		if opts.promptHash == "" || opts.outputHash == "" {
			return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: errors.New("--prompt-hash and --output-hash are required with --receipt")}
		}
		promptHash, err := parseHashFlag("--prompt-hash", opts.promptHash)
		if err != nil {
			return verify.VerifyInput{}, verify.VerifyOpts{}, err
		}
		outputHash, err := parseHashFlag("--output-hash", opts.outputHash)
		if err != nil {
			return verify.VerifyInput{}, verify.VerifyOpts{}, err
		}
		input.Header = opts.receipt
		input.ExplicitPromptHash = promptHash
		input.ExplicitOutputHash = outputHash
	default:
		return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: errors.New("one of --bundle or --receipt is required")}
	}
	input.ExplicitPubkey = pubkey

	c, err := cacheForRun(cfg)
	if err != nil {
		return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: err}
	}
	coordinatorHost := opts.coordinator
	resolvedProviderID, resolutionErr, err := resolveProviderID(opts.providerID, bundleProviderID, input.Header, coordinatorHost, c)
	if err != nil {
		return verify.VerifyInput{}, verify.VerifyOpts{}, err
	}
	if resolvedProviderID == "" && len(pubkey) == 0 {
		return verify.VerifyInput{}, verify.VerifyOpts{}, &cliUsageError{err: missingProviderIDError(resolutionErr)}
	}
	input.ProviderID = resolvedProviderID

	catalogOpts, err := buildCatalogOpts(opts)
	if err != nil {
		return verify.VerifyInput{}, verify.VerifyOpts{}, err
	}

	verifyOpts := verify.VerifyOpts{
		Offline:          opts.offline,
		Quiet:            opts.quiet,
		CoordinatorHost:  coordinatorHost,
		Cache:            c,
		Now:              cfg.now,
		HTTPClient:       cfg.httpClient,
		Catalog:          catalogOpts,
		RequireModelHash: opts.requireModelHash,
	}
	return input, verifyOpts, nil
}

// SPEC-015 §M.3.1 flag-combination validation. Returns the
// catalog options bundle plus any usage error.
func buildCatalogOpts(opts options) (verify.CatalogOpts, error) {
	var co verify.CatalogOpts
	hasCatalog := opts.catalog != "" || opts.catalogURL != ""
	hasPubkey := opts.catalogPubkey != "" || opts.catalogPubkeyURL != ""

	// Mutually-exclusive sources.
	if opts.catalog != "" && opts.catalogURL != "" {
		return co, &cliUsageError{err: errors.New("--catalog and --catalog-url are mutually exclusive")}
	}
	if opts.catalogPubkey != "" && opts.catalogPubkeyURL != "" {
		return co, &cliUsageError{err: errors.New("--catalog-pubkey and --catalog-pubkey-url are mutually exclusive")}
	}

	// SPEC-015 §M.3.1 — catalog without pubkey (or vice versa) is exit 64.
	if hasCatalog && !hasPubkey {
		return co, &cliUsageError{err: errors.New("--catalog/--catalog-url requires --catalog-pubkey or --catalog-pubkey-url")}
	}
	if hasPubkey && !hasCatalog {
		return co, &cliUsageError{err: errors.New("--catalog-pubkey/--catalog-pubkey-url requires --catalog or --catalog-url")}
	}

	// SPEC-015 §M.3.1.1 — --offline incompatible with URL-fetch flags.
	if opts.offline && (opts.catalogURL != "" || opts.catalogPubkeyURL != "") {
		return co, &cliUsageError{err: errors.New("--catalog-url and --catalog-pubkey-url are incompatible with --offline")}
	}

	if opts.catalog != "" {
		co.Path = opts.catalog
	}
	if opts.catalogURL != "" {
		co.URL = opts.catalogURL
	}
	if opts.catalogPubkey != "" {
		decoded, err := base64.RawURLEncoding.DecodeString(opts.catalogPubkey)
		if err != nil {
			return co, &cliUsageError{err: fmt.Errorf("--catalog-pubkey not base64.RawURLEncoding: %v", err)}
		}
		if len(decoded) != ed25519.PublicKeySize {
			return co, &cliUsageError{err: fmt.Errorf("--catalog-pubkey decoded length %d, want %d", len(decoded), ed25519.PublicKeySize)}
		}
		co.Pubkey = decoded
	}
	if opts.catalogPubkeyURL != "" {
		co.PubkeyURL = opts.catalogPubkeyURL
	}
	co.Enabled = hasCatalog && hasPubkey
	return co, nil
}

func readBundle(path string, stdin io.Reader) (*bundleInput, error) {
	var raw []byte
	var err error
	if path == "-" {
		raw, err = io.ReadAll(stdin)
	} else {
		raw, err = os.ReadFile(path)
	}
	if err != nil {
		return nil, &cliInputFormatError{err: fmt.Errorf("read bundle: %w", err)}
	}
	var bundle bundleInput
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decoder.UseNumber()
	if err := decoder.Decode(&bundle); err != nil {
		return nil, &cliInputFormatError{err: fmt.Errorf("decode bundle JSON: %w", err)}
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, &cliInputFormatError{err: errors.New("bundle JSON contains trailing data")}
	}
	if bundle.BundleVersion == nil || *bundle.BundleVersion != 1 {
		return nil, &cliInputFormatError{err: errors.New("bundle_version must be integer 1")}
	}
	if bundle.Receipt == "" {
		return nil, &cliInputFormatError{err: errors.New("bundle receipt is required")}
	}
	if bundle.Request == nil {
		return nil, &cliInputFormatError{err: errors.New("bundle request is required")}
	}
	if bundle.Response == nil {
		return nil, &cliInputFormatError{err: errors.New("bundle response is required")}
	}
	return &bundle, nil
}

func parseOptionalPubkey(raw string) ([]byte, error) {
	if raw == "" {
		return nil, nil
	}
	pubkey, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, &cliUsageError{err: fmt.Errorf("--pubkey must be base64: %w", err)}
	}
	if len(pubkey) != 32 {
		return nil, &cliUsageError{err: fmt.Errorf("--pubkey must decode to 32 bytes, got %d", len(pubkey))}
	}
	return pubkey, nil
}

func parseHashFlag(name, raw string) ([]byte, error) {
	decoded, err := hex.DecodeString(raw)
	if err != nil || len(decoded) != 32 || strings.ToLower(raw) != raw {
		return nil, &cliUsageError{err: fmt.Errorf("%s must be 64 lowercase hex characters", name)}
	}
	return decoded, nil
}

func cacheForRun(cfg runConfig) (*cache.Cache, error) {
	if cfg.cache != nil {
		return cfg.cache, nil
	}
	return cache.Open("")
}

func resolveProviderID(cliProviderID, bundleProviderID, header, coordinatorHost string, c *cache.Cache) (string, error, error) {
	if cliProviderID != "" {
		return cliProviderID, nil, nil
	}
	if bundleProviderID != "" {
		return bundleProviderID, nil, nil
	}
	parsed, err := receipt.Parse(header)
	if err != nil {
		return "", nil, &verify.InputFormatError{Err: err}
	}
	pubkey, err := receipt.ParsePubkey(parsed.Tuple.ProviderPubkey)
	if err != nil {
		return "", nil, &verify.InputFormatError{Err: err}
	}
	providerID, err := singleMatchProviderIDFromCache(c, normalizedCoordinatorHost(coordinatorHost), pubkey)
	return providerID, err, nil
}

func missingProviderIDError(resolutionErr error) error {
	message := "--provider-id is required when no bundle provider_id or single-match cache entry is available"
	if resolutionErr != nil {
		return fmt.Errorf("%s (single-match resolution failed: %v)", message, resolutionErr)
	}
	return errors.New(message)
}

func singleMatchProviderIDFromCache(c *cache.Cache, coordinatorHost string, pubkey []byte) (string, error) {
	if c == nil || c.Path() == "" {
		return "", nil
	}
	file, err := os.Open(c.Path())
	if errors.Is(err, os.ErrNotExist) || err != nil {
		return "", nil
	}
	defer file.Close()

	matches := map[string]bool{}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), maxCacheLineBytes)
	for scanner.Scan() {
		var entry struct {
			CoordinatorHost string `json:"coordinator_host"`
			ProviderID      string `json:"provider_id"`
			ReceiptPubkey   string `json:"receipt_pubkey"`
		}
		if err := json.Unmarshal(bytes.TrimSpace(scanner.Bytes()), &entry); err != nil {
			continue
		}
		decoded, err := base64.StdEncoding.DecodeString(entry.ReceiptPubkey)
		if err != nil {
			continue
		}
		if entry.CoordinatorHost == coordinatorHost && bytes.Equal(decoded, pubkey) && entry.ProviderID != "" {
			matches[entry.ProviderID] = true
		}
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	if len(matches) != 1 {
		return "", nil
	}
	for providerID := range matches {
		return providerID, nil
	}
	return "", nil
}

func normalizedCoordinatorHost(raw string) string {
	if raw == "" {
		return defaultCoordinator
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return raw
	}
	return parsed.Host
}

func emitResult(stdout io.Writer, result verify.Result, asJSON bool) error {
	if asJSON {
		data, err := renderJSON(result)
		if err != nil {
			return err
		}
		_, err = stdout.Write(data)
		return err
	}
	_, err := fmt.Fprint(stdout, renderHuman(result))
	return err
}

func exitForResult(result verify.Result) int {
	switch result.Result {
	case "valid":
		return exitValid
	case "invalid":
		return exitInvalid
	case "inconclusive":
		return exitInconclusive
	default:
		return exitSoftware
	}
}

func exitForError(err error) int {
	var usageErr *verify.UsageError
	var formatErr *verify.InputFormatError
	var cliUsage *cliUsageError
	var cliFormat *cliInputFormatError
	switch {
	case errors.As(err, &usageErr), errors.As(err, &cliUsage):
		return exitUsage
	case errors.As(err, &formatErr), errors.As(err, &cliFormat):
		return exitDataErr
	default:
		return exitSoftware
	}
}

func writeErr(stderr io.Writer, quiet bool, err error) {
	if quiet || err == nil {
		return
	}
	fmt.Fprintln(stderr, err)
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: macprovider-verify [flags]")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "Flags:")
	fmt.Fprintln(w, "  --version              print version")
	fmt.Fprintln(w, "  --help                 print this usage")
	fmt.Fprintln(w, "  --bundle <path|->      verify a receipt bundle JSON file, or stdin with -")
	fmt.Fprintln(w, "  --receipt <value>      verify an X-MacProvider-Receipt header value")
	fmt.Fprintln(w, "  --prompt-hash <hex>    expected canonical prompt SHA-256 hex")
	fmt.Fprintln(w, "  --output-hash <hex>    expected canonical output SHA-256 hex")
	fmt.Fprintln(w, "  --pubkey <base64>      explicit base64 ed25519 public key")
	fmt.Fprintln(w, "  --provider-id <id>     provider identifier for resolver lookup")
	fmt.Fprintln(w, "  --json                 emit one-line JSON output")
	fmt.Fprintln(w, "  --offline              disable live coordinator fetches")
	fmt.Fprintln(w, "  --quiet                suppress stderr diagnostics and warnings")
	fmt.Fprintln(w, "  --coordinator <host>   coordinator host for /v1/receipt-keys")
	fmt.Fprintln(w, "  --explain              print SPEC-015 trust-boundary explanation after valid results")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "SPEC-015 v0.3 catalog flags (§M.3.1 / §M.3.1.2):")
	fmt.Fprintln(w, "  --catalog <path>             local signed catalog file (mutually exclusive with --catalog-url)")
	fmt.Fprintln(w, "  --catalog-url <url>          URL to fetch signed catalog (incompatible with --offline)")
	fmt.Fprintln(w, "  --catalog-pubkey <b64url>    base64url-unpadded ed25519 catalog signing pubkey (43 ASCII chars)")
	fmt.Fprintln(w, "  --catalog-pubkey-url <url>   URL to fetch the catalog signing pubkey (incompatible with --offline)")
	fmt.Fprintln(w, "  --require-model-hash         fail-closed (exit 1) when receipt model_hash is null (§M.3.1.2)")
}

const explainText = `A ` + "`valid`" + ` result from ` + "`macprovider verify`" + ` proves **exactly this**:
a holder of the provider's private key signed a canonical tuple
containing the values (` + "`model_id`" + `, ` + "`prompt_hash`" + `, ` + "`output_hash`" + `,
` + "`provider_pubkey`" + `, ` + "`ttft_ms`" + `, ` + "`tokens_out`" + `, ` + "`unix_ts`" + `), AND the
pubkey that signature checks against is the one the coordinator
publishes for the resolved ` + "`provider_id`" + ` at verification time (or
was within the §7.5.2 rotation grace window per §10.2.1).

The phrasing "signed a tuple containing ` + "`unix_ts`" + `" is deliberate:
the signature commits the holder of the private key to the claimed
timestamp value, but does NOT prove that value reflects the real
wall-clock time at signing. The signed-at attestation is about
content, not chronology.

A ` + "`valid`" + ` result DOES NOT prove:

- **That the response was generated by the model named in
  ` + "`model_id`" + `.** Model-hash binding is the SPEC-011 v0.5
  catalog-signing surface; folding ` + "`model_hash`" + ` into the receipt
  tuple is the v0.3+ candidate per §15 Q6. A v0.2 verifier MUST
  NOT silently treat ` + "`valid`" + ` as "model attestation."
- **That ` + "`unix_ts`" + ` is honest.** The timestamp is provider-reported.
  The verifier MAY optionally cross-check against a buyer-recorded
  received-at timestamp with an operator-set skew window, but v0.2
  does NOT require this check (see §15 Q4), and a ` + "`valid`" + ` result
  without skew-check does NOT attest to timestamp honesty.
- **That no other party also saw the response.** Privacy
  properties are SPEC-008 / Cluster E territory and are orthogonal
  to receipt verification. A receipt with ` + "`valid`" + ` says nothing
  about whether the operator, the coordinator, the gateway, or
  another buyer also observed the response bytes.
- **That the pubkey itself is trustworthy in some absolute sense.**
  v0.1's §8 trust root (` + "`/poolz`" + `) is operator-mutable. The v0.1
  SPEC is honest about this; v0.2 inherits that honesty without
  weakening it. The §15 Q1 stronger-trust-root work (TUF-style
  signing, on-chain anchor) is v0.3+ scope.
- **That the response was delivered to the buyer who is now
  verifying it.** A receipt commits to (prompt, output, provider);
  it does not commit to ` + "`request_id`" + ` or a buyer-supplied nonce.
  Replay-resistance is §15 Q2 (v0.2 verifier scope per the v0.1
  text, now deferred to v0.3+ — see §15 Q2 update below).
- **That this was the only receipt issued for this response.** A
  receipt does not commit to uniqueness. A provider could in
  principle issue multiple receipts for the same canonical
  (prompt, output) tuple — to different buyers, on different
  reconnects, or by re-running the same prompt. Each receipt
  independently verifies on its own merits; ` + "`valid`" + ` says nothing
  about whether another ` + "`valid`" + ` receipt also exists. This matters
  for accounting (a buyer cannot use a receipt as proof of
  sole-delivery for billing-dispute purposes) and is orthogonal
  to the replay-resistance concern above.

A ` + "`valid`" + ` result from ` + "`macprovider verify`" + ` is therefore a narrow,
specific proof: cryptographic evidence that some holder of the
provider's signing key — which the coordinator currently endorses
— attests to having produced this (prompt → output) mapping. It
is necessary for verifiable inference. It is not sufficient.
SPEC-015 v0.3+ closes the remaining gaps (model attestation,
timestamp honesty, replay resistance, stronger trust root) in
priority order determined by audit-loop and operator demand.

A verifier's human-mode output line for ` + "`valid`" + ` SHOULD frame this
scope visibly — e.g. by including the phrase ` + "`signed by m1-anon`" + `
rather than ` + "`verified m1-anon`" + `. The ` + "`--explain`" + ` flag of §10.4.2
exists precisely to make this trust boundary unmissable to a
buyer who is about to act on a ` + "`valid`" + ` result.

**SPEC-015 v0.3 catalog-attested ` + "`valid`" + ` results.** When ` + "`macprovider verify`" + `
runs with ` + "`--catalog`" + ` (or ` + "`--catalog-url`" + `) and the receipt carries a
non-null ` + "`model_hash`" + `, a ` + "`valid`" + ` result with ` + "`model_hash_verified: true`" + ` ALSO
attests that the loaded weights matched the catalog's expected SHA-256 for the
requested ` + "`model_id`" + `. This closes the §10.6 "DOES NOT prove that the
response was generated by the model named in ` + "`model_id`" + `" disclaimer for v0.3
catalog-valid results. Subject to: the buyer trusting the catalog signing
pubkey (which is the new trust root v0.3 verifier requires); the catalog being
non-expired (60-second skew grace per §M.3.2 step 5); and the operator not
substituting both catalog AND catalog pubkey simultaneously (§M.3.3 inherits
§8.3 operator-mutability). The other §10.6 disclaimers (timestamp honesty,
no-other-observer, no-uniqueness, replay-resistance) are PRESERVED.

When ` + "`model_hash_verified`" + ` is ` + "`null`" + `, the catalog check did NOT run
(no catalog flags supplied, receipt is legacy v0.1/v0.2, or receipt
` + "`model_hash`" + ` is null per §M.2.3 warm-swap-disabled providers). In that case
the v0.2 trust boundary above applies in full and the v0.3 model-hash claim
is not made.

When you supply ` + "`--pubkey`" + ` AND a custom ` + "`--coordinator`" + `, the explicit
pubkey is the trust root regardless of what the coordinator publishes. A
divergence between your ` + "`--pubkey`" + ` and the coordinator's published pubkey
for the same ` + "`provider_id`" + ` is recorded as the warning
` + "`explicit_vs_live_divergence`" + ` but does NOT change the verification result
— the explicit pubkey wins. If you need to act on disagreement, parse the JSON
output's ` + "`warnings[]`" + ` array; checking the exit code alone is not enough in
this configuration.`
