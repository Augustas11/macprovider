package main

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// Offline SPEC-042/SPEC-043 pool signing (#1690 M1 blocker B7). These three
// trust-pool-admin subcommands replace the lab-only scripts/lab/1690-m6/labtool
// pool-keygen/pool-root/pool-manifest: every key id, the launch environment,
// the custody disclosure, the signer-set version and the attestation tier are
// explicit required flags, private keys live in owner-only PEM files, and
// nothing a subcommand prints or writes contains private key material. They
// make no network request; the signed events are submitted separately with
// `append-event` / `submit-policy`.

const (
	trustPoolIdentitySchema = "macprovider.trust-pool-identity.v1"

	trustPoolRootIssuerKeyFile        = "root-issuer-key.pem"
	trustPoolManifestAuthorityKeyFile = "manifest-authority-key.pem"
	trustPoolPolicySignerKeyFile      = "policy-signer-key.pem"
	trustPoolIdentityFile             = "pool-identity.json"

	// genesis authority-log entry validity: the signer set stays valid until
	// rotated; the policy core carries the real policy window.
	trustPoolGenesisSignerSetNotBefore = 1
	trustPoolGenesisSignerSetExpiresAt = 9999999999
)

var (
	trustPoolKeyIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	// SPEC-043-R002 key_custody_disclosure.class vocabulary.
	trustPoolCustodyClasses = map[string]bool{
		trustpool.RootCustodyClassSoftware: true,
		trustpool.RootCustodyClassHSM:      true,
		trustpool.RootCustodyClassMPC:      true,
		trustpool.RootCustodyClassOther:    true,
	}
)

// trustPoolIdentity is the public half written by keygen. It carries no
// private key material; the genesis nonce is public once the first manifest
// snapshot is submitted.
type trustPoolIdentity struct {
	SchemaVersion                  string `json:"schema_version"`
	PoolID                         string `json:"pool_id"`
	GenesisNonce                   string `json:"genesis_nonce"`
	ManifestAuthorityKeyID         string `json:"manifest_authority_key_id"`
	ManifestAuthorityPublicKey     string `json:"manifest_authority_public_key"`
	PolicySignerKeyID              string `json:"policy_signer_key_id"`
	PolicySignerPublicKey          string `json:"policy_signer_public_key"`
	RootSignatureAlgorithm         string `json:"root_signature_algorithm"`
	RootIssuerPublicKeyDER         string `json:"root_issuer_public_key_der"`
	RootIssuerPublicKeyFingerprint string `json:"root_issuer_public_key_fingerprint"`
}

type loadedTrustPoolIdentity struct {
	raw          trustPoolIdentity
	identityCore poolmanifest.IdentityCore
	authority    ed25519.PublicKey
	policySigner ed25519.PublicKey
	rootDER      []byte
}

// requiredFlags fails unless every named flag was given on the command line.
// Values may be empty only where the caller checks them itself.
func requiredFlags(fs *flag.FlagSet, names ...string) error {
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	var missing []string
	for _, name := range names {
		if !set[name] {
			missing = append(missing, "--"+name)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("required flag(s) not set: %s", strings.Join(missing, ", "))
	}
	return nil
}

func parseOfflineFlags(fs *flag.FlagSet, args []string) error {
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments")
	}
	return nil
}

func validTrustPoolKeyID(label, v string) error {
	if !trustPoolKeyIDPattern.MatchString(v) {
		return fmt.Errorf("--%s must match %s", label, trustPoolKeyIDPattern.String())
	}
	return nil
}

