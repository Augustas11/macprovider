// Command fakeprov is the #1693 tier-E2 stand-in for macprovider-cli: the
// integration harness's in-process fake provider
// (test/integration/harness_test.go, type fakeProvider) as a long-lived
// process that runs against a real coordinator binary elsewhere. Test
// scaffolding only; never point it at production.
//
// Invocations:
//
//	fakeprov -coord-ws ws://HOST:PORT/ws/provider -provider-id ID -token-file F [flags]
//	fakeprov serve --config PATH
//	fakeprov autotune --recommend --apply --drain --max-duration N   (no-op, exit 0)
//
// Anything else prints usage and exits 2.
//
// serve --config file: one `key: value` per line, '#' comments, optional
// quotes around values. Keys:
//
//	port:            local status port; /v1/status is served on 127.0.0.1:<port>
//	                 (catalog-canary-proof.py reads this key) unless status_listen is set
//	coordinator_ws:  coordinator provider WS URL (required)
//	provider_id:     provider id (required); also the /v1/status provider_id
//	token_file:      file holding the provider bearer token (required)
//	http_listen:     inference listen host:port (default 127.0.0.1:18100)
//	endpoint_url:    advertised endpoint_url (default http://<http_listen>)
//	catalog_dir:     release dir with release.json + autotune-candidates.json
//	catalog_from_coordinator: coordinator buyer-mux base URL; before every WS
//	                 connect the identity is re-derived from its live
//	                 /v1/autotune-release + /v1/autotune-candidates(.sig)
//	catalog_key:     candidate row key (default meta-llama/llama-3.2-3b-instruct)
//	status_listen:   explicit host:port for /v1/status
//	settlement:      true|false, settlement receipts (default true)
//
// Flag mode catalog identity: explicit -catalog-* / -model-* flags override the
// values derived from -catalog-dir or -catalog-from-coordinator (at most one of
// the two may be set).
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultModelID    = "mlx-community/Llama-3.2-3B-Instruct-4bit"
	defaultCatalogKey = "meta-llama/llama-3.2-3b-instruct"
	defaultHTTPListen = "127.0.0.1:18100"
)

type options struct {
	coordWS         string
	providerID      string
	localProviderID string
	token           string
	tokenFile       string
	httpListen      string
	endpointURL     string
	statusListen    string
	modelID         string
	modelHash       string
	catalogDir      string
	catalogCoord    string
	catalogKey      string
	releaseID       string
	policy          string
	candidatesSHA   string
	signer          string
	rowIdentity     string
	settlement      bool
	explicit        map[string]bool
}

func logf(format string, args ...any) { log.Printf(format, args...) }

func usage() {
	fmt.Fprint(os.Stderr, `usage:
  fakeprov -coord-ws URL -provider-id ID (-token T | -token-file F) [flags]
  fakeprov serve --config PATH
  fakeprov autotune --recommend --apply --drain --max-duration N
`)
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds | log.LUTC)
	log.SetPrefix("fakeprov ")
	log.SetOutput(os.Stderr)
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var opts options
	var err error
	switch arg := os.Args[1]; {
	case arg == "serve":
		opts, err = parseServe(os.Args[2:])
	case arg == "autotune":
		os.Exit(runAutotune(os.Args[2:]))
	case strings.HasPrefix(arg, "-"):
		opts, err = parseFlags(os.Args[1:])
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "fakeprov: %v\n", err)
		usage()
		os.Exit(2)
	}
	if err := run(opts); err != nil {
		log.Fatalf("fatal: %v", err)
	}
}

func runAutotune(args []string) int {
	fs := flag.NewFlagSet("autotune", flag.ContinueOnError)
	recommend := fs.Bool("recommend", false, "")
	apply := fs.Bool("apply", false, "")
	drain := fs.Bool("drain", false, "")
	maxDuration := fs.Int("max-duration", 0, "")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		usage()
		return 2
	}
	fmt.Printf("fakeprov: autotune no-op (recommend=%t apply=%t drain=%t max-duration=%d); the fake provider serves the catalog row from its config\n",
		*recommend, *apply, *drain, *maxDuration)
	return 0
}

