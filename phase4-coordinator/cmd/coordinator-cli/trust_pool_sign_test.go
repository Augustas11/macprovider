package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	_ "modernc.org/sqlite"
)

type signFixture struct {
	dir      string
	keys     string
	poolID   string
	custody  string
	now      time.Time
	creator  string
	approval string
}

func newSignFixture(t *testing.T) signFixture {
	t.Helper()
	dir := t.TempDir()
	keys := filepath.Join(dir, "keys")
	var out bytes.Buffer
	if err := trustPoolAdmin([]string{"keygen", "--out-dir", keys,
		"--manifest-authority-key-id", "m1-manifest-authority-1",
		"--policy-signer-key-id", "m1-policy-signer-1"}, os.Getenv, nil, &out); err != nil {
		t.Fatalf("keygen: %v", err)
	}
	poolID := outputField(t, out.String(), "pool_id")
	custody := filepath.Join(dir, "custody.json")
	if err := os.WriteFile(custody, []byte(`{"class":"software","description":"operator Mac, encrypted volume, owner-only files"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return signFixture{dir: dir, keys: keys, poolID: poolID, custody: custody, now: time.Now().UTC(),
		creator: "acct-m1-ops", approval: "approval-m1-v1"}
}

func outputField(t *testing.T, out, key string) string {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if v, ok := strings.CutPrefix(line, key+"="); ok {
			return v
		}
	}
	t.Fatalf("output has no %s= line:\n%s", key, out)
	return ""
}

func (f signFixture) rootArgs(nonce, expiry, out string) []string {
	return []string{"sign-root",
		"--identity", filepath.Join(f.keys, trustPoolIdentityFile),
		"--root-issuer-key", filepath.Join(f.keys, trustPoolRootIssuerKeyFile),
		"--root-issuer-key-id", "m1-root-issuer-1",
		"--operation-id", "m1-root-1",
		"--creator-account-id", f.creator,
		"--approval-record-id", f.approval,
		"--approval-version", "approval-version-1",
		"--launch-environment", "candidate",
		"--custody-disclosure", f.custody,
		"--custody-class", "software",
		"--display-name", "Malibu M1 operator pool",
		"--nonce", nonce,
		"--nonce-expiry", expiry,
		"--out", out,
	}
}

func (f signFixture) manifestArgs(op, out string, notBefore, expiresAt time.Time) []string {
	return []string{"sign-manifest",
		"--identity", filepath.Join(f.keys, trustPoolIdentityFile),
		"--root-issuer-key", filepath.Join(f.keys, trustPoolRootIssuerKeyFile),
		"--root-issuer-key-id", "m1-root-issuer-1",
		"--manifest-authority-key", filepath.Join(f.keys, trustPoolManifestAuthorityKeyFile),
		"--policy-signer-key", filepath.Join(f.keys, trustPoolPolicySignerKeyFile),
		"--operation-id", op,
		"--encoding", "2",
		"--signer-set-version", "1",
		"--settlement-mode", "enforce",
		"--runtime-allowlist", "llamacpp_loopback",
		"--models", "mlx-community/Llama-3.2-3B-Instruct-4bit",
		"--min-binary-version", "1.8.123",
		"--min-attestation-tier", "hardware",
		"--retention-policy-id", "standard",
		"--min-eligible-members", "1",
		"--not-before", notBefore.Format(time.RFC3339),
		"--expires-at", expiresAt.Format(time.RFC3339),
		"--out", out,
	}
}

func openSignTestStore(t *testing.T) *trustpool.Store {
	t.Helper()
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "trustpool.sqlite")))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return store
}

func signTestDigest(v string) string {
	sum := sha256.Sum256([]byte(v))
	return hex.EncodeToString(sum[:])
}

func approveSignTestCreator(t *testing.T, store *trustpool.Store, f signFixture) {
	t.Helper()
	grace := f.now.Add(31 * 24 * time.Hour)
	if _, err := store.UpsertCreatorApproval(context.Background(), trustpool.CreatorApproval{
		CreatorAccountID:                  f.creator,
		ApprovalRecordID:                  f.approval,
		CurrentApprovalVersion:            "approval-version-1",
		PublicDisplayName:                 "Malibu ops",
		LegalSupportContact:               "legal@example.test",
		BillingContact:                    "billing@example.test",
		EmergencyNotificationEndpoint:     "https://example.test/emergency",
		AcknowledgedMaxResponseTime:       "15m",
		AllowedProductCategory:            "design-partner",
		DataRetentionCategory:             "standard",
		SupportOwner:                      "ops",
		AllowedLaunchEnvironment:          "candidate",
		CreatorAgreementID:                "agreement-m1",
		CreatorAgreementVersion:           "v1",
		CreatorAgreementExpiresAtUTC:      grace.Add(-time.Hour),
		CreatorAgreementGraceEndsAtUTC:    grace,
		PricingScheduleID:                 "pricing-m1",
		PricingScheduleVersion:            "v1",
		ProhibitedClaimAcknowledgmentHash: signTestDigest("claims"),
		BuyerDisclosureCommitmentHash:     signTestDigest("disclosure"),
		ApprovalCriteriaHash:              signTestDigest("criteria"),
		ApprovedBy:                        "operator-a",
		ApprovedAtUTC:                     f.now.Add(-time.Hour),
		Status:                            trustpool.CreatorStatusEnabled,
	}); err != nil {
		t.Fatalf("UpsertCreatorApproval: %v", err)
	}
}

func readSignedEvent(t *testing.T, path string) trustpool.DurableEvent {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("%s mode %04o, want 0644 (public event)", path, info.Mode().Perm())
	}
	e, err := readTrustPoolEvent(path)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

// TestTrustPoolSignRoundTripThroughDurableStore signs root and manifest events
// with the reviewed tool and appends them through the coordinator's own
// validated append path (nonce consumption, root proof of possession, online
// policy acceptance, candidate claim checks), then extends the manifest.
func TestTrustPoolSignRoundTripThroughDurableStore(t *testing.T) {
	ctx := context.Background()
	f := newSignFixture(t)
	store := openSignTestStore(t)
	approveSignTestCreator(t, store, f)
	nonce, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "m1-nonce-1",
		CreatorAccountID:       f.creator,
		ApprovalRecordID:       f.approval,
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           f.now.Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce: %v", err)
	}
	create := trustpool.DurableEvent{OperationID: "m1-create-1", TimestampUTC: f.now, EventType: trustpool.EventPoolCreated,
		PoolID: f.poolID, CreatorAccountID: f.creator, ApprovalRecordID: f.approval}
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("append pool_created: %v", err)
	}

	var out bytes.Buffer
	// The store, not the tool, is the authority on nonces: a correctly signed
	// event over a nonce the coordinator never issued is refused.
	unissuedOut := filepath.Join(f.dir, "root-unissued.json")
	unissuedArgs := f.rootArgs("nonce-never-issued", nonce.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), unissuedOut)
	if err := trustPoolAdmin(unissuedArgs, os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-root (unissued nonce): %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, readSignedEvent(t, unissuedOut)); err == nil {
		t.Fatal("store accepted a root registration over an unissued nonce")
	}

	rootOut := filepath.Join(f.dir, "root.json")
	if err := trustPoolAdmin(f.rootArgs(nonce.Nonce, nonce.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), rootOut), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-root: %v", err)
	}
	root := readSignedEvent(t, rootOut)
	if root.RootIssuerKeyID != "m1-root-issuer-1" || root.LaunchEnvironment != "candidate" ||
		root.ManifestAuthorityRootKeyID != "m1-manifest-authority-1" {
		t.Fatalf("root event ids/environment not taken from flags: %+v", root)
	}
	custodyBytes, _ := os.ReadFile(f.custody)
	if root.StructuredKeyCustodyDisclosureHash != signTestDigest(string(custodyBytes)) ||
		root.IntendedPoolDisplayNameHash != signTestDigest("Malibu M1 operator pool") {
		t.Fatalf("root event hashes do not bind the disclosure and display name")
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, root); err != nil {
		t.Fatalf("append root_issuer_registered: %v", err)
	}

	manifestOut := filepath.Join(f.dir, "manifest-v1.json")
	notBefore := f.now.Add(-time.Minute).Truncate(time.Second)
	expiresAt := notBefore.Add(30 * 24 * time.Hour)
	if err := trustPoolAdmin(f.manifestArgs("m1-manifest-1", manifestOut, notBefore, expiresAt), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest genesis: %v", err)
	}
	manifest := readSignedEvent(t, manifestOut)
	if _, _, _, err := store.AppendValidatedEvent(ctx, manifest); err != nil {
		t.Fatalf("append manifest_accepted v1: %v", err)
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[f.poolID]
	if pool == nil || pool.ManifestVersion != 1 || pool.ManifestCoreDigest != manifest.ManifestCoreDigest ||
		!pool.ManifestPolicyCoreV2 || !reflect.DeepEqual(pool.ManifestRuntimeAllowlist, []string{"llamacpp_loopback"}) ||
		pool.ManifestSettlementMode != "enforce" || pool.RootIssuer == nil || pool.RootIssuer.KeyID != "m1-root-issuer-1" {
		t.Fatalf("reconstructed pool does not carry the signed v2 manifest: %+v", pool)
	}

	// Successor: --prev extends the snapshot; the manifest authority key is
	// genesis-only and must not be needed or accepted.
	successorOut := filepath.Join(f.dir, "manifest-v2.json")
	args := f.manifestArgs("m1-manifest-2", successorOut, expiresAt, expiresAt.Add(30*24*time.Hour))
	args = withoutFlag(args, "--manifest-authority-key")
	args = append(args, "--prev", manifestOut)
	if err := trustPoolAdmin(args, os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest successor: %v", err)
	}
	successor := readSignedEvent(t, successorOut)
	if successor.ManifestVersion != 2 {
		t.Fatalf("successor manifest_version = %d, want 2", successor.ManifestVersion)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, successor); err != nil {
		t.Fatalf("append manifest_accepted v2: %v", err)
	}
	overlap := append(withoutFlag(f.manifestArgs("m1-manifest-3", filepath.Join(f.dir, "overlap.json"), notBefore, expiresAt), "--manifest-authority-key"), "--prev", successorOut)
	if err := trustPoolAdmin(overlap, os.Getenv, nil, &out); err == nil || !strings.Contains(err.Error(), "previous policy window") {
		t.Fatalf("overlapping successor window error = %v", err)
	}
}

func withoutFlag(args []string, name string) []string {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == name {
			i++
			continue
		}
		out = append(out, args[i])
	}
	return out
}

func TestTrustPoolSignRequiresEveryExplicitFlag(t *testing.T) {
	f := newSignFixture(t)
	expiry := f.now.Add(time.Hour).Format(time.RFC3339Nano)
	cases := map[string][]string{
		"sign-root": f.rootArgs("nonce-1", expiry, filepath.Join(f.dir, "root.json")),
		"sign-manifest": f.manifestArgs("m1-manifest-1", filepath.Join(f.dir, "manifest.json"),
			f.now, f.now.Add(time.Hour)),
		"keygen": {"keygen", "--out-dir", filepath.Join(f.dir, "keys2"),
			"--manifest-authority-key-id", "a-1", "--policy-signer-key-id", "p-1"},
	}
	optional := map[string]bool{"--manifest-authority-key": true}
	for sub, full := range cases {
		for i := 1; i < len(full); i += 2 {
			name := full[i]
			if optional[name] {
				continue
			}
			args := withoutFlag(full, name)
			var out bytes.Buffer
			err := trustPoolAdmin(args, os.Getenv, nil, &out)
			if err == nil || !strings.Contains(err.Error(), name) {
				t.Fatalf("%s without %s: error = %v, want it to name the flag", sub, name, err)
			}
			if out.Len() != 0 {
				t.Fatalf("%s without %s wrote output", sub, name)
			}
		}
	}
}

func TestTrustPoolKeygenProtectsPrivateKeys(t *testing.T) {
	dir := t.TempDir()
	keys := filepath.Join(dir, "keys")
	var out bytes.Buffer
	if err := trustPoolAdmin([]string{"keygen", "--out-dir", keys,
		"--manifest-authority-key-id", "a-1", "--policy-signer-key-id", "p-1"}, os.Getenv, nil, &out); err != nil {
		t.Fatalf("keygen: %v", err)
	}
	if info, err := os.Stat(keys); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("key directory mode = %v, %v; want 0700", info, err)
	}
	for _, name := range []string{trustPoolRootIssuerKeyFile, trustPoolManifestAuthorityKeyFile, trustPoolPolicySignerKeyFile} {
		path := filepath.Join(keys, name)
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("%s mode = %v, %v; want 0600", name, info, err)
		}
		raw, _ := os.ReadFile(path)
		body := strings.Join(strings.Split(strings.TrimSpace(string(raw)), "\n")[1:2], "")
		if strings.Contains(out.String(), body) {
			t.Fatalf("keygen output leaks %s material", name)
		}
	}
	identity, _ := os.ReadFile(filepath.Join(keys, trustPoolIdentityFile))
	if strings.Contains(string(identity), "PRIVATE KEY") || strings.Contains(out.String(), "PRIVATE KEY") {
		t.Fatal("identity file or output carries private key material")
	}
	var id trustPoolIdentity
	if err := json.Unmarshal(identity, &id); err != nil || id.PoolID != outputField(t, out.String(), "pool_id") {
		t.Fatalf("identity pool_id mismatch: %v", err)
	}
	if err := trustPoolAdmin([]string{"keygen", "--out-dir", keys,
		"--manifest-authority-key-id", "a-1", "--policy-signer-key-id", "p-1"}, os.Getenv, nil, &out); err == nil {
		t.Fatal("keygen overwrote an existing key directory")
	}
	if err := trustPoolAdmin([]string{"keygen", "--out-dir", filepath.Join(dir, "same"),
		"--manifest-authority-key-id", "x-1", "--policy-signer-key-id", "x-1"}, os.Getenv, nil, &out); err == nil {
		t.Fatal("keygen accepted equal authority and policy signer key ids")
	}
}

func TestTrustPoolSignRejectsUnsafeOrMismatchedInputs(t *testing.T) {
	f := newSignFixture(t)
	expiry := f.now.Add(time.Hour).Format(time.RFC3339Nano)
	rootKey := filepath.Join(f.keys, trustPoolRootIssuerKeyFile)
	run := func(args []string) error {
		var out bytes.Buffer
		return trustPoolAdmin(args, os.Getenv, nil, &out)
	}
	n := 0
	outPath := func() string { n++; return filepath.Join(f.dir, "out-"+string(rune('a'+n))+".json") }

	if err := os.Chmod(rootKey, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run(f.rootArgs("nonce-1", expiry, outPath())); err == nil || !strings.Contains(err.Error(), "owner-only") {
		t.Fatalf("group/other-readable key error = %v", err)
	}
	if err := os.Chmod(rootKey, 0o600); err != nil {
		t.Fatal(err)
	}

	link := filepath.Join(f.dir, "root-link.pem")
	if err := os.Symlink(rootKey, link); err != nil {
		t.Fatal(err)
	}
	args := f.rootArgs("nonce-1", expiry, outPath())
	args[4] = link
	if err := run(args); err == nil || !strings.Contains(err.Error(), "regular file") {
		t.Fatalf("symlinked key error = %v", err)
	}

	other := newSignFixture(t)
	args = f.rootArgs("nonce-1", expiry, outPath())
	args[4] = filepath.Join(other.keys, trustPoolRootIssuerKeyFile)
	if err := run(args); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("foreign root key error = %v", err)
	}

	args = f.rootArgs("nonce-1", expiry, outPath())
	for i := range args {
		if args[i] == "--custody-class" {
			args[i+1] = "hsm"
		}
	}
	if err := run(args); err == nil || !strings.Contains(err.Error(), "does not equal --custody-class") {
		t.Fatalf("custody class mismatch error = %v", err)
	}

	tampered := filepath.Join(f.dir, "identity-tampered.json")
	raw, _ := os.ReadFile(filepath.Join(f.keys, trustPoolIdentityFile))
	if err := os.WriteFile(tampered, bytes.Replace(raw, []byte(f.poolID), []byte(other.poolID), 1), 0o644); err != nil {
		t.Fatal(err)
	}
	args = f.rootArgs("nonce-1", expiry, outPath())
	args[2] = tampered
	if err := run(args); err == nil || !strings.Contains(err.Error(), "pool_id does not derive") {
		t.Fatalf("tampered identity error = %v", err)
	}

	existing := outPath()
	if err := os.WriteFile(existing, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := run(f.rootArgs("nonce-1", expiry, existing)); err == nil {
		t.Fatal("sign-root overwrote an existing --out file")
	}

	manifest := f.manifestArgs("m1-manifest-1", outPath(), f.now, f.now.Add(time.Hour))
	for i := range manifest {
		if manifest[i] == "--settlement-mode" {
			manifest[i+1] = "observe"
		}
	}
	if err := run(manifest); err == nil || !strings.Contains(err.Error(), "policy core") {
		t.Fatalf("non-empty runtime allowlist in observe mode error = %v", err)
	}
	v1 := f.manifestArgs("m1-manifest-1", outPath(), f.now, f.now.Add(time.Hour))
	for i := range v1 {
		if v1[i] == "--encoding" {
			v1[i+1] = "1"
		}
	}
	if err := run(v1); err == nil || !strings.Contains(err.Error(), "needs --encoding 2") {
		t.Fatalf("runtime allowlist on encoding 1 error = %v", err)
	}
}
