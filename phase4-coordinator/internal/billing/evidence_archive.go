package billing

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

// SPEC-022 R-15.3: the settled-evidence archive is gzip-compressed JSON
// lines with a sidecar manifest (internal/verifiedarchive). Every row is
// stored with every column so a settled credit can be rederived from the
// archive alone (R-15.7).
const (
	evidenceArchiveFormat         = "macprovider-settlement-evidence-archive-v1"
	evidenceArchiveSuffix         = verifiedarchive.Suffix
	evidenceArchiveManifestSuffix = verifiedarchive.ManifestSuffix
	evidenceArchiveRoleEvidence   = "evidence"
	evidenceArchiveRoleReference  = "reference"
	evidenceArchiveNamePrefix     = "settlement-evidence"
)

// ErrEvidenceArchiveInvalid marks an archive that failed re-verification;
// retention never deletes against it (SPEC-022 R-15.4).
var ErrEvidenceArchiveInvalid = verifiedarchive.ErrInvalid

// archiveRow is one database row keyed by column name. Values are int64,
// float64, string, nil, or archiveBlob.
type archiveRow map[string]any

// archiveBlob keeps BLOB values distinguishable from TEXT in JSON.
type archiveBlob = verifiedarchive.Blob

// EvidenceArchiveManifest is the sidecar written next to an archive.
type EvidenceArchiveManifest = verifiedarchive.Manifest

// archivedRequest is one request as read back from an archive.
type archivedRequest struct {
	RequestID string
	CreditIDs []int64
	// Rows holds every archived row of the request by table.
	Rows map[string][]archiveRow
	// Digest is the SHA-256 of the request's lines as stored, and Bytes
	// their length: a re-read is matched against a verified pass by Digest.
	Digest [sha256.Size]byte
	Bytes  int64
}

// verifiedEvidenceArchive is an archive whose bytes, lines, and counts were
// re-checked against its manifest. It keeps only each request's digest.
type verifiedEvidenceArchive = verifiedarchive.Verified

type evidenceArchiveWriter struct {
	w *verifiedarchive.Writer
}

// setSpaceGuard makes the writer call guard every step bytes of output.
func (w *evidenceArchiveWriter) setSpaceGuard(step int64, guard func() error) {
	w.w.SetSpaceGuard(step, guard)
}

func newEvidenceArchiveWriter(dir string, now time.Time, cutoff string) (*evidenceArchiveWriter, error) {
	w, err := verifiedarchive.NewWriter(dir, evidenceArchiveNamePrefix, evidenceArchiveFormat, now, cutoff)
	if err != nil {
		return nil, err
	}
	return &evidenceArchiveWriter{w: w}, nil
}

func archiveTableRows(table, role string, rows []archiveRow) verifiedarchive.TableRows {
	out := verifiedarchive.TableRows{Table: table, Role: role, Rows: make([]verifiedarchive.Row, len(rows))}
	for i, row := range rows {
		out.Rows[i] = row
	}
	return out
}

func (w *evidenceArchiveWriter) writeRequest(b requestEvidenceBundle) error {
	creditIDs := make([]int64, 0, len(b.credits))
	for _, c := range b.credits {
		creditIDs = append(creditIDs, c.id)
	}
	tables := make([]verifiedarchive.TableRows, 0, len(evidenceReferenceTables)+len(evidenceRetentionTables)+1)
	for _, table := range evidenceReferenceTables {
		tables = append(tables, archiveTableRows(table, evidenceArchiveRoleReference, b.reference[table]))
	}
	for _, table := range evidenceRetentionTables {
		tables = append(tables, archiveTableRows(table, evidenceArchiveRoleEvidence, b.evidence[table]))
	}
	tables = append(tables, archiveTableRows(evidenceRetentionJournalTable, evidenceArchiveRoleEvidence, b.routeJournal))
	return w.w.WriteGroup(b.requestID, creditIDs, tables)
}

// finish writes the trailer, makes the archive and its manifest durable, and
// returns the manifest.
func (w *evidenceArchiveWriter) finish() (EvidenceArchiveManifest, string, error) {
	return w.w.Finish()
}

