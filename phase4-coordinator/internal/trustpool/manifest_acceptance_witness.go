package trustpool

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"time"
)

const manifestAcceptanceWitnessSchema = "macprovider.trustpool_manifest_acceptance_witness.v1"

type manifestAcceptanceWitnessFile struct {
	SchemaVersion string                           `json:"schema_version"`
	Pools         []manifestAcceptanceWitnessEntry `json:"pools"`
}

type manifestAcceptanceWitnessEntry struct {
	PoolID                 string `json:"pool_id"`
	ManifestVersion        uint64 `json:"manifest_version"`
	OperationID            string `json:"operation_id"`
	AcceptedAtUTC          string `json:"accepted_at_utc"`
	ManifestCoreDigest     string `json:"manifest_core_digest"`
	RootIssuerKeyID        string `json:"root_issuer_key_id"`
	RootIssuerPublicKeyFP  string `json:"root_issuer_public_key_fingerprint"`
	ManifestSignature      string `json:"manifest_signature"`
	ManifestSnapshotSHA256 string `json:"manifest_snapshot_sha256"`
}

func (s *Store) verifyManifestAcceptanceWitness(ctx context.Context) error {
	if s == nil || s.manifestWitnessPath == "" {
		return nil
	}
	return withManifestAcceptanceWitnessConn(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		highWater, err := manifestAcceptanceHighWaterFromQueryer(ctx, conn)
		if err != nil {
			return err
		}
		return s.reconcileManifestAcceptanceWitness(highWater)
	})
}

func (s *Store) reconcileManifestAcceptanceWitness(highWater map[string]ManifestAcceptanceProjection) error {
	if s == nil || s.manifestWitnessPath == "" {
		return nil
	}
	witness, found, err := readManifestAcceptanceWitness(s.manifestWitnessPath)
	if err != nil {
		return err
	}
	if !found {
		if len(highWater) > 0 {
			return fmt.Errorf("%w: manifest acceptance witness %q missing while coordinator db already has accepted manifest high-water", ErrMalformedDurableEvent, s.manifestWitnessPath)
		}
		return writeManifestAcceptanceWitness(s.manifestWitnessPath, highWater)
	}
	next := make(map[string]ManifestAcceptanceProjection, len(witness))
	for poolID, witnessed := range witness {
		current, ok := highWater[poolID]
		if !ok {
			return fmt.Errorf("%w: manifest acceptance witness pool %q missing from coordinator db", ErrMalformedDurableEvent, poolID)
		}
		switch {
		case current.ManifestVersion < witnessed.ManifestVersion:
			return fmt.Errorf("%w: manifest acceptance witness pool %q version rollback %d < %d", ErrMalformedDurableEvent, poolID, current.ManifestVersion, witnessed.ManifestVersion)
		case current.ManifestVersion == witnessed.ManifestVersion && !manifestAcceptanceProjectionEqual(current, witnessed):
			return fmt.Errorf("%w: manifest acceptance witness pool %q high-water mismatch at version %d", ErrMalformedDurableEvent, poolID, current.ManifestVersion)
		}
		next[poolID] = current
	}
	for poolID, current := range highWater {
		if _, ok := next[poolID]; !ok {
			next[poolID] = current
		}
	}
	return writeManifestAcceptanceWitness(s.manifestWitnessPath, next)
}

func withManifestAcceptanceWitnessConn(ctx context.Context, db *sql.DB, fn func(context.Context, *sql.Conn) error) error {
	conn, err := db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	return fn(ctx, conn)
}

func readManifestAcceptanceWitness(path string) (map[string]ManifestAcceptanceProjection, bool, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	var file manifestAcceptanceWitnessFile
	if err := json.Unmarshal(raw, &file); err != nil {
		return nil, false, fmt.Errorf("%w: manifest acceptance witness JSON: %v", ErrMalformedDurableEvent, err)
	}
	if file.SchemaVersion != manifestAcceptanceWitnessSchema {
		return nil, false, fmt.Errorf("%w: manifest acceptance witness schema %q", ErrMalformedDurableEvent, file.SchemaVersion)
	}
	out := make(map[string]ManifestAcceptanceProjection, len(file.Pools))
	for _, entry := range file.Pools {
		p, err := projectionFromWitnessEntry(entry)
		if err != nil {
			return nil, false, err
		}
		if _, exists := out[p.PoolID]; exists {
			return nil, false, fmt.Errorf("%w: duplicate manifest acceptance witness pool %q", ErrMalformedDurableEvent, p.PoolID)
		}
		out[p.PoolID] = p
	}
	return out, true, nil
}

func writeManifestAcceptanceWitness(path string, highWater map[string]ManifestAcceptanceProjection) error {
	file := manifestAcceptanceWitnessFile{
		SchemaVersion: manifestAcceptanceWitnessSchema,
		Pools:         make([]manifestAcceptanceWitnessEntry, 0, len(highWater)),
	}
	poolIDs := make([]string, 0, len(highWater))
	for poolID := range highWater {
		poolIDs = append(poolIDs, poolID)
	}
	slices.Sort(poolIDs)
	for _, poolID := range poolIDs {
		file.Pools = append(file.Pools, witnessEntryFromProjection(highWater[poolID]))
	}
	raw, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".manifest-acceptance-witness-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(raw); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

func witnessEntryFromProjection(p ManifestAcceptanceProjection) manifestAcceptanceWitnessEntry {
	return manifestAcceptanceWitnessEntry{
		PoolID:                 p.PoolID,
		ManifestVersion:        p.ManifestVersion,
		OperationID:            p.OperationID,
		AcceptedAtUTC:          p.AcceptedAtUTC.UTC().Format(time.RFC3339Nano),
		ManifestCoreDigest:     p.ManifestCoreDigest,
		RootIssuerKeyID:        p.RootIssuerKeyID,
		RootIssuerPublicKeyFP:  p.RootIssuerPublicKeyFP,
		ManifestSignature:      p.ManifestSignature,
		ManifestSnapshotSHA256: p.ManifestSnapshotSHA256,
	}
}

func projectionFromWitnessEntry(entry manifestAcceptanceWitnessEntry) (ManifestAcceptanceProjection, error) {
	acceptedAt, err := time.Parse(time.RFC3339Nano, entry.AcceptedAtUTC)
	if err != nil {
		return ManifestAcceptanceProjection{}, fmt.Errorf("%w: manifest acceptance witness accepted_at_utc: %v", ErrMalformedDurableEvent, err)
	}
	p := ManifestAcceptanceProjection{
		PoolID:                 entry.PoolID,
		ManifestVersion:        entry.ManifestVersion,
		OperationID:            entry.OperationID,
		AcceptedAtUTC:          acceptedAt.UTC(),
		ManifestCoreDigest:     entry.ManifestCoreDigest,
		RootIssuerKeyID:        entry.RootIssuerKeyID,
		RootIssuerPublicKeyFP:  entry.RootIssuerPublicKeyFP,
		ManifestSignature:      entry.ManifestSignature,
		ManifestSnapshotSHA256: entry.ManifestSnapshotSHA256,
	}
	if p.PoolID == "" || p.ManifestVersion == 0 || p.OperationID == "" || p.ManifestCoreDigest == "" || p.ManifestSnapshotSHA256 == "" {
		return ManifestAcceptanceProjection{}, fmt.Errorf("%w: incomplete manifest acceptance witness entry", ErrMalformedDurableEvent)
	}
	return p, nil
}