// trustPoolAdminKeygen generates the root issuer (ECDSA P-256), manifest
// authority root (Ed25519) and policy signer (Ed25519) keys into a new
// owner-only directory, and writes pool-identity.json beside them.
func trustPoolAdminKeygen(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("trust-pool-admin keygen", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	outDir := fs.String("out-dir", "", "new directory for the keys (created 0700; must not exist)")
	authorityKeyID := fs.String("manifest-authority-key-id", "", "SPEC-042 manifest authority root key id (derives pool_id)")
	policyKeyID := fs.String("policy-signer-key-id", "", "SPEC-042 policy signer key id (genesis signer set, 1-of-1)")
	if err := parseOfflineFlags(fs, args); err != nil {
		return err
	}
	if err := requiredFlags(fs, "out-dir", "manifest-authority-key-id", "policy-signer-key-id"); err != nil {
		return err
	}
	if err := validTrustPoolKeyID("manifest-authority-key-id", *authorityKeyID); err != nil {
		return err
	}
	if err := validTrustPoolKeyID("policy-signer-key-id", *policyKeyID); err != nil {
		return err
	}
	if *authorityKeyID == *policyKeyID {
		return fmt.Errorf("--manifest-authority-key-id and --policy-signer-key-id must differ")
	}
	dir := strings.TrimSpace(*outDir)
	if dir == "" {
		return fmt.Errorf("--out-dir must not be empty")
	}
	if err := os.Mkdir(dir, 0o700); err != nil {
		return fmt.Errorf("create --out-dir: %w", err)
	}
	root, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	authorityPub, authority, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	policyPub, policy, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	rootDER, err := x509.MarshalPKIXPublicKey(&root.PublicKey)
	if err != nil {
		return err
	}
	fingerprint, err := trustpool.RootIssuerPublicKeyFingerprint(trustpool.RootSignatureAlgorithmP256SHA256, rootDER)
	if err != nil {
		return err
	}
	poolID, err := poolmanifest.IdentityCore{RootIssuerKeyID: *authorityKeyID, GenesisNonce: nonce}.PoolID()
	if err != nil {
		return err
	}
	for name, key := range map[string]any{
		trustPoolRootIssuerKeyFile:        root,
		trustPoolManifestAuthorityKeyFile: authority,
		trustPoolPolicySignerKeyFile:      policy,
	} {
		if err := writePrivateKeyPEM(filepath.Join(dir, name), key); err != nil {
			return err
		}
	}
	identity := trustPoolIdentity{
		SchemaVersion:                  trustPoolIdentitySchema,
		PoolID:                         poolID,
		GenesisNonce:                   base64.StdEncoding.EncodeToString(nonce),
		ManifestAuthorityKeyID:         *authorityKeyID,
		ManifestAuthorityPublicKey:     base64.StdEncoding.EncodeToString(authorityPub),
		PolicySignerKeyID:              *policyKeyID,
		PolicySignerPublicKey:          base64.StdEncoding.EncodeToString(policyPub),
		RootSignatureAlgorithm:         trustpool.RootSignatureAlgorithmP256SHA256,
		RootIssuerPublicKeyDER:         base64.StdEncoding.EncodeToString(rootDER),
		RootIssuerPublicKeyFingerprint: fingerprint,
	}
	raw, err := json.MarshalIndent(identity, "", "  ")
	if err != nil {
		return err
	}
	if err := writeNewFile(filepath.Join(dir, trustPoolIdentityFile), append(raw, '\n'), 0o644); err != nil {
		return err
	}
	_, err = fmt.Fprintf(stdout, "pool_id=%s\nroot_issuer_public_key_fingerprint=%s\nidentity=%s\n",
		poolID, fingerprint, filepath.Join(dir, trustPoolIdentityFile))
	return err
}

// trustPoolAdminSignRoot builds and signs the root_issuer_registered event for
// a nonce issued by `issue-root-nonce`.
func trustPoolAdminSignRoot(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("trust-pool-admin sign-root", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identityPath := fs.String("identity", "", "pool-identity.json from keygen")
	rootKeyPath := fs.String("root-issuer-key", "", "root issuer private key PEM (owner-only file)")
	rootKeyID := fs.String("root-issuer-key-id", "", "SPEC-043 root issuer key id")
	operationID := fs.String("operation-id", "", "idempotency/operation id of the event")
	creator := fs.String("creator-account-id", "", "approved creator account id")
	approval := fs.String("approval-record-id", "", "creator approval record id")
	approvalVersion := fs.String("approval-version", "", "current creator approval version")
	launchEnvironment := fs.String("launch-environment", "", "launch environment the nonce was issued for")
	custodyPath := fs.String("custody-disclosure", "", "SPEC-043-R002 key_custody_disclosure JSON; the event carries sha256 of its exact bytes")
	custodyClass := fs.String("custody-class", "", "expected custody class: software, hsm, mpc or other; must equal the disclosure's class")
	displayName := fs.String("display-name", "", "intended pool display name; the event carries its sha256")
	nonce := fs.String("nonce", "", "root registration nonce from issue-root-nonce")
	nonceExpiry := fs.String("nonce-expiry", "", "that nonce's expires_at_utc (RFC3339)")
	outPath := fs.String("out", "", "new file for the signed event JSON")
	if err := parseOfflineFlags(fs, args); err != nil {
		return err
	}
	if err := requiredFlags(fs, "identity", "root-issuer-key", "root-issuer-key-id", "operation-id",
		"creator-account-id", "approval-record-id", "approval-version", "launch-environment",
		"custody-disclosure", "custody-class", "display-name", "nonce", "nonce-expiry", "out"); err != nil {
		return err
	}
	for label, v := range map[string]string{
		"operation-id": *operationID, "creator-account-id": *creator, "approval-record-id": *approval,
		"approval-version": *approvalVersion, "launch-environment": *launchEnvironment,
		"display-name": *displayName, "nonce": *nonce, "out": *outPath,
	} {
		if strings.TrimSpace(v) == "" || strings.TrimSpace(v) != v {
			return fmt.Errorf("--%s must be non-empty without surrounding whitespace", label)
		}
	}
	if err := validTrustPoolKeyID("root-issuer-key-id", *rootKeyID); err != nil {
		return err
	}
	if _, err := time.Parse(time.RFC3339Nano, *nonceExpiry); err != nil {
		return fmt.Errorf("--nonce-expiry must be RFC3339: %w", err)
	}
	custodyHash, err := trustPoolCustodyDisclosureHash(*custodyPath, *custodyClass)
	if err != nil {
		return err
	}
	identity, err := loadTrustPoolIdentity(*identityPath)
	if err != nil {
		return err
	}
	root, err := loadRootIssuerKey(*rootKeyPath, identity)
	if err != nil {
		return err
	}
	e := trustpool.DurableEvent{
		OperationID:                        *operationID,
		TimestampUTC:                       time.Now().UTC(),
		EventType:                          trustpool.EventRootIssuerRegistered,
		PoolID:                             identity.raw.PoolID,
		CreatorAccountID:                   *creator,
		ApprovalRecordID:                   *approval,
		CurrentApprovalVersion:             *approvalVersion,
		RootIssuerKeyID:                    *rootKeyID,
		RootIssuerPublicKeyDER:             identity.raw.RootIssuerPublicKeyDER,
		RootIssuerPublicKeyFingerprint:     identity.raw.RootIssuerPublicKeyFingerprint,
		RootSignatureAlgorithm:             trustpool.RootSignatureAlgorithmP256SHA256,
		ManifestAuthorityRootKeyID:         identity.raw.ManifestAuthorityKeyID,
		ManifestAuthorityRootPublicKey:     identity.raw.ManifestAuthorityPublicKey,
		StructuredKeyCustodyDisclosureHash: custodyHash,
		GenesisNonceDigest:                 sha256Hex(identity.identityCore.GenesisNonce),
		IntendedPoolDisplayNameHash:        sha256Hex([]byte(*displayName)),
		LaunchEnvironment:                  *launchEnvironment,
		RootRegistrationNonce:              *nonce,
		RootRegistrationNonceExpiry:        *nonceExpiry,
		RootRegistrationPurpose:            trustpool.RootRegistrationPurposeDefault,
		RootRegistrationEnvironment:        *launchEnvironment,
	}
	msg, err := trustpool.RootRegistrationSigningMessage(e)
	if err != nil {
		return err
	}
	if e.RootRegistrationSignature, err = signTrustPoolP256(root, msg); err != nil {
		return err
	}
	if err := trustpool.VerifyRootIssuerRegistrationEvent(e); err != nil {
		return fmt.Errorf("signed root registration does not verify: %w", err)
	}
	return writeTrustPoolEvent(*outPath, e, stdout)
}

// trustPoolAdminSignManifest builds and signs a manifest_accepted event. With
// no --prev it is the genesis manifest (version 1) and also signs the genesis
// authority-log entry with the manifest authority root key; with --prev it
// extends that accepted event's snapshot by one version.
func trustPoolAdminSignManifest(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("trust-pool-admin sign-manifest", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	identityPath := fs.String("identity", "", "pool-identity.json from keygen")
	rootKeyPath := fs.String("root-issuer-key", "", "root issuer private key PEM (owner-only file)")
	rootKeyID := fs.String("root-issuer-key-id", "", "SPEC-043 root issuer key id (as registered)")
	authorityKeyPath := fs.String("manifest-authority-key", "", "manifest authority root private key PEM; genesis only")
	policyKeyPath := fs.String("policy-signer-key", "", "policy signer private key PEM (owner-only file)")
	prevPath := fs.String("prev", "", "previous manifest_accepted event JSON; omit for the genesis manifest")
	operationID := fs.String("operation-id", "", "idempotency/operation id of the event")
	encoding := fs.Int("encoding", 0, "policy core encoding: 1 or 2")
	signerSetVersion := fs.Uint64("signer-set-version", 0, "signer set that signs this core (genesis: 1)")
	settlementMode := fs.String("settlement-mode", "", "observe or enforce")
	runtimeAllowlist := fs.String("runtime-allowlist", "", "comma-separated runtime_allowlist (encoding 2; empty = native only)")
	models := fs.String("models", "", "comma-separated model allowlist")
	minBinary := fs.String("min-binary-version", "", "pool min binary version")
	minTier := fs.String("min-attestation-tier", "", "pool min attestation tier")
	retention := fs.String("retention-policy-id", "", "registered retention policy id")
	minMembers := fs.Uint64("min-eligible-members", 0, "minimum eligible members")
	notBefore := fs.String("not-before", "", "policy window start (RFC3339)")
	expiresAt := fs.String("expires-at", "", "policy window end (RFC3339)")
	outPath := fs.String("out", "", "new file for the signed event JSON")
	if err := parseOfflineFlags(fs, args); err != nil {
		return err
	}
	if err := requiredFlags(fs, "identity", "root-issuer-key", "root-issuer-key-id", "policy-signer-key",
		"operation-id", "encoding", "signer-set-version", "settlement-mode", "models", "min-binary-version",
		"min-attestation-tier", "retention-policy-id", "min-eligible-members", "not-before", "expires-at", "out"); err != nil {
		return err
	}
	if err := validTrustPoolKeyID("root-issuer-key-id", *rootKeyID); err != nil {
		return err
	}
	for label, v := range map[string]string{
		"operation-id": *operationID, "settlement-mode": *settlementMode, "min-attestation-tier": *minTier,
		"retention-policy-id": *retention, "min-binary-version": *minBinary, "out": *outPath,
	} {
		if strings.TrimSpace(v) == "" || strings.TrimSpace(v) != v {
			return fmt.Errorf("--%s must be non-empty without surrounding whitespace", label)
		}
	}
	var coreEncoding uint8
	switch *encoding {
	case int(poolmanifest.PolicyCoreEncodingV1):
		coreEncoding = poolmanifest.PolicyCoreEncodingV1
		set := map[string]bool{}
		fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
		if set["runtime-allowlist"] {
			return fmt.Errorf("--runtime-allowlist needs --encoding 2")
		}
	case int(poolmanifest.PolicyCoreEncodingV2):
		coreEncoding = poolmanifest.PolicyCoreEncodingV2
		if err := requiredFlags(fs, "runtime-allowlist"); err != nil {
			return fmt.Errorf("--encoding 2 needs an explicit --runtime-allowlist (use \"\" for native only): %w", err)
		}
	default:
		return fmt.Errorf("--encoding must be 1 or 2")
	}
	modelList := splitTrustPoolCSV(*models)
	if len(modelList) == 0 {
		return fmt.Errorf("--models must name at least one model")
	}
	start, err := parseTrustPoolUnix("not-before", *notBefore)
	if err != nil {
		return err
	}
	end, err := parseTrustPoolUnix("expires-at", *expiresAt)
	if err != nil {
		return err
	}
	if end <= start {
		return fmt.Errorf("--expires-at must be after --not-before")
	}

	identity, err := loadTrustPoolIdentity(*identityPath)
	if err != nil {
		return err
	}
	root, err := loadRootIssuerKey(*rootKeyPath, identity)
	if err != nil {
		return err
	}
	policy, err := loadEd25519Key(*policyKeyPath, identity.policySigner, "--policy-signer-key")
	if err != nil {
		return err
	}
	core := poolmanifest.PolicyCore{
		PoolID:             identity.raw.PoolID,
		SignerSetVersion:   *signerSetVersion,
		ModelAllowlist:     modelList,
		MinBinaryVersion:   *minBinary,
		MinAttestationTier: *minTier,
		SettlementMode:     *settlementMode,
		RetentionPolicyID:  *retention,
		MinEligibleMembers: *minMembers,
		NotBeforeUnix:      start,
		ExpiresAtUnix:      end,
		Encoding:           coreEncoding,
		// The coordinator accepts only these values today (SPEC-043
		// candidate claims, SPEC-042 Layer 2): no revenue-split execution,
		// no Layer-3 privacy promise, no sticky routing.
		SplitExecutionStatus: "declared_not_executed",
		PrivacyMode:          "none",
		MetadataVisible:      "standard",
		DowngradePolicy:      "reject",
	}
	if coreEncoding == poolmanifest.PolicyCoreEncodingV2 {
		core.RuntimeAllowlist = splitTrustPoolCSV(*runtimeAllowlist)
	}
	var snapshot poolmanifest.ManifestSnapshot
	if strings.TrimSpace(*prevPath) == "" {
		if strings.TrimSpace(*authorityKeyPath) == "" {
			return fmt.Errorf("the genesis manifest needs --manifest-authority-key to sign the genesis signer set")
		}
		authority, err := loadEd25519Key(*authorityKeyPath, identity.authority, "--manifest-authority-key")
		if err != nil {
			return err
		}
		core.ManifestVersion = 1
		core.PrevManifestCoreHash = poolmanifest.GenesisPrevHash()
		entry := poolmanifest.AuthorityLogEntry{
			PoolID:                      identity.raw.PoolID,
			SignerSetVersion:            *signerSetVersion,
			PrevAuthorityLogEntryHash:   poolmanifest.GenesisPrevHash(),
			Keys:                        []poolmanifest.SignerKey{{KeyID: identity.raw.PolicySignerKeyID, PublicKey: identity.policySigner}},
			Threshold:                   1,
			NotBeforeUnix:               trustPoolGenesisSignerSetNotBefore,
			ExpiresAtUnix:               trustPoolGenesisSignerSetExpiresAt,
			AuthorizingSignerSetVersion: 0,
		}
		entryHash, err := entry.EntryHash()
		if err != nil {
			return err
		}
		entryMsg, err := poolmanifest.AuthorityLogEntrySigningMessage(entryHash)
		if err != nil {
			return err
		}
		entry.Signatures = []poolmanifest.Signature{{KeyID: identity.raw.ManifestAuthorityKeyID, Sig: ed25519.Sign(authority, entryMsg)}}
		snapshot = poolmanifest.ManifestSnapshot{
			IdentityCore:  identity.identityCore,
			RootIssuerKey: poolmanifest.SignerKey{KeyID: identity.raw.ManifestAuthorityKeyID, PublicKey: identity.authority},
			AuthorityLog:  []poolmanifest.AuthorityLogEntry{entry},
		}
	} else {
		if strings.TrimSpace(*authorityKeyPath) != "" {
			return fmt.Errorf("--manifest-authority-key is genesis-only; omit it with --prev")
		}
		prev, err := readTrustPoolEvent(*prevPath)
		if err != nil {
			return err
		}
		if prev.EventType != trustpool.EventManifestAccepted || prev.PoolID != identity.raw.PoolID {
			return fmt.Errorf("--prev must be a manifest_accepted event for pool %s", identity.raw.PoolID)
		}
		snapRaw, err := base64.StdEncoding.DecodeString(prev.ManifestSnapshot)
		if err != nil {
			return fmt.Errorf("--prev manifest_snapshot: %w", err)
		}
		if snapshot, err = poolmanifest.ParseManifestSnapshot(snapRaw); err != nil {
			return fmt.Errorf("--prev manifest_snapshot: %w", err)
		}
		if len(snapshot.Policies) == 0 {
			return fmt.Errorf("--prev manifest_snapshot has no accepted policy")
		}
		prevDigest, err := hex.DecodeString(prev.ManifestCoreDigest)
		if err != nil {
			return fmt.Errorf("--prev manifest_core_digest: %w", err)
		}
		prevCore := snapshot.Policies[len(snapshot.Policies)-1].SignedCore.Core
		if start < prevCore.ExpiresAtUnix {
			return fmt.Errorf("--not-before must not precede the previous policy window end (%s)",
				time.Unix(int64(prevCore.ExpiresAtUnix), 0).UTC().Format(time.RFC3339))
		}
		core.ManifestVersion = prev.ManifestVersion + 1
		core.PrevManifestCoreHash = prevDigest
	}
	if err := core.ValidateAcceptance(); err != nil {
		return fmt.Errorf("policy core: %w", err)
	}
	digest, err := core.ManifestCoreDigest()
	if err != nil {
		return err
	}
	policyMsg, err := core.SigningMessage()
	if err != nil {
		return err
	}
	snapshot.Policies = append(snapshot.Policies, poolmanifest.AcceptedPolicyRecord{
		SignedCore: poolmanifest.SignedPolicyCore{
			Core:       core,
			Signatures: []poolmanifest.Signature{{KeyID: identity.raw.PolicySignerKeyID, Sig: ed25519.Sign(policy, policyMsg)}},
		},
		AcceptedAtUnix: uint64(time.Now().Unix()),
	})
	if err := poolmanifest.VerifyNewestPolicyAcceptance(snapshot); err != nil {
		return fmt.Errorf("signed policy core does not verify against the signer set: %w", err)
	}
	snapRaw, err := snapshot.CanonicalBytes()
	if err != nil {
		return err
	}
	e := trustpool.DurableEvent{
		OperationID:                    *operationID,
		TimestampUTC:                   time.Now().UTC(),
		EventType:                      trustpool.EventManifestAccepted,
		PoolID:                         identity.raw.PoolID,
		ManifestVersion:                core.ManifestVersion,
		ManifestCoreDigest:             hex.EncodeToString(digest),
		RootIssuerKeyID:                *rootKeyID,
		RootIssuerPublicKeyFingerprint: identity.raw.RootIssuerPublicKeyFingerprint,
		ManifestSnapshot:               base64.StdEncoding.EncodeToString(snapRaw),
	}
	msg, err := trustpool.ManifestAcceptanceSigningMessage(e)
	if err != nil {
		return err
	}
	if e.ManifestSignature, err = signTrustPoolP256(root, msg); err != nil {
		return err
	}
	if _, _, err := trustpool.VerifyManifestAcceptedEvent(e, trustpool.ReconstructedRootIssuer{
		KeyID:                          *rootKeyID,
		PublicKeyDER:                   identity.raw.RootIssuerPublicKeyDER,
		PublicKeyFingerprint:           identity.raw.RootIssuerPublicKeyFingerprint,
		SignatureAlgorithm:             identity.raw.RootSignatureAlgorithm,
		ManifestAuthorityRootKeyID:     identity.raw.ManifestAuthorityKeyID,
		ManifestAuthorityRootPublicKey: identity.raw.ManifestAuthorityPublicKey,
		GenesisNonceDigest:             sha256Hex(identity.identityCore.GenesisNonce),
	}); err != nil {
		return fmt.Errorf("signed manifest does not verify: %w", err)
	}
	return writeTrustPoolEvent(*outPath, e, stdout)
}

func trustPoolCustodyDisclosureHash(path, wantClass string) (string, error) {
	if !trustPoolCustodyClasses[wantClass] {
		return "", fmt.Errorf("--custody-class must be one of software, hsm, mpc, other")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read --custody-disclosure: %w", err)
	}
	var disclosure map[string]any
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	if err := dec.Decode(&disclosure); err != nil {
		return "", fmt.Errorf("--custody-disclosure must be one JSON object: %w", err)
	}
	if dec.More() {
		return "", fmt.Errorf("--custody-disclosure must contain exactly one JSON object")
	}
	class, _ := disclosure["class"].(string)
	description, _ := disclosure["description"].(string)
	if class != wantClass {
		return "", fmt.Errorf("--custody-disclosure class %q does not equal --custody-class %q", class, wantClass)
	}
	if strings.TrimSpace(description) == "" {
		return "", fmt.Errorf("--custody-disclosure needs a non-empty description (SPEC-043-R002)")
	}
	return sha256Hex(raw), nil
}

func loadTrustPoolIdentity(path string) (loadedTrustPoolIdentity, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return loadedTrustPoolIdentity{}, fmt.Errorf("read --identity: %w", err)
	}
	var id trustPoolIdentity
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&id); err != nil {
		return loadedTrustPoolIdentity{}, fmt.Errorf("--identity: %w", err)
	}
	if id.SchemaVersion != trustPoolIdentitySchema {
		return loadedTrustPoolIdentity{}, fmt.Errorf("--identity schema_version must be %s", trustPoolIdentitySchema)
	}
	if id.RootSignatureAlgorithm != trustpool.RootSignatureAlgorithmP256SHA256 {
		return loadedTrustPoolIdentity{}, fmt.Errorf("--identity root_signature_algorithm must be %s", trustpool.RootSignatureAlgorithmP256SHA256)
	}
	decode := func(field, v string) ([]byte, error) {
		b, err := base64.StdEncoding.DecodeString(v)
		if err != nil || len(b) == 0 {
			return nil, fmt.Errorf("--identity %s must be non-empty base64", field)
		}
		return b, nil
	}
	nonce, err := decode("genesis_nonce", id.GenesisNonce)
	if err != nil {
		return loadedTrustPoolIdentity{}, err
	}
	authority, err := decode("manifest_authority_public_key", id.ManifestAuthorityPublicKey)
	if err != nil {
		return loadedTrustPoolIdentity{}, err
	}
	policy, err := decode("policy_signer_public_key", id.PolicySignerPublicKey)
	if err != nil {
		return loadedTrustPoolIdentity{}, err
	}
	rootDER, err := decode("root_issuer_public_key_der", id.RootIssuerPublicKeyDER)
	if err != nil {
		return loadedTrustPoolIdentity{}, err
	}
	if len(authority) != ed25519.PublicKeySize || len(policy) != ed25519.PublicKeySize {
		return loadedTrustPoolIdentity{}, fmt.Errorf("--identity Ed25519 public keys must be %d bytes", ed25519.PublicKeySize)
	}
	core := poolmanifest.IdentityCore{RootIssuerKeyID: id.ManifestAuthorityKeyID, GenesisNonce: nonce}
	poolID, err := core.PoolID()
	if err != nil {
		return loadedTrustPoolIdentity{}, err
	}
	if poolID != id.PoolID {
		return loadedTrustPoolIdentity{}, fmt.Errorf("--identity pool_id does not derive from manifest_authority_key_id and genesis_nonce")
	}
	fingerprint, err := trustpool.RootIssuerPublicKeyFingerprint(id.RootSignatureAlgorithm, rootDER)
	if err != nil {
		return loadedTrustPoolIdentity{}, err
	}
	if fingerprint != id.RootIssuerPublicKeyFingerprint {
		return loadedTrustPoolIdentity{}, fmt.Errorf("--identity root_issuer_public_key_fingerprint does not match root_issuer_public_key_der")
	}
	return loadedTrustPoolIdentity{
		raw: id, identityCore: core, authority: authority, policySigner: policy, rootDER: rootDER,
	}, nil
}

// readOwnerOnlyFile reads a private key file only when it is a regular file
// (not a symlink) owned by the current user with no group/other permission.
func readOwnerOnlyFile(path, label string) ([]byte, error) {
	if strings.TrimSpace(path) == "" {
		return nil, fmt.Errorf("%s is required", label)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", label, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s must be a regular file, not a symlink or special file", label)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return nil, fmt.Errorf("%s has mode %04o; private keys must be owner-only (0600 or 0400)", label, perm)
	}
	if st, ok := info.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return nil, fmt.Errorf("%s must be owned by the current user", label)
	}
	return os.ReadFile(path)
}

