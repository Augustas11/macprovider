package billing

import (
	"bufio"
	"compress/gzip"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
)

// SPEC-022 R-15.3: the settled-evidence archive is gzip-compressed JSON
// lines with a sidecar manifest. Every row is stored with every column so a
// settled credit can be rederived from the archive alone (R-15.7).
const (
	evidenceArchiveFormat         = "macprovider-settlement-evidence-archive-v1"
	evidenceArchiveSuffix         = ".jsonl.gz"
	evidenceArchiveManifestSuffix = ".manifest.json"
	evidenceArchiveRoleEvidence   = "evidence"
	evidenceArchiveRoleReference  = "reference"
	// evidenceArchiveMaxLineBytes bounds one decoded JSON line on re-read.
	evidenceArchiveMaxLineBytes = 64 << 20
)

// ErrEvidenceArchiveInvalid marks an archive that failed re-verification;
// retention never deletes against it (SPEC-022 R-15.4).
var ErrEvidenceArchiveInvalid = errors.New("settlement evidence archive failed verification")

// archiveRow is one database row keyed by column name. Values are int64,
// float64, string, nil, or archiveBlob.
type archiveRow map[string]any

// archiveBlob keeps BLOB values distinguishable from TEXT in JSON.
type archiveBlob struct {
	Base64 string `json:"blob_base64"`
}

type evidenceArchiveLine struct {
	Kind      string `json:"kind"`
	Format    string `json:"format,omitempty"`
	CreatedAt string `json:"created_at_utc,omitempty"`
	Cutoff    string `json:"cutoff_window_end_utc,omitempty"`
	RequestID string `json:"request_id,omitempty"`
	Table     string `json:"table,omitempty"`
	Role      string `json:"role,omitempty"`
	// Row is decoded with UseNumber so integers survive round trip.
	Row          map[string]any   `json:"row,omitempty"`
	CreditIDs    []int64          `json:"credit_ids,omitempty"`
	RequestCount int              `json:"request_count,omitempty"`
	RowCounts    map[string]int64 `json:"row_counts,omitempty"`
}

// EvidenceArchiveManifest is the sidecar written next to an archive.
type EvidenceArchiveManifest struct {
	Format             string           `json:"format"`
	ArchiveFile        string           `json:"archive_file"`
	SHA256             string           `json:"sha256"`
	SizeBytes          int64            `json:"size_bytes"`
	RequestCount       int              `json:"request_count"`
	RowCounts          map[string]int64 `json:"row_counts"`
	CutoffWindowEndUTC string           `json:"cutoff_window_end_utc"`
	CreatedAtUTC       string           `json:"created_at_utc"`
}

// archivedRequest is one request as read back from a verified archive.
type archivedRequest struct {
	RequestID string
	CreditIDs []int64
	// Rows holds every archived row of the request by table.
	Rows map[string][]archiveRow
}

// verifiedEvidenceArchive is an archive whose bytes, lines, and counts were
// re-checked against its manifest.
type verifiedEvidenceArchive struct {
	Path     string
	Manifest EvidenceArchiveManifest
	Requests []archivedRequest
}

type evidenceArchiveWriter struct {
	dir       string
	finalName string
	partial   *os.File
	hasher    hash.Hash
	counter   *countingWriter
	gz        *gzip.Writer
	buf       *bufio.Writer
	enc       *json.Encoder
	counts    map[string]int64
	requests  int
	createdAt string
	cutoff    string
}

type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

