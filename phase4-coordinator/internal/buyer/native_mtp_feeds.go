package buyer

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

// SPEC-023 §12.5 (SPEC-023-R024) native-MTP admission set and emergency
// revocation feed. The coordinator relays signed bytes it cannot forge: the
// provider verifies every signature and binding itself. The checks here make
// a misconfigured deploy fail closed instead of serving bytes no provider can
// admit.

const (
	nativeMTPAdmissionSchema   = "macprovider.native-mtp-admission.v1"
	nativeMTPRevocationsSchema = "macprovider.native-mtp-revocations.v1"
	// SPEC-023 §12.5: at most 256 admission entries and a one-hour revocation
	// body; the provider refuses larger files.
	maxNativeMTPAdmissionEntries = 256
	maxNativeMTPRevocationBytes  = 64 << 10
	maxNativeMTPRevocationSlots  = 4096
	nativeMTPRevocationMaxWindow = time.Hour
	// Directory index refresh; an operator replacing the slot directory is
	// served within this bound.
	nativeMTPRevocationRescan = 10 * time.Second
)

var nativeMTPRevocationSlotName = regexp.MustCompile(`^([0-9]{1,19})\.json$`)

type nativeMTPAdmissionEnvelope struct {
	SchemaVersion            string                       `json:"schema_version"`
	ReleaseID                string                       `json:"release_id"`
	IssuedAt                 string                       `json:"issued_at"`
	ExpiresAt                string                       `json:"expires_at"`
	SignerKeyID              string                       `json:"signer_key_id"`
	ChallengeBankSignerKeyID string                       `json:"challenge_bank_signer_key_id"`
	RevocationSignerKeyID    string                       `json:"revocation_signer_key_id"`
	Entries                  []map[string]json.RawMessage `json:"entries"`
}

// NativeMTPFeeds is the loaded admission set of one catalog release plus the
// revocation slot directory. Empty when the release carries no admission.
type NativeMTPFeeds struct {
	AdmissionJSON         []byte
	AdmissionSig          []byte
	ArtifactManifestJSON  []byte
	SelftestBankJSON      []byte
	SelftestBankSig       []byte
	ReleaseID             string
	RevocationSignerKeyID string
	revocations           *nativeMTPRevocationSlots
}

func (f NativeMTPFeeds) admissionEnabled() bool {
	return len(f.AdmissionJSON) > 0 && len(f.AdmissionSig) > 0
}

