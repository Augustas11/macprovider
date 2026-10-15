// Package verifiedarchive writes and re-verifies the coordinator's local
// row archives: gzip-compressed JSON lines with a sidecar manifest holding
// the file's SHA-256, byte size, group count, and per-table row counts.
// Settled-evidence retention (SPEC-022 R-15.3/R-15.4) and audit-log rotation
// (SPEC-002 R-7.10.2) both archive through it, so a row leaves a hot
// database only after the file holding it was re-read and verified.
package verifiedarchive

import (
	"bufio"
	"bytes"
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
)

const (
	// Suffix is the archive file suffix; ManifestSuffix is appended to the
	// archive path for its sidecar manifest.
	Suffix         = ".jsonl.gz"
	ManifestSuffix = ".manifest.json"
	// maxLineBytes bounds one decoded JSON line on re-read.
	maxLineBytes = 64 << 20
)

// ErrInvalid marks an archive that failed re-verification. Nothing may be
// deleted against it.
var ErrInvalid = errors.New("settlement evidence archive failed verification")

// Row is one database row keyed by column name. Values are int64, float64,
// string, nil, or Blob.
type Row = map[string]any

// Blob keeps BLOB values distinguishable from TEXT in JSON.
type Blob struct {
	Base64 string `json:"blob_base64"`
}