func newEvidenceArchiveWriter(dir string, now time.Time, cutoff string) (*evidenceArchiveWriter, error) {
	if strings.TrimSpace(dir) == "" || !filepath.IsAbs(dir) {
		return nil, fmt.Errorf("settlement evidence archive_dir must be an absolute path")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create archive dir: %w", err)
	}
	var nonce [6]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	name := fmt.Sprintf("settlement-evidence-%s-%s%s", now.UTC().Format("20060102T150405Z"), hex.EncodeToString(nonce[:]), evidenceArchiveSuffix)
	f, err := os.OpenFile(filepath.Join(dir, name+".partial"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create archive: %w", err)
	}
	h := sha256.New()
	counter := &countingWriter{w: io.MultiWriter(f, h)}
	gz := gzip.NewWriter(counter)
	buf := bufio.NewWriterSize(gz, 1<<20)
	w := &evidenceArchiveWriter{
		dir: dir, finalName: name, partial: f, hasher: h, counter: counter, gz: gz, buf: buf,
		enc: json.NewEncoder(buf), counts: map[string]int64{},
		createdAt: sqliteTimeText(now), cutoff: cutoff,
	}
	if err := w.enc.Encode(evidenceArchiveLine{Kind: "header", Format: evidenceArchiveFormat, CreatedAt: w.createdAt, Cutoff: cutoff}); err != nil {
		w.abort()
		return nil, err
	}
	return w, nil
}

func (w *evidenceArchiveWriter) writeRequest(b requestEvidenceBundle) error {
	creditIDs := make([]int64, 0, len(b.credits))
	for _, c := range b.credits {
		creditIDs = append(creditIDs, c.id)
	}
	if err := w.enc.Encode(evidenceArchiveLine{Kind: "request", RequestID: b.requestID, CreditIDs: creditIDs}); err != nil {
		return err
	}
	write := func(table, role string, rows []archiveRow) error {
		for _, row := range rows {
			if err := w.enc.Encode(evidenceArchiveLine{Kind: "row", RequestID: b.requestID, Table: table, Role: role, Row: archiveRowJSON(row)}); err != nil {
				return err
			}
			w.counts[table]++
		}
		return nil
	}
	for _, table := range evidenceReferenceTables {
		if err := write(table, evidenceArchiveRoleReference, b.reference[table]); err != nil {
			return err
		}
	}
	for _, table := range evidenceRetentionTables {
		if err := write(table, evidenceArchiveRoleEvidence, b.evidence[table]); err != nil {
			return err
		}
	}
	w.requests++
	return nil
}

// finish writes the trailer, makes the archive and its manifest durable, and
// returns the manifest. The archive becomes visible under its final name only
// after its bytes are fsynced.
func (w *evidenceArchiveWriter) finish() (EvidenceArchiveManifest, string, error) {
	if err := w.enc.Encode(evidenceArchiveLine{Kind: "trailer", RequestCount: w.requests, RowCounts: w.counts}); err != nil {
		w.abort()
		return EvidenceArchiveManifest{}, "", err
	}
	if err := w.buf.Flush(); err != nil {
		w.abort()
		return EvidenceArchiveManifest{}, "", err
	}
	if err := w.gz.Close(); err != nil {
		w.abort()
		return EvidenceArchiveManifest{}, "", err
	}
	if err := w.partial.Sync(); err != nil {
		w.abort()
		return EvidenceArchiveManifest{}, "", err
	}
	if err := w.partial.Close(); err != nil {
		_ = os.Remove(w.partial.Name())
		return EvidenceArchiveManifest{}, "", err
	}
	finalPath := filepath.Join(w.dir, w.finalName)
	if err := os.Rename(w.partial.Name(), finalPath); err != nil {
		_ = os.Remove(w.partial.Name())
		return EvidenceArchiveManifest{}, "", err
	}
	manifest := EvidenceArchiveManifest{
		Format:             evidenceArchiveFormat,
		ArchiveFile:        w.finalName,
		SHA256:             hex.EncodeToString(w.hasher.Sum(nil)),
		SizeBytes:          w.counter.n,
		RequestCount:       w.requests,
		RowCounts:          w.counts,
		CutoffWindowEndUTC: w.cutoff,
		CreatedAtUTC:       w.createdAt,
	}
	if err := writeEvidenceArchiveManifest(finalPath, manifest); err != nil {
		return EvidenceArchiveManifest{}, "", err
	}
	if err := fsyncDir(w.dir); err != nil {
		return EvidenceArchiveManifest{}, "", err
	}
	return manifest, finalPath, nil
}

func (w *evidenceArchiveWriter) abort() {
	if w == nil || w.partial == nil {
		return
	}
	_ = w.partial.Close()
	_ = os.Remove(w.partial.Name())
}

func writeEvidenceArchiveManifest(archivePath string, manifest EvidenceArchiveManifest) error {
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	path := archivePath + evidenceArchiveManifestSuffix
	tmp := path + ".partial"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(raw, '\n')); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

func fsyncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func readEvidenceArchiveManifest(archivePath string) (EvidenceArchiveManifest, error) {
	raw, err := os.ReadFile(archivePath + evidenceArchiveManifestSuffix)
	if err != nil {
		return EvidenceArchiveManifest{}, err
	}
	var m EvidenceArchiveManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return EvidenceArchiveManifest{}, err
	}
	return m, nil
}