func (w *evidenceArchiveWriter) abort() {
	if w == nil {
		return
	}
	w.w.Abort()
}

func readEvidenceArchiveManifest(archivePath string) (EvidenceArchiveManifest, error) {
	return verifiedarchive.ReadManifest(archivePath)
}

// verifyEvidenceArchive re-reads an archive from disk and checks it against
// the expected manifest (SPEC-022 R-15.4 step 1).
func verifyEvidenceArchive(archivePath string, expected EvidenceArchiveManifest) (verifiedEvidenceArchive, error) {
	if expected.Format != evidenceArchiveFormat {
		return verifiedEvidenceArchive{}, fmt.Errorf("%w: manifest format %q", ErrEvidenceArchiveInvalid, expected.Format)
	}
	return verifiedarchive.Verify(archivePath, expected, evidenceArchiveKnownTable)
}

// streamEvidenceArchive reads an archive once and calls visit with each
// complete request in file order. The whole-file checks complete only after
// the last visit, so a caller that acts on rows before the stream ends must
// match each request's Digest against a previously verified pass.
func streamEvidenceArchive(archivePath string, expected EvidenceArchiveManifest, visit func(archivedRequest) error) error {
	if expected.Format != evidenceArchiveFormat {
		return fmt.Errorf("%w: manifest format %q", ErrEvidenceArchiveInvalid, expected.Format)
	}
	return verifiedarchive.Stream(archivePath, expected, evidenceArchiveKnownTable, func(g verifiedarchive.Group) error {
		req := archivedRequest{RequestID: g.ID, CreditIDs: g.CreditIDs, Rows: make(map[string][]archiveRow, len(g.Rows)), Digest: g.Digest, Bytes: g.Bytes}
		for table, rows := range g.Rows {
			converted := make([]archiveRow, len(rows))
			for i, row := range rows {
				converted[i] = row
			}
			req.Rows[table] = converted
		}
		return visit(req)
	})
}

func evidenceArchiveKnownTable(table string) bool {
	if table == evidenceRetentionJournalTable {
		return true
	}
	for _, t := range evidenceRetentionTables {
		if t == table {
			return true
		}
	}
	for _, t := range evidenceReferenceTables {
		if t == table {
			return true
		}
	}
	return false
}

func normalizeArchiveValue(v any) any {
	return verifiedarchive.NormalizeValue(v)
}

func (r archiveRow) int64(col string) (int64, bool) {
	v, ok := r[col].(int64)
	return v, ok
}

func (r archiveRow) str(col string) (string, bool) {
	v, ok := r[col].(string)
	return v, ok
}

func (r archiveRow) isNull(col string) bool {
	v, ok := r[col]
	return !ok || v == nil
}

func (r archiveRow) nullInt(col string) *int64 {
	if v, ok := r.int64(col); ok {
		return &v
	}
	return nil
}

// ArchivedCreditRederivation is the R-15.7 check of one archived credit.
type ArchivedCreditRederivation struct {
	RequestCreditID        int64  `json:"request_credit_id"`
	RequestID              string `json:"request_id"`
	Basis                  string `json:"basis"`
	ArchivedGrossCredits   int64  `json:"archived_gross_credits"`
	ArchivedProviderCredit int64  `json:"archived_provider_credits"`
	RederivedGrossCredits  int64  `json:"rederived_gross_credits"`
	RederivedProviderCred  int64  `json:"rederived_provider_credits"`
	Matches                bool   `json:"matches"`
}