// line is one JSON line. The field names are the archive format: changing
// one breaks verification of every archive already written.
type line struct {
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

// Manifest is the sidecar written next to an archive. RequestCount counts
// the archive's groups (a request for settled evidence, a block of rows for
// the audit log).
type Manifest struct {
	Format             string           `json:"format"`
	ArchiveFile        string           `json:"archive_file"`
	SHA256             string           `json:"sha256"`
	SizeBytes          int64            `json:"size_bytes"`
	RequestCount       int              `json:"request_count"`
	RowCounts          map[string]int64 `json:"row_counts"`
	CutoffWindowEndUTC string           `json:"cutoff_window_end_utc"`
	CreatedAtUTC       string           `json:"created_at_utc"`
}

// TableRows is one table's rows of a group, written in order.
type TableRows struct {
	Table string
	Role  string
	Rows  []Row
}

// Group is one group as read back from an archive.
type Group struct {
	ID        string
	CreditIDs []int64
	// Rows holds every archived row of the group by table.
	Rows map[string][]Row
	// Digest is the SHA-256 of the group's lines as stored, and Bytes their
	// length: a re-read is matched against a verified pass by Digest.
	Digest [sha256.Size]byte
	Bytes  int64
}

// Verified is an archive whose bytes, lines, and counts were re-checked
// against its manifest. It keeps only each group's digest, never its rows,
// so verification memory does not grow with the archive's payload.
type Verified struct {
	Path     string
	Manifest Manifest
	Digests  map[string][sha256.Size]byte
}

// Writer writes one archive. The file becomes visible under its final name
// only after Finish made its bytes durable.
type Writer struct {
	dir       string
	format    string
	finalName string
	partial   *os.File
	hasher    hash.Hash
	counter   *countingWriter
	gz        *gzip.Writer
	buf       *bufio.Writer
	enc       *json.Encoder
	counts    map[string]int64
	groups    int
	createdAt string
	cutoff    string
}

// countingWriter counts the compressed archive bytes. With a guard set, it
// calls the guard before every guardStep bytes reach the file, splitting
// writes at those boundaries, so a guard error stops the archive within one
// step of output.
type countingWriter struct {
	w          io.Writer
	n          int64
	guard      func() error
	guardStep  int64
	sinceGuard int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	written := 0
	for len(p) > 0 {
		chunk := p
		if c.guard != nil && c.guardStep > 0 {
			if c.sinceGuard >= c.guardStep {
				if err := c.guard(); err != nil {
					return written, err
				}
				c.sinceGuard = 0
			}
			if room := c.guardStep - c.sinceGuard; int64(len(chunk)) > room {
				chunk = chunk[:room]
			}
		}
		n, err := c.w.Write(chunk)
		written += n
		c.n += int64(n)
		c.sinceGuard += int64(n)
		p = p[n:]
		if err != nil {
			return written, err
		}
		if n < len(chunk) {
			return written, io.ErrShortWrite
		}
	}
	return written, nil
}

// NewWriter creates <dir>/<namePrefix>-<UTC timestamp>-<nonce>.jsonl.gz as a
// partial file and writes the header line.
func NewWriter(dir, namePrefix, format string, now time.Time, cutoff string) (*Writer, error) {
	if strings.TrimSpace(dir) == "" || !filepath.IsAbs(dir) {
		return nil, fmt.Errorf("archive directory must be an absolute path")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create archive dir: %w", err)
	}
	var nonce [6]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	name := fmt.Sprintf("%s-%s-%s%s", namePrefix, now.UTC().Format("20060102T150405Z"), hex.EncodeToString(nonce[:]), Suffix)
	f, err := os.OpenFile(filepath.Join(dir, name+".partial"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, fmt.Errorf("create archive: %w", err)
	}
	h := sha256.New()
	counter := &countingWriter{w: io.MultiWriter(f, h)}
	gz := gzip.NewWriter(counter)
	buf := bufio.NewWriterSize(gz, 1<<20)
	w := &Writer{
		dir: dir, format: format, finalName: name, partial: f, hasher: h, counter: counter, gz: gz, buf: buf,
		enc: json.NewEncoder(buf), counts: map[string]int64{},
		createdAt: TimeText(now), cutoff: cutoff,
	}
	if err := w.enc.Encode(line{Kind: "header", Format: format, CreatedAt: w.createdAt, Cutoff: cutoff}); err != nil {
		w.Abort()
		return nil, err
	}
	return w, nil
}

// SetSpaceGuard makes the writer call guard every step bytes of output.
func (w *Writer) SetSpaceGuard(step int64, guard func() error) {
	w.counter.guard, w.counter.guardStep = guard, step
}

// Groups is the number of groups written so far.
func (w *Writer) Groups() int { return w.groups }

// WriteGroup writes one group: its group line, then every row of tables in
// order.
func (w *Writer) WriteGroup(id string, creditIDs []int64, tables []TableRows) error {
	if err := w.enc.Encode(line{Kind: "request", RequestID: id, CreditIDs: creditIDs}); err != nil {
		return err
	}
	for _, t := range tables {
		for _, row := range t.Rows {
			if err := w.enc.Encode(line{Kind: "row", RequestID: id, Table: t.Table, Role: t.Role, Row: rowJSON(row)}); err != nil {
				return err
			}
			w.counts[t.Table]++
		}
	}
	w.groups++
	return nil
}

// Finish writes the trailer, makes the archive and its manifest durable, and
// returns the manifest and the archive path.
func (w *Writer) Finish() (Manifest, string, error) {
	if err := w.enc.Encode(line{Kind: "trailer", RequestCount: w.groups, RowCounts: w.counts}); err != nil {
		w.Abort()
		return Manifest{}, "", err
	}
	if err := w.buf.Flush(); err != nil {
		w.Abort()
		return Manifest{}, "", err
	}
	if err := w.gz.Close(); err != nil {
		w.Abort()
		return Manifest{}, "", err
	}
	if err := w.partial.Sync(); err != nil {
		w.Abort()
		return Manifest{}, "", err
	}
	if err := w.partial.Close(); err != nil {
		_ = os.Remove(w.partial.Name())
		return Manifest{}, "", err
	}
	finalPath := filepath.Join(w.dir, w.finalName)
	if err := os.Rename(w.partial.Name(), finalPath); err != nil {
		_ = os.Remove(w.partial.Name())
		return Manifest{}, "", err
	}
	manifest := Manifest{
		Format:             w.format,
		ArchiveFile:        w.finalName,
		SHA256:             hex.EncodeToString(w.hasher.Sum(nil)),
		SizeBytes:          w.counter.n,
		RequestCount:       w.groups,
		RowCounts:          w.counts,
		CutoffWindowEndUTC: w.cutoff,
		CreatedAtUTC:       w.createdAt,
	}
	if err := WriteManifest(finalPath, manifest); err != nil {
		return Manifest{}, "", err
	}
	if err := FsyncDir(w.dir); err != nil {
		return Manifest{}, "", err
	}
	return manifest, finalPath, nil
}

// Abort removes the partial file. It is safe on a nil writer.
func (w *Writer) Abort() {
	if w == nil || w.partial == nil {
		return
	}
	_ = w.partial.Close()
	_ = os.Remove(w.partial.Name())
}

// WriteManifest writes the sidecar manifest of archivePath atomically.
func WriteManifest(archivePath string, manifest Manifest) error {
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	path := archivePath + ManifestSuffix
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

// FsyncDir makes directory entries durable.
func FsyncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// ReadManifest reads the sidecar manifest of archivePath.
func ReadManifest(archivePath string) (Manifest, error) {
	raw, err := os.ReadFile(archivePath + ManifestSuffix)
	if err != nil {
		return Manifest{}, err
	}
	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return Manifest{}, err
	}
	return m, nil
}

// Verify re-reads an archive from disk and checks it against the expected
// manifest: byte size, SHA-256, format, every line parsing, the trailer,
// and per-table row and group counts. It streams the file and keeps one
// group at a time.
func Verify(archivePath string, expected Manifest, knownTable func(string) bool) (Verified, error) {
	digests := map[string][sha256.Size]byte{}
	err := Stream(archivePath, expected, knownTable, func(g Group) error {
		digests[g.ID] = g.Digest
		return nil
	})
	if err != nil {
		return Verified{}, err
	}
	return Verified{Path: archivePath, Manifest: expected, Digests: digests}, nil
}

// Stream reads an archive once and calls visit with each complete group in
// file order; a group's rows follow its group line. The whole-file checks
// (size, SHA-256, counts, trailer) complete only after the last visit, so a
// caller that acts on rows before the stream ends must match each group's
// Digest against a previously verified pass.
func Stream(archivePath string, expected Manifest, knownTable func(string) bool, visit func(Group) error) error {
	invalid := func(format string, args ...any) error {
		return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, args...))
	}
	if expected.Format == "" {
		return invalid("manifest has no format")
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
	scanner.Buffer(make([]byte, 0, 1<<20), maxLineBytes)
	counts := map[string]int64{}
	seen := map[string]bool{}
	groups := 0
	var current *Group
	var currentHash hash.Hash
	flush := func() error {
		if current == nil {
			return nil
		}
		copy(current.Digest[:], currentHash.Sum(nil))
		g := *current
		current = nil
		return visit(g)
	}
	sawHeader, sawTrailer := false, false
	var trailer line
	for scanner.Scan() {
		if sawTrailer {
			return invalid("data after trailer")
		}
		raw := scanner.Bytes()
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		var ln line
		if err := dec.Decode(&ln); err != nil {
			return invalid("parse line: %v", err)
		}
		switch ln.Kind {
		case "header":
			if sawHeader || ln.Format != expected.Format {
				return invalid("bad header")
			}
			sawHeader = true
		case "request":
			if !sawHeader || ln.RequestID == "" {
				return invalid("request before header")
			}
			if seen[ln.RequestID] {
				return invalid("duplicate request %q", ln.RequestID)
			}
			if err := flush(); err != nil {
				return err
			}
			seen[ln.RequestID] = true
			groups++
			current = &Group{ID: ln.RequestID, CreditIDs: ln.CreditIDs, Rows: map[string][]Row{}}
			currentHash = sha256.New()
		case "row":
			if current == nil || ln.RequestID != current.ID || !knownTable(ln.Table) || ln.Row == nil {
				return invalid("row for unknown request or table")
			}
			row, err := rowFromJSON(ln.Row)
			if err != nil {
				return invalid("row value: %v", err)
			}
			current.Rows[ln.Table] = append(current.Rows[ln.Table], row)
			counts[ln.Table]++
		case "trailer":
			if err := flush(); err != nil {
				return err
			}
			sawTrailer = true
			trailer = ln
		default:
			return invalid("unknown line kind %q", ln.Kind)
		}
		if current != nil {
			_, _ = currentHash.Write(raw)
			_, _ = currentHash.Write([]byte{'\n'})
			current.Bytes += int64(len(raw)) + 1
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
	if groups != expected.RequestCount || trailer.RequestCount != expected.RequestCount {
		return invalid("request count %d, trailer %d, manifest %d", groups, trailer.RequestCount, expected.RequestCount)
	}
	if !equalRowCounts(counts, expected.RowCounts) || !equalRowCounts(trailer.RowCounts, expected.RowCounts) {
		return invalid("row counts differ from manifest")
	}
	return nil
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

func rowJSON(row Row) map[string]any {
	out := make(map[string]any, len(row))
	for k, v := range row {
		out[k] = v
	}
	return out
}

func rowFromJSON(raw map[string]any) (Row, error) {
	row := make(Row, len(raw))
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
			row[k] = Blob{Base64: b64}
		default:
			return nil, fmt.Errorf("column %s: unsupported value %T", k, v)
		}
	}
	return row, nil
}

// TimeText is the archive's fixed-width UTC timestamp text, the form the
// coordinator stores in SQLite.
func TimeText(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000000Z")
}

// NormalizeValue maps a database/sql scan value to an archive value.
func NormalizeValue(v any) any {
	switch t := v.(type) {
	case nil, int64, float64, string:
		return t
	case []byte:
		return Blob{Base64: base64.StdEncoding.EncodeToString(t)}
	case bool:
		if t {
			return int64(1)
		}
		return int64(0)
	case int:
		return int64(t)
	case time.Time:
		return TimeText(t)
	default:
		return fmt.Sprint(t)
	}
}

// RowsEqual compares two rows column by column. A REAL that holds an
// integral value is written to JSON without a fraction and reads back as an
// integer, so numbers compare by value.
func RowsEqual(a, b Row) bool {
	if len(a) != len(b) {
		return false
	}
	for col, av := range a {
		bv, ok := b[col]
		if !ok || !ValuesEqual(av, bv) {
			return false
		}
	}
	return true
}

// ValuesEqual compares two archive values.
func ValuesEqual(a, b any) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case string:
		y, ok := b.(string)
		return ok && x == y
	case Blob:
		y, ok := b.(Blob)
		return ok && x == y
	case int64:
		switch y := b.(type) {
		case int64:
			return x == y
		case float64:
			return float64(x) == y && int64(y) == x
		}
	case float64:
		switch y := b.(type) {
		case float64:
			return x == y
		case int64:
			return float64(y) == x && int64(x) == y
		}
	}
	return false
}