// loadNativeMTPFeeds reads the optional admission set. Configured, it needs
// the candidate catalog of the same release: the sidecar release_id must be
// the catalog version and its signer the catalog signer (SPEC-023 §12.5), the
// projection manifest and challenge bank must be the exact bytes every entry
// binds, and the bank must carry the sidecar's challenge-bank signature.
func loadNativeMTPFeeds(cfg config.AutotuneFeedsConfig, keyring map[string]ed25519.PublicKey, candidates loadedAutotuneFeed) (NativeMTPFeeds, error) {
	paths := map[string]string{
		"native_mtp_admission_path":         strings.TrimSpace(cfg.NativeMTPAdmissionPath),
		"native_mtp_admission_sig_path":     strings.TrimSpace(cfg.NativeMTPAdmissionSigPath),
		"native_mtp_artifact_manifest_path": strings.TrimSpace(cfg.NativeMTPArtifactManifestPath),
		"native_mtp_selftest_bank_path":     strings.TrimSpace(cfg.NativeMTPSelftestBankPath),
		"native_mtp_selftest_bank_sig_path": strings.TrimSpace(cfg.NativeMTPSelftestBankSigPath),
		"native_mtp_revocations_dir":        strings.TrimSpace(cfg.NativeMTPRevocationsDir),
	}
	set := 0
	for _, p := range paths {
		if p != "" {
			set++
		}
	}
	if set == 0 {
		return NativeMTPFeeds{}, nil
	}
	if set != len(paths) {
		return NativeMTPFeeds{}, fmt.Errorf("autotune native-MTP feed set incomplete: %s must all be configured together", strings.Join(sortedKeys(paths), ", "))
	}
	if !candidates.enabled() {
		return NativeMTPFeeds{}, fmt.Errorf("autotune native-MTP feed set requires the autotune_candidates feed of the same release")
	}
	admission, err := loadAutotuneFeedPair(paths["native_mtp_admission_path"], paths["native_mtp_admission_sig_path"], "native_mtp_admission", keyring, validateNativeMTPAdmissionShape)
	if err != nil {
		return NativeMTPFeeds{}, err
	}
	var envelope nativeMTPAdmissionEnvelope
	if err := decodeStrictJSON(admission.jsonBytes, &envelope); err != nil {
		return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_admission schema: %w", err)
	}
	if envelope.ReleaseID != candidates.verification.Version {
		return NativeMTPFeeds{}, fmt.Errorf("autotune native-MTP release mismatch: admission release_id %q != autotune_candidates version %q", envelope.ReleaseID, candidates.verification.Version)
	}
	if admission.verification.KeyID != candidates.verification.KeyID {
		return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_admission signer key_id %q != autotune_candidates signer key_id %q", admission.verification.KeyID, candidates.verification.KeyID)
	}
	for _, id := range []string{envelope.ChallengeBankSignerKeyID, envelope.RevocationSignerKeyID} {
		if _, ok := keyring[id]; !ok {
			return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_admission names key_id %q absent from autotune.public_keys", id)
		}
	}
	manifest, err := readBoundedFeedFile(paths["native_mtp_artifact_manifest_path"], "native_mtp_artifact_manifest", maxAutotuneFeedBytes)
	if err != nil {
		return NativeMTPFeeds{}, err
	}
	bank, err := readBoundedFeedFile(paths["native_mtp_selftest_bank_path"], "native_mtp_selftest_bank", maxAutotuneFeedBytes)
	if err != nil {
		return NativeMTPFeeds{}, err
	}
	bankSig, err := readBoundedFeedFile(paths["native_mtp_selftest_bank_sig_path"], "native_mtp_selftest_bank_sig", maxAutotuneSidecarBytes)
	if err != nil {
		return NativeMTPFeeds{}, err
	}
	bankSidecar, bankSignature, err := parseAutotuneSidecar(bankSig)
	if err != nil {
		return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_selftest_bank signature sidecar: %w", err)
	}
	if bankSidecar.KeyID != envelope.ChallengeBankSignerKeyID {
		return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_selftest_bank signer key_id %q != admission challenge_bank_signer_key_id %q", bankSidecar.KeyID, envelope.ChallengeBankSignerKeyID)
	}
	if !ed25519.Verify(keyring[bankSidecar.KeyID], bank, bankSignature) {
		return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_selftest_bank signature verification failed")
	}
	manifestSHA := sha256Hex(manifest)
	bankSHA := sha256Hex(bank)
	for i, entry := range envelope.Entries {
		for field, want := range map[string]string{"artifact_manifest_sha256": manifestSHA, "challenge_bank_sha256": bankSHA} {
			var got string
			if err := json.Unmarshal(entry[field], &got); err != nil || got != want {
				return NativeMTPFeeds{}, fmt.Errorf("autotune.native_mtp_admission entries[%d].%s does not match the configured %s bytes", i, field, strings.TrimSuffix(field, "_sha256"))
			}
		}
	}
	return NativeMTPFeeds{
		AdmissionJSON:         admission.jsonBytes,
		AdmissionSig:          admission.sigBytes,
		ArtifactManifestJSON:  manifest,
		SelftestBankJSON:      bank,
		SelftestBankSig:       bankSig,
		ReleaseID:             envelope.ReleaseID,
		RevocationSignerKeyID: envelope.RevocationSignerKeyID,
		revocations: &nativeMTPRevocationSlots{
			dir:     paths["native_mtp_revocations_dir"],
			keyID:   envelope.RevocationSignerKeyID,
			key:     keyring[envelope.RevocationSignerKeyID],
			nowFunc: time.Now,
		},
	}, nil
}

// validateNativeMTPAdmissionShape checks the closed envelope the provider
// parses; the entry grammar is the provider's (SPEC-048 R013) and is not
// duplicated here beyond the bindings loadNativeMTPFeeds checks.
func validateNativeMTPAdmissionShape(raw []byte, signerKeyID string) (feedRelease, error) {
	var envelope nativeMTPAdmissionEnvelope
	if err := decodeStrictJSON(raw, &envelope); err != nil {
		return feedRelease{}, err
	}
	if envelope.SchemaVersion != nativeMTPAdmissionSchema {
		return feedRelease{}, fmt.Errorf("schema_version must be %q", nativeMTPAdmissionSchema)
	}
	if envelope.SignerKeyID != signerKeyID {
		return feedRelease{}, fmt.Errorf("signer_key_id must equal signature key_id")
	}
	issued, err := parseFeedTimestamp("issued_at", envelope.IssuedAt)
	if err != nil {
		return feedRelease{}, err
	}
	expires, err := parseFeedTimestamp("expires_at", envelope.ExpiresAt)
	if err != nil {
		return feedRelease{}, err
	}
	if !issued.Before(expires) || expires.Sub(issued) > 90*24*time.Hour {
		return feedRelease{}, fmt.Errorf("expires_at must be after issued_at and at most 90 days later")
	}
	if strings.TrimSpace(envelope.ReleaseID) == "" || envelope.ReleaseID != strings.TrimSpace(envelope.ReleaseID) {
		return feedRelease{}, fmt.Errorf("release_id must be a non-empty trimmed string")
	}
	if len(envelope.Entries) == 0 || len(envelope.Entries) > maxNativeMTPAdmissionEntries {
		return feedRelease{}, fmt.Errorf("entries must contain 1..%d rows", maxNativeMTPAdmissionEntries)
	}
	return feedRelease{version: envelope.ReleaseID, generatedAt: issued}, nil
}