func parseFlags(args []string) (options, error) {
	var o options
	fs := flag.NewFlagSet("fakeprov", flag.ContinueOnError)
	fs.StringVar(&o.coordWS, "coord-ws", "", "coordinator provider WS URL, e.g. ws://127.0.0.1:8444/ws/provider")
	fs.StringVar(&o.providerID, "provider-id", "", "provider id")
	fs.StringVar(&o.localProviderID, "local-provider-id", "", "provider_id reported by /v1/status (default -provider-id)")
	fs.StringVar(&o.token, "token", "", "provider bearer token")
	fs.StringVar(&o.tokenFile, "token-file", "", "file holding the provider bearer token")
	fs.StringVar(&o.httpListen, "http-listen", defaultHTTPListen, "inference endpoint listen host:port")
	fs.StringVar(&o.endpointURL, "endpoint-url", "", "endpoint_url advertised to the coordinator (default http://<http-listen>)")
	fs.StringVar(&o.statusListen, "status-listen", "", "canary mode: serve GET /v1/status on host:port")
	fs.StringVar(&o.modelID, "model-id", defaultModelID, "served model id")
	fs.StringVar(&o.modelHash, "model-hash", "", "model hash (64 hex)")
	fs.StringVar(&o.catalogDir, "catalog-dir", "", "derive catalog identity from DIR/release.json + DIR/autotune-candidates.json")
	fs.StringVar(&o.catalogCoord, "catalog-from-coordinator", "", "coordinator buyer base URL; re-derive the catalog identity from its live feeds before every WS connect")
	fs.StringVar(&o.catalogKey, "catalog-key", defaultCatalogKey, "candidate catalog row key")
	fs.StringVar(&o.releaseID, "catalog-release-id", "", "catalog_release_id")
	fs.StringVar(&o.policy, "catalog-policy", "", "catalog_policy_version")
	fs.StringVar(&o.candidatesSHA, "catalog-sha", "", "catalog_candidate_sha256 (candidate feed sha256)")
	fs.StringVar(&o.signer, "catalog-signer", "", "catalog_signer_key_id")
	fs.StringVar(&o.rowIdentity, "catalog-row-identity", "", "catalog_row_identity (64 hex)")
	fs.BoolVar(&o.settlement, "settlement", false, "enable settlement receipts (v2 auth handshake)")
	if err := fs.Parse(args); err != nil {
		return o, err
	}
	if fs.NArg() != 0 {
		return o, fmt.Errorf("unexpected arguments: %v", fs.Args())
	}
	o.explicit = map[string]bool{}
	fs.Visit(func(f *flag.Flag) { o.explicit[f.Name] = true })
	return o, nil
}

func parseServe(args []string) (options, error) {
	o := options{httpListen: defaultHTTPListen, modelID: defaultModelID, catalogKey: defaultCatalogKey, settlement: true, explicit: map[string]bool{}}
	if len(args) != 2 || (args[0] != "--config" && args[0] != "-config") {
		return o, errors.New("serve requires exactly --config PATH")
	}
	f, err := os.Open(args[1])
	if err != nil {
		return o, err
	}
	defer f.Close()
	port := ""
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if i := strings.Index(line, "#"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			return o, fmt.Errorf("%s:%d: want key: value", args[1], n)
		}
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		switch key {
		case "port":
			port = value
		case "coordinator_ws":
			o.coordWS = value
		case "provider_id":
			o.providerID = value
		case "token_file":
			o.tokenFile = value
		case "http_listen":
			o.httpListen = value
		case "endpoint_url":
			o.endpointURL = value
		case "catalog_dir":
			o.catalogDir = value
		case "catalog_from_coordinator":
			o.catalogCoord = value
		case "catalog_key":
			o.catalogKey = value
		case "status_listen":
			o.statusListen = value
		case "settlement":
			b, err := strconv.ParseBool(value)
			if err != nil {
				return o, fmt.Errorf("%s:%d: settlement: %v", args[1], n, err)
			}
			o.settlement = b
		default:
			return o, fmt.Errorf("%s:%d: unknown key %q", args[1], n, key)
		}
	}
	if err := sc.Err(); err != nil {
		return o, err
	}
	if o.statusListen == "" && port != "" {
		if p, err := strconv.Atoi(port); err != nil || p < 1 || p > 65535 {
			return o, fmt.Errorf("invalid port %q", port)
		}
		o.statusListen = "127.0.0.1:" + port
	}
	return o, nil
}