// RederiveArchivedCredit verifies the archive at archivePath against its
// manifest and recomputes one settled credit from archived rows alone
// (SPEC-022 R-15.7). An enforce credit is re-priced from its closed payable
// verdict's attempt-output usage exactly as the verified-receipt sync priced
// it; any other credit is re-priced from its own ledger token fields.
func RederiveArchivedCredit(archivePath string, requestCreditID int64) (ArchivedCreditRederivation, error) {
	manifest, err := readEvidenceArchiveManifest(archivePath)
	if err != nil {
		return ArchivedCreditRederivation{}, err
	}
	// One streaming pass keeps only the credit's request. It is used only
	// after the same pass verified the whole file it was read from.
	var found *archivedRequest
	var foundCredit archiveRow
	err = streamEvidenceArchive(archivePath, manifest, func(req archivedRequest) error {
		if found != nil {
			return nil
		}
		for _, credit := range req.Rows["ledger_request_credits"] {
			if id, _ := credit.int64("id"); id == requestCreditID {
				found, foundCredit = &req, credit
				return nil
			}
		}
		return nil
	})
	if err != nil {
		return ArchivedCreditRederivation{}, err
	}
	if found == nil {
		return ArchivedCreditRederivation{}, fmt.Errorf("request credit %d is not in archive %s", requestCreditID, filepath.Base(archivePath))
	}
	return rederiveArchivedCreditRow(*found, foundCredit)
}

func rederiveArchivedCreditRow(req archivedRequest, credit archiveRow) (ArchivedCreditRederivation, error) {
	id, _ := credit.int64("id")
	gross, _ := credit.int64("gross_credits")
	provider, _ := credit.int64("provider_credits")
	out := ArchivedCreditRederivation{RequestCreditID: id, RequestID: req.RequestID, ArchivedGrossCredits: gross, ArchivedProviderCredit: provider}
	promptRate, _ := credit.int64("prompt_rate_per_mtok")
	completionRate, _ := credit.int64("completion_rate_per_mtok")
	multiplier, _ := credit.int64("global_multiplier_ppm")
	share, _ := credit.int64("provider_share_bps")
	faultFlag, _ := credit.str("fault_flag")
	usageSource, _ := credit.str("usage_source")
	model, _ := credit.str("model")
	rateEntry := RateCardEntry{PromptCreditsPerMtok: promptRate, CompletionCreditsPerMtok: completionRate}
	cached := credit.nullInt("cached_prompt_tokens")
	if cached != nil && *cached > 0 {
		entry, err := archivedCacheRateEntry(req, credit, model)
		if err != nil {
			return out, err
		}
		rateEntry = entry
	} else {
		cached = nil
	}
	var result BilledRow
	if usageJSON, ok := archivedPayableUsage(req, credit); ok {
		var usage settlementUsageV04
		if err := json.Unmarshal([]byte(usageJSON), &usage); err != nil {
			return out, fmt.Errorf("decode archived usage: %w", err)
		}
		chargedPrompt := usage.BillableInputTokens
		if p := credit.nullInt("prompt_tokens"); p != nil && chargedPrompt > *p {
			chargedPrompt = *p
		}
		completion := usage.BillableOutputTokens
		result = ComputeCreditsWithCache(&chargedPrompt, cached, &completion, credit.nullInt("estimated_completion_tokens"), UsageProviderReported, faultFlag, rateEntry, multiplier, share)
		out.Basis = "receipt_bound_usage"
	} else {
		result = ComputeCreditsWithCache(credit.nullInt("prompt_tokens"), cached, credit.nullInt("completion_tokens"), credit.nullInt("estimated_completion_tokens"), usageSource, faultFlag, rateEntry, multiplier, share)
		out.Basis = "ledger_tokens"
	}
	out.RederivedGrossCredits = result.GrossCredits
	out.RederivedProviderCred = result.ProviderCredits
	out.Matches = result.GrossCredits == gross && result.ProviderCredits == provider
	return out, nil
}