func parseFeedTimestamp(field, value string) (time.Time, error) {
	if !artifactFeedTimestampGrammar.MatchString(value) {
		return time.Time{}, fmt.Errorf("%s must be RFC3339 at seconds precision with an explicit timezone", field)
	}
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("%s must be RFC3339: %w", field, err)
	}
	return parsed, nil
}

func readBoundedFeedFile(path, label string, limit int) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read autotune.%s_path: %w", label, err)
	}
	if len(raw) == 0 {
		return nil, configEmptyFeedError(label)
	}
	if len(raw) > limit {
		return nil, fmt.Errorf("autotune.%s exceeds %d bytes", label, limit)
	}
	if !utf8.Valid(raw) {
		return nil, fmt.Errorf("autotune.%s is not valid UTF-8", label)
	}
	return raw, nil
}

func sha256Hex(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

// nativeMTPRevocationSlots serves the emergency revocation feed from a
// directory of pre-signed bodies, one per slot: `<generation>.json` and
// `<generation>.json.sig`. The served body is the newest one already issued
// (issued_at <= now). An elapsed expires_at does not stop serving it (#1938):
// providers keep enforcing the newest verified revoked set they hold, so a
// missed batch publish never turns native MTP off. The coordinator holds no signing key
// (SPEC-023 §3.7.9); an emergency revocation is a replacement directory
// signed off-host, whose higher generations and superset revoked set the
// provider's monotonic checks accept.
type nativeMTPRevocationSlots struct {
	dir     string
	keyID   string
	key     ed25519.PublicKey
	nowFunc func() time.Time

	mu        sync.Mutex
	scannedAt time.Time
	slots     []nativeMTPRevocationSlot
}

type nativeMTPRevocationSlot struct {
	generation uint64
	issuedAt   time.Time
	expiresAt  time.Time
	body       []byte
	sig        []byte
}

type nativeMTPRevocationBody struct {
	SchemaVersion               string   `json:"schema_version"`
	Generation                  uint64   `json:"generation"`
	IssuedAt                    string   `json:"issued_at"`
	ExpiresAt                   string   `json:"expires_at"`
	SignerKeyID                 string   `json:"signer_key_id"`
	RevokedAdmissionTupleSHA256 []string `json:"revoked_admission_tuple_sha256"`
}

func (r *nativeMTPRevocationSlots) current() (nativeMTPRevocationSlot, bool) {
	now := r.nowFunc()
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.scannedAt.IsZero() || now.Sub(r.scannedAt) >= nativeMTPRevocationRescan || now.Before(r.scannedAt) {
		r.slots = r.scan()
		r.scannedAt = now
	}
	var best *nativeMTPRevocationSlot
	for i := range r.slots {
		slot := &r.slots[i]
		if slot.issuedAt.After(now) {
			continue
		}
		if best == nil || slot.issuedAt.After(best.issuedAt) || (slot.issuedAt.Equal(best.issuedAt) && slot.generation > best.generation) {
			best = slot
		}
	}
	if best == nil {
		return nativeMTPRevocationSlot{}, false
	}
	return *best, true
}

// scan loads every well-formed, correctly signed slot. A malformed or
// unsigned slot is skipped, never served.
func (r *nativeMTPRevocationSlots) scan() []nativeMTPRevocationSlot {
	entries, err := os.ReadDir(r.dir)
	if err != nil {
		return nil
	}
	var slots []nativeMTPRevocationSlot
	for _, entry := range entries {
		if len(slots) >= maxNativeMTPRevocationSlots {
			break
		}
		match := nativeMTPRevocationSlotName.FindStringSubmatch(entry.Name())
		if match == nil || !entry.Type().IsRegular() {
			continue
		}
		slot, ok := r.loadSlot(match[1])
		if ok {
			slots = append(slots, slot)
		}
	}
	return slots
}

func (r *nativeMTPRevocationSlots) loadSlot(generationText string) (nativeMTPRevocationSlot, bool) {
	generation, err := strconv.ParseUint(generationText, 10, 64)
	if err != nil || strconv.FormatUint(generation, 10) != generationText {
		return nativeMTPRevocationSlot{}, false
	}
	body, err := os.ReadFile(filepath.Join(r.dir, generationText+".json"))
	if err != nil || len(body) == 0 || len(body) > maxNativeMTPRevocationBytes {
		return nativeMTPRevocationSlot{}, false
	}
	sig, err := os.ReadFile(filepath.Join(r.dir, generationText+".json.sig"))
	if err != nil || len(sig) == 0 || len(sig) > maxAutotuneSidecarBytes {
		return nativeMTPRevocationSlot{}, false
	}
	sidecar, signature, err := parseAutotuneSidecar(sig)
	if err != nil || sidecar.KeyID != r.keyID || !ed25519.Verify(r.key, body, signature) {
		return nativeMTPRevocationSlot{}, false
	}
	var parsed nativeMTPRevocationBody
	if err := decodeStrictJSON(body, &parsed); err != nil {
		return nativeMTPRevocationSlot{}, false
	}
	if parsed.SchemaVersion != nativeMTPRevocationsSchema || parsed.SignerKeyID != r.keyID || parsed.Generation != generation || parsed.RevokedAdmissionTupleSHA256 == nil {
		return nativeMTPRevocationSlot{}, false
	}
	issued, err := parseFeedTimestamp("issued_at", parsed.IssuedAt)
	if err != nil {
		return nativeMTPRevocationSlot{}, false
	}
	expires, err := parseFeedTimestamp("expires_at", parsed.ExpiresAt)
	if err != nil || !issued.Before(expires) || expires.Sub(issued) > nativeMTPRevocationMaxWindow {
		return nativeMTPRevocationSlot{}, false
	}
	return nativeMTPRevocationSlot{generation: generation, issuedAt: issued, expiresAt: expires, body: body, sig: sig}, true
}

func (s *Server) handleNativeMTPAdmission(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.NativeMTP.AdmissionJSON, feeds.NativeMTP.admissionEnabled())
}

func (s *Server) handleNativeMTPAdmissionSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.NativeMTP.AdmissionSig, feeds.NativeMTP.admissionEnabled())
}

func (s *Server) handleNativeMTPArtifactManifest(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.NativeMTP.ArtifactManifestJSON, feeds.NativeMTP.admissionEnabled())
}

func (s *Server) handleNativeMTPSelftestBank(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.NativeMTP.SelftestBankJSON, feeds.NativeMTP.admissionEnabled())
}

func (s *Server) handleNativeMTPSelftestBankSig(w http.ResponseWriter, r *http.Request) {
	feeds := s.autotuneFeedsSnapshot()
	s.serveAutotuneFeedBytes(w, r, feeds.NativeMTP.SelftestBankSig, feeds.NativeMTP.admissionEnabled())
}

// handleNativeMTPRevocations serves `native-mtp-revocations.<key>.json` and
// its `.sig` (SPEC-023 §12.5). A newer slot replaces the served body at its
// issued_at, so it is served without shared caching.
func (s *Server) handleNativeMTPRevocations(w http.ResponseWriter, r *http.Request) {
	if !s.allowReceiptKeys(r) {
		w.Header().Set("Retry-After", "1")
		writeError(w, http.StatusTooManyRequests, "rate_limited", "Autotune feed endpoint rate limit exceeded")
		return
	}
	name := chi.URLParam(r, "*")
	feeds := s.autotuneFeedsSnapshot()
	revocations := feeds.NativeMTP.revocations
	if revocations == nil {
		writeError(w, http.StatusNotFound, "autotune_feed_not_found", "Autotune feed not found")
		return
	}
	var wantSig bool
	switch name {
	case revocations.keyID + ".json":
	case revocations.keyID + ".json.sig":
		wantSig = true
	default:
		writeError(w, http.StatusNotFound, "autotune_feed_not_found", "Autotune feed not found")
		return
	}
	slot, ok := revocations.current()
	if !ok {
		writeError(w, http.StatusNotFound, "autotune_feed_not_found", "Autotune feed not found")
		return
	}
	body := slot.body
	if wantSig {
		body = slot.sig
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if _, err := w.Write(body); err != nil {
		s.log.Warn().Err(err).Msg("write native-MTP revocation feed failed")
	}
}