func run(o options) error {
	if o.coordWS == "" || o.providerID == "" {
		return errors.New("coordinator WS URL and provider id are required")
	}
	if o.token == "" && o.tokenFile != "" {
		raw, err := os.ReadFile(o.tokenFile)
		if err != nil {
			return fmt.Errorf("read token file: %w", err)
		}
		o.token = strings.TrimSpace(string(raw))
	}
	if o.token == "" {
		return errors.New("provider token is required (-token or -token-file)")
	}
	if o.localProviderID == "" {
		o.localProviderID = o.providerID
	}
	if o.endpointURL == "" {
		o.endpointURL = "http://" + o.httpListen
	}
	if o.catalogDir != "" && o.catalogCoord != "" {
		return errors.New("catalog dir and catalog-from-coordinator are mutually exclusive")
	}
	// Explicit flags win over derived values.
	override := func(id catalogIdentity) catalogIdentity {
		set := func(dst *string, flagName, v string) {
			if o.explicit[flagName] || *dst == "" {
				*dst = v
			}
		}
		set(&id.ReleaseID, "catalog-release-id", o.releaseID)
		set(&id.PolicyVersion, "catalog-policy", o.policy)
		set(&id.CandidatesSHA, "catalog-sha", o.candidatesSHA)
		set(&id.SignerKeyID, "catalog-signer", o.signer)
		set(&id.RowIdentity, "catalog-row-identity", o.rowIdentity)
		set(&id.ModelHash, "model-hash", o.modelHash)
		set(&id.ModelID, "model-id", o.modelID)
		return id
	}
	id := override(catalogIdentity{})
	if o.catalogDir != "" {
		derived, err := loadCatalogDir(o.catalogDir, o.catalogKey)
		if err != nil {
			return fmt.Errorf("catalog dir %s: %w", o.catalogDir, err)
		}
		id = override(derived)
	}
	p := &fakeProvider{
		providerID:      o.providerID,
		localProviderID: o.localProviderID,
		providerToken:   o.token,
		wsURL:           o.coordWS,
		endpointURL:     o.endpointURL,
		catalogKey:      o.catalogKey,
		id:              id,
	}
	if o.catalogCoord != "" {
		p.refreshCatalog = func(ctx context.Context) (catalogIdentity, error) {
			derived, err := fetchCatalogFromCoordinator(ctx, o.catalogCoord, o.catalogKey)
			if err != nil {
				return catalogIdentity{}, err
			}
			return override(derived), nil
		}
	}
	if o.settlement {
		if err := p.enableSettlementReceipts(); err != nil {
			return err
		}
	}
	logf("config provider_id=%s ws=%s endpoint_url=%s model_id=%s model_hash=%s settlement=%t catalog{release_id=%s policy=%s sha=%s signer=%s row_identity=%s key=%s from_coordinator=%s} status_listen=%s",
		p.providerID, p.wsURL, p.endpointURL, id.ModelID, id.ModelHash, o.settlement,
		id.ReleaseID, id.PolicyVersion, id.CandidatesSHA, id.SignerKeyID, id.RowIdentity, p.catalogKey, o.catalogCoord, o.statusListen)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	servers := []*http.Server{}
	serve := func(addr string, h http.Handler, name string) error {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			return fmt.Errorf("%s listen %s: %w", name, addr, err)
		}
		srv := &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second}
		servers = append(servers, srv)
		logf("%s listening on %s", name, ln.Addr())
		go func() {
			if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Fatalf("%s serve: %v", name, err)
			}
		}()
		return nil
	}
	if err := serve(o.httpListen, p.inferenceHandler(), "inference"); err != nil {
		return err
	}
	if o.statusListen != "" {
		if err := serve(o.statusListen, p.statusHandler(), "status"); err != nil {
			return err
		}
	}

	p.runWSForever(ctx)
	logf("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	for _, srv := range servers {
		_ = srv.Shutdown(shutdownCtx)
	}
	return nil
}