func parsePrivateKeyPEM(path, label string) (any, error) {
	raw, err := readOwnerOnlyFile(path, label)
	if err != nil {
		return nil, err
	}
	block, rest := pem.Decode(raw)
	if block == nil || block.Type != "PRIVATE KEY" || len(strings.TrimSpace(string(rest))) != 0 {
		return nil, fmt.Errorf("%s must hold exactly one PKCS#8 \"PRIVATE KEY\" PEM block", label)
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("%s: parse PKCS#8: %w", label, err)
	}
	return key, nil
}

func loadRootIssuerKey(path string, identity loadedTrustPoolIdentity) (*ecdsa.PrivateKey, error) {
	parsed, err := parsePrivateKeyPEM(path, "--root-issuer-key")
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, fmt.Errorf("--root-issuer-key must be an ECDSA P-256 key")
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return nil, err
	}
	if string(der) != string(identity.rootDER) {
		return nil, fmt.Errorf("--root-issuer-key does not match the identity's root issuer public key")
	}
	return key, nil
}

func loadEd25519Key(path string, want ed25519.PublicKey, label string) (ed25519.PrivateKey, error) {
	parsed, err := parsePrivateKeyPEM(path, label)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(ed25519.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("%s must be an Ed25519 key", label)
	}
	if !key.Public().(ed25519.PublicKey).Equal(want) {
		return nil, fmt.Errorf("%s does not match the identity's public key", label)
	}
	return key, nil
}