// archivedPayableUsage is the attempt-output usage joined exactly as the
// payable view joins it for an enforce credit.
func archivedPayableUsage(req archivedRequest, credit archiveRow) (string, bool) {
	mode, _ := credit.str("settlement_policy_mode")
	scopeHash, okHash := credit.str("settlement_account_scope_hash")
	policy, okPolicy := credit.str("settlement_policy_version")
	if mode != RouteSnapshotModeEnforce || !okHash || !okPolicy {
		return "", false
	}
	attempt, _ := credit.int64("attempt_n")
	providerID, _ := credit.str("provider_id")
	for _, srv := range req.Rows["settlement_receipt_verdicts"] {
		if h, _ := srv.str("account_scope_hash"); h != scopeHash {
			continue
		}
		if a, _ := srv.int64("attempt_n"); a != attempt {
			continue
		}
		if p, _ := srv.str("provider_id"); p != providerID {
			continue
		}
		closed, _ := srv.int64("closed")
		outcome, _ := srv.str("settlement_outcome")
		srvMode, _ := srv.str("route_snapshot_mode")
		srvPolicy, _ := srv.str("route_snapshot_policy_version")
		digest, _ := srv.str("route_snapshot_digest")
		if closed != 1 || srvMode != RouteSnapshotModeEnforce || srvPolicy != policy {
			continue
		}
		if outcome != SettlementOutcomeVerified && outcome != SettlementOutcomeRelayBlindSettled {
			continue
		}
		for _, srs := range req.Rows["settlement_route_snapshots"] {
			d, _ := srs.str("route_snapshot_digest")
			a, _ := srs.int64("attempt_n")
			p, _ := srs.str("provider_id")
			if d != digest || a != attempt || p != providerID {
				continue
			}
			scope, _ := srs.str("account_scope")
			for _, sao := range req.Rows["settlement_attempt_outputs"] {
				s, _ := sao.str("account_scope")
				sa, _ := sao.int64("attempt_n")
				sp, _ := sao.str("provider_id")
				dup, _ := sao.int64("overlapping_or_duplicate")
				if s == scope && sa == attempt && sp == providerID && dup == 0 {
					usage, ok := sao.str("usage_canonical_json")
					return usage, ok
				}
			}
		}
	}
	return "", false
}

// archivedCacheRateEntry resolves a cached credit's cache-hit rate the way
// the verified-receipt sync did: the pool model's signed route rate, or the
// archived config snapshot's rate-card entry.
func archivedCacheRateEntry(req archivedRequest, credit archiveRow, model string) (RateCardEntry, error) {
	attempt, _ := credit.int64("attempt_n")
	providerID, _ := credit.str("provider_id")
	if poolmanifest.IsPoolModelID(model) {
		for _, srs := range req.Rows["settlement_route_snapshots"] {
			a, _ := srs.int64("attempt_n")
			p, _ := srs.str("provider_id")
			if a == attempt && p == providerID {
				raw, _ := srs.str("route_snapshot_json")
				return poolModelRateEntryFromRouteJSON(raw), nil
			}
		}
		return RateCardEntry{}, fmt.Errorf("cached pool-model credit has no archived route snapshot")
	}
	assigned, _ := credit.str("provider_assigned_id")
	var snapshotID int64
	var bestIdentityID int64 = -1
	for _, lpis := range req.Rows["ledger_provider_identity_snapshots"] {
		a, _ := lpis.int64("attempt_n")
		p, _ := lpis.str("provider_id")
		pa, _ := lpis.str("provider_assigned_id")
		rowID, _ := lpis.int64("id")
		cfgID, ok := lpis.int64("config_snapshot_id")
		if a == attempt && p == providerID && pa == assigned && ok && rowID > bestIdentityID {
			bestIdentityID, snapshotID = rowID, cfgID
		}
	}
	if bestIdentityID < 0 {
		return RateCardEntry{}, fmt.Errorf("cached credit has no archived config snapshot id")
	}
	for _, lcs := range req.Rows["ledger_config_snapshots"] {
		if id, _ := lcs.int64("id"); id == snapshotID {
			raw, _ := lcs.str("rate_card_json")
			var rateCard map[string]RateCardEntry
			if err := json.Unmarshal([]byte(raw), &rateCard); err != nil {
				return RateCardEntry{}, err
			}
			return RateFor(rateCard, model), nil
		}
	}
	return RateCardEntry{}, fmt.Errorf("cached credit config snapshot %d is not archived", snapshotID)
}

// VerifyEvidenceArchiveFile re-verifies an archive against its sidecar
// manifest and reports the manifest (operator restore procedure).
func VerifyEvidenceArchiveFile(archivePath string) (EvidenceArchiveManifest, error) {
	manifest, err := readEvidenceArchiveManifest(archivePath)
	if err != nil {
		return EvidenceArchiveManifest{}, err
	}
	if _, err := verifyEvidenceArchive(archivePath, manifest); err != nil {
		return EvidenceArchiveManifest{}, err
	}
	return manifest, nil
}