// verifyEvidenceArchive re-reads an archive from disk and checks it against
// the expected manifest: byte size, SHA-256, format, every line parsing, the
// trailer, and per-table row and request counts (SPEC-022 R-15.4 step 1).
func verifyEvidenceArchive(archivePath string, expected EvidenceArchiveManifest) (verifiedEvidenceArchive, error) {
	invalid := func(format string, args ...any) (verifiedEvidenceArchive, error) {
		return verifiedEvidenceArchive{}, fmt.Errorf("%w: %s", ErrEvidenceArchiveInvalid, fmt.Sprintf(format, args...))
	}
	if expected.Format != evidenceArchiveFormat {
		return invalid("manifest format %q", expected.Format)
	}
	f, err := os.Open(archivePath)
	if err != nil {
		return invalid("open: %v", err)
	}
	defer f.Close()
	h := sha256.New()
	counter := &countingWriter{w: h}
	gz, err := gzip.NewReader(io.TeeReader(f, counter))
	if err != nil {
		return invalid("gzip: %v", err)
	}
	scanner := bufio.NewScanner(gz)
	scanner.Buffer(make([]byte, 0, 1<<20), evidenceArchiveMaxLineBytes)
	counts := map[string]int64{}
	var requests []archivedRequest
	byID := map[string]int{}
	sawHeader, sawTrailer := false, false
	var trailer evidenceArchiveLine
	for scanner.Scan() {
		if sawTrailer {
			return invalid("data after trailer")
		}
		dec := json.NewDecoder(strings.NewReader(scanner.Text()))
		dec.UseNumber()
		var line evidenceArchiveLine
		if err := dec.Decode(&line); err != nil {
			return invalid("parse line: %v", err)
		}
		switch line.Kind {
		case "header":
			if sawHeader || line.Format != evidenceArchiveFormat {
				return invalid("bad header")
			}
			sawHeader = true
		case "request":
			if !sawHeader || line.RequestID == "" {
				return invalid("request before header")
			}
			if _, dup := byID[line.RequestID]; dup {
				return invalid("duplicate request %q", line.RequestID)
			}
			byID[line.RequestID] = len(requests)
			requests = append(requests, archivedRequest{RequestID: line.RequestID, CreditIDs: line.CreditIDs, Rows: map[string][]archiveRow{}})
		case "row":
			idx, ok := byID[line.RequestID]
			if !ok || !evidenceArchiveKnownTable(line.Table) || line.Row == nil {
				return invalid("row for unknown request or table")
			}
			row, err := archiveRowFromJSON(line.Row)
			if err != nil {
				return invalid("row value: %v", err)
			}
			requests[idx].Rows[line.Table] = append(requests[idx].Rows[line.Table], row)
			counts[line.Table]++
		case "trailer":
			sawTrailer = true
			trailer = line
		default:
			return invalid("unknown line kind %q", line.Kind)
		}
	}
	if err := scanner.Err(); err != nil {
		return invalid("read: %v", err)
	}
	if err := gz.Close(); err != nil {
		return invalid("gzip close: %v", err)
	}
	// Drain any bytes after the gzip stream so size and digest cover the file.
	if _, err := io.Copy(io.Discard, io.TeeReader(f, counter)); err != nil {
		return invalid("read tail: %v", err)
	}
	if !sawHeader || !sawTrailer {
		return invalid("missing header or trailer")
	}
	if counter.n != expected.SizeBytes {
		return invalid("size %d, manifest %d", counter.n, expected.SizeBytes)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != expected.SHA256 {
		return invalid("sha256 %s, manifest %s", got, expected.SHA256)
	}
	if len(requests) != expected.RequestCount || trailer.RequestCount != expected.RequestCount {
		return invalid("request count %d, trailer %d, manifest %d", len(requests), trailer.RequestCount, expected.RequestCount)
	}
	if !equalRowCounts(counts, expected.RowCounts) || !equalRowCounts(trailer.RowCounts, expected.RowCounts) {
		return invalid("row counts differ from manifest")
	}
	return verifiedEvidenceArchive{Path: archivePath, Manifest: expected, Requests: requests}, nil
}

func equalRowCounts(a, b map[string]int64) bool {
	norm := func(m map[string]int64) map[string]int64 {
		out := map[string]int64{}
		for k, v := range m {
			if v != 0 {
				out[k] = v
			}
		}
		return out
	}
	na, nb := norm(a), norm(b)
	if len(na) != len(nb) {
		return false
	}
	for k, v := range na {
		if nb[k] != v {
			return false
		}
	}
	return true
}

func evidenceArchiveKnownTable(table string) bool {
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

func archiveRowJSON(row archiveRow) map[string]any {
	out := make(map[string]any, len(row))
	for k, v := range row {
		out[k] = v
	}
	return out
}

func archiveRowFromJSON(raw map[string]any) (archiveRow, error) {
	row := make(archiveRow, len(raw))
	for k, v := range raw {
		switch t := v.(type) {
		case nil, string:
			row[k] = t
		case json.Number:
			if i, err := t.Int64(); err == nil {
				row[k] = i
				continue
			}
			f, err := t.Float64()
			if err != nil {
				return nil, err
			}
			row[k] = f
		case map[string]any:
			b64, ok := t["blob_base64"].(string)
			if !ok || len(t) != 1 {
				return nil, fmt.Errorf("column %s: unsupported object", k)
			}
			if _, err := base64.StdEncoding.DecodeString(b64); err != nil {
				return nil, fmt.Errorf("column %s: %w", k, err)
			}
			row[k] = archiveBlob{Base64: b64}
		default:
			return nil, fmt.Errorf("column %s: unsupported value %T", k, v)
		}
	}
	return row, nil
}

func normalizeArchiveValue(v any) any {
	switch t := v.(type) {
	case nil, int64, float64, string:
		return t
	case []byte:
		return archiveBlob{Base64: base64.StdEncoding.EncodeToString(t)}
	case bool:
		if t {
			return int64(1)
		}
		return int64(0)
	case int:
		return int64(t)
	case time.Time:
		return sqliteTimeText(t)
	default:
		return fmt.Sprint(t)
	}
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
	archive, err := verifyEvidenceArchive(archivePath, manifest)
	if err != nil {
		return ArchivedCreditRederivation{}, err
	}
	for _, req := range archive.Requests {
		for _, credit := range req.Rows["ledger_request_credits"] {
			if id, _ := credit.int64("id"); id == requestCreditID {
				return rederiveArchivedCreditRow(req, credit)
			}
		}
	}
	return ArchivedCreditRederivation{}, fmt.Errorf("request credit %d is not in archive %s", requestCreditID, filepath.Base(archivePath))
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