func writePrivateKeyPEM(path string, key any) error {
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	return writeNewFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
}

// writeNewFile never replaces an existing file or follows a symlink at path.
func writeNewFile(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func readTrustPoolEvent(path string) (trustpool.DurableEvent, error) {
	var e trustpool.DurableEvent
	raw, err := os.ReadFile(path)
	if err != nil {
		return e, err
	}
	if err := json.Unmarshal(raw, &e); err != nil {
		return e, fmt.Errorf("%s: %w", path, err)
	}
	return e, nil
}

func writeTrustPoolEvent(path string, e trustpool.DurableEvent, stdout io.Writer) error {
	raw, err := json.Marshal(e)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	if err := writeNewFile(path, raw, 0o644); err != nil {
		return fmt.Errorf("write --out: %w", err)
	}
	_, err = fmt.Fprintf(stdout, "event_type=%s\npool_id=%s\noperation_id=%s\nevent_sha256=%s\nout=%s\n",
		e.EventType, e.PoolID, e.OperationID, sha256Hex(raw), path)
	return err
}

func signTrustPoolP256(key *ecdsa.PrivateKey, msg []byte) (string, error) {
	digest := sha256.Sum256(msg)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(sig), nil
}

func parseTrustPoolUnix(label, v string) (uint64, error) {
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return 0, fmt.Errorf("--%s must be RFC3339: %w", label, err)
	}
	if t.Unix() <= 0 {
		return 0, fmt.Errorf("--%s must be after the Unix epoch", label)
	}
	return uint64(t.Unix()), nil
}

func splitTrustPoolCSV(s string) []string {
	out := []string{}
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
