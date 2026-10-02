package buyer

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

const (
	settlementReceiptRecoveryMaxPending  = 1024
	settlementReceiptRecoveryMaxWorkers  = 4
	settlementReceiptRecoveryMaxAttempts = 4
	settlementReceiptRecoveryBaseDelay   = 250 * time.Millisecond
)

type settlementReceiptRecoveryInput struct {
	identity              billing.SettlementReceiptIdentity
	header                string
	providerReceiptPubkey []byte
	poolLabels            *billing.SettlementPoolLabels
	// receivedAtUnixMS is the first observation of the receipt; every retry
	// re-uses it as the authoritative arrival time.
	receivedAtUnixMS int64
}

// settlementReceiptRetryable is the recovery-queue retry predicate: transient
// SQLite pressure, or a pool-authority read that could not decide.
func settlementReceiptRetryable(err error) bool {
	return settlementOutputPersistFailedAfterCredit(err) || errors.Is(err, billing.ErrPoolOperatorAttestationTransient)
}

type settlementReceiptRecoveryItem struct {
	key     string
	input   settlementReceiptRecoveryInput
	attempt int
}

type settlementReceiptPersistFunc func(context.Context, *billing.Store, settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error)

func persistSettlementReceiptDirect(ctx context.Context, store *billing.Store, input settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
	if input.header == "" {
		return store.RecordMissingSettlementReceipt(ctx, billing.SettlementReceiptMissingInput{
			SettlementReceiptIdentity: input.identity,
		})
	}
	if input.poolLabels != nil {
		// SPEC-022-R012.4: a pool attempt may settle pool_operator_attested.
		return store.IngestPoolSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
			SettlementReceiptIdentity: input.identity,
			Header:                    input.header,
			ProviderReceiptPubkey:     input.providerReceiptPubkey,
			PoolLabels:                input.poolLabels,
		}.WithReceivedAt(input.receivedAtUnixMS))
	}
	return store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: input.identity,
		Header:                    input.header,
		ProviderReceiptPubkey:     input.providerReceiptPubkey,
	}.WithReceivedAt(input.receivedAtUnixMS))
}

func (s *Server) persistSettlementReceipt(ctx context.Context, store *billing.Store, input settlementReceiptRecoveryInput) (billing.SettlementReceiptState, error) {
	persist := s.settlementReceiptPersist
	if persist == nil {
		persist = persistSettlementReceiptDirect
	}
	state, err := persist(ctx, store, input)
	if err == nil && input.poolLabels != nil && store != nil {
		s.recordSettlementPoolLabels(ctx, store, input)
	}
	return state, err
}

type settlementPoolLabelRecordFunc func(context.Context, *billing.Store, billing.SettlementReceiptIdentity, *billing.SettlementPoolLabels) (billing.SettlementPoolLabelRecord, error)

func recordSettlementPoolLabelsDirect(ctx context.Context, store *billing.Store, id billing.SettlementReceiptIdentity, labels *billing.SettlementPoolLabels) (billing.SettlementPoolLabelRecord, error) {
	return store.RecordSettlementPoolLabels(ctx, id, labels)
}

// recordSettlementPoolLabels stamps the SPEC-042 R006 labels after the verdict
// is durable. A failure only leaves the label unrecorded, which already keeps
// the request out of pool-scoped accounting; it never fails settlement.
//
// The synchronous receipt path shares one short deadline between the verdict
// and the label, so under SQLite pressure the label write could miss it and
// stay NULL on a verified verdict (#1816 VM acceptance A-4). The stamp is
// idempotent and a dispute is sticky, so an unrecorded label is retried in
// the background on its own deadline.
func (s *Server) recordSettlementPoolLabels(ctx context.Context, store *billing.Store, input settlementReceiptRecoveryInput) {
	rec, err := s.tryRecordSettlementPoolLabels(ctx, store, input)
	if err == nil {
		s.reportSettlementPoolLabel(rec, nil, input)
		return
	}
	if s.settlementPoolLabelRetries.Add(1) > settlementPoolLabelMaxBackground {
		s.settlementPoolLabelRetries.Add(-1)
		s.reportSettlementPoolLabel(rec, err, input)
		return
	}
	go func() {
		defer s.settlementPoolLabelRetries.Add(-1)
		for attempt := 0; attempt < settlementPoolLabelBackgroundAttempts; attempt++ {
			time.Sleep(settlementReceiptRecoveryBaseDelay << attempt)
			retryCtx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
			rec, err = s.tryRecordSettlementPoolLabels(retryCtx, store, input)
			cancel()
			if err == nil {
				break
			}
		}
		s.reportSettlementPoolLabel(rec, err, input)
	}()
}

func (s *Server) tryRecordSettlementPoolLabels(ctx context.Context, store *billing.Store, input settlementReceiptRecoveryInput) (billing.SettlementPoolLabelRecord, error) {
	record := s.settlementPoolLabelRecord
	if record == nil {
		record = recordSettlementPoolLabelsDirect
	}
	var rec billing.SettlementPoolLabelRecord
	var err error
	for attempt := 1; attempt <= settlementPoolLabelAttempts; attempt++ {
		rec, err = record(ctx, store, input.identity, input.poolLabels)
		if err == nil || ctx.Err() != nil {
			break
		}
		if attempt < settlementPoolLabelAttempts {
			time.Sleep(time.Duration(attempt) * settlementPoolLabelRetryBackoff)
		}
	}
	return rec, err
}

// reportSettlementPoolLabel logs a label that stayed unrecorded after every
// retry (terminal, operator-visible) or a disputed one.
func (s *Server) reportSettlementPoolLabel(rec billing.SettlementPoolLabelRecord, err error, input settlementReceiptRecoveryInput) {
	if err != nil {
		s.log.Error().Err(err).
			Str("event", "trusted_pool_label_unrecorded").
			Str("pool_id", input.poolLabels.PoolID).
			Str("request_id", input.identity.RequestID).
			Int64("attempt_n", input.identity.AttemptN).
			Str("provider_id", input.identity.ProviderID).
			Msg("trusted pool settlement label not recorded after retries; request excluded from pool-scoped accounting")
		return
	}
	if rec.Status != billing.PoolLabelStatusDisputed {
		return
	}
	// SPEC-042 R006 pool-audit event. Usage already settled under SPEC-005;
	// only pool-scoped attribution is withheld.
	s.log.Warn().
		Str("event", "trusted_pool_label_disputed").
		Str("pool_id", rec.PoolID).
		Uint64("routing_manifest_version", rec.ManifestVersion).
		Str("routing_manifest_core_digest", rec.ManifestCoreDigest).
		Uint64("settlement_manifest_version", input.poolLabels.ManifestVersion).
		Str("settlement_manifest_core_digest", input.poolLabels.ManifestCoreDigest).
		Str("route_snapshot_hash", rec.RouteSnapshotHash).
		Str("verdict_route_snapshot_digest", rec.VerdictRouteSnapshotDigest).
		Str("request_id", input.identity.RequestID).
		Int64("attempt_n", input.identity.AttemptN).
		Str("provider_id", input.identity.ProviderID).
		Msg("trusted pool settlement label disputed; request excluded from pool-scoped accounting")
}

// settlementPoolLabels captures the SPEC-042 R006 labels for the attempt being
// settled. When a route snapshot exists, prefer its immutable routing-time
// labels: ordinary manifest rotation, pause, or entry removal after dispatch
// must not turn an in-flight served request into an unverified label. Legacy
// pool routes that have no route snapshot still fall back to the live registry.
func (b *billingRecorder) settlementPoolLabels() *billing.SettlementPoolLabels {
	if b == nil || b.state == nil || b.state.poolID == "" {
		return nil
	}
	labels := &billing.SettlementPoolLabels{
		PoolID:            b.state.poolID,
		RouteSnapshotHash: b.settlementRouteSnapshotDigest,
	}
	if snap := b.settlementRouteSnapshot; snap != nil && snap.PoolID == b.state.poolID {
		labels.ManifestVersion = snap.ManifestVersion
		labels.ManifestCoreDigest = snap.ManifestCoreDigest
		return labels
	}
	if b.server != nil && b.server.trustPools != nil {
		if snap := b.server.trustPools.Snapshot(b.state.poolID); snap.Exists {
			labels.ManifestVersion = snap.ManifestVersion
			labels.ManifestCoreDigest = snap.ManifestCoreDigest
		}
	}
	return labels
}

const (
	settlementPoolLabelAttempts     = 3
	settlementPoolLabelRetryBackoff = 50 * time.Millisecond
	// Background label retries: bounded in count and in flight.
	settlementPoolLabelBackgroundAttempts = 5
	settlementPoolLabelMaxBackground      = 256
)

func settlementReceiptRecoveryKey(input settlementReceiptRecoveryInput) string {
	digest := sha256.Sum256([]byte(input.header))
	return fmt.Sprintf("%s\x00%s\x00%d\x00%s\x00%x", input.identity.AccountScope, input.identity.RequestID, input.identity.AttemptN, input.identity.ProviderID, digest)
}

func (b *billingRecorder) deferredSettlementReceiptState(input settlementReceiptRecoveryInput) billing.SettlementReceiptState {
	mode, version := b.settlementPolicyForLedger()
	return billing.SettlementReceiptState{
		SettlementReceiptIdentity:  input.identity,
		ReceiptPresent:             input.header != "",
		ReceiptResult:              billing.SettlementReceiptResultInconclusive,
		SettlementOutcome:          billing.SettlementOutcomePending,
		Reason:                     "receipt_verdict_pending",
		RouteSnapshotMode:          mode,
		RouteSnapshotPolicyVersion: version,
	}
}

// deferSettlementReceiptRecovery preserves the successful buyer response when
// the receipt verdict write encounters transient SQLite pressure. The signed
// receipt remains memory-only and is retried through a bounded, coalesced
// worker queue; raw receipt bytes are never written to a recovery table.
func (s *Server) deferSettlementReceiptRecovery(input settlementReceiptRecoveryInput) bool {
	key := settlementReceiptRecoveryKey(input)
	s.settlementReceiptRecoveryMu.Lock()
	defer s.settlementReceiptRecoveryMu.Unlock()
	if s.settlementReceiptRecoveryKeys == nil {
		s.settlementReceiptRecoveryKeys = make(map[string]struct{})
	}
	if _, exists := s.settlementReceiptRecoveryKeys[key]; exists {
		return true
	}
	if len(s.settlementReceiptRecoveryKeys) >= settlementReceiptRecoveryMaxPending {
		s.log.Error().
			Str("request_id", input.identity.RequestID).
			Str("provider_id", input.identity.ProviderID).
			Int("queue_limit", settlementReceiptRecoveryMaxPending).
			Msg("settlement receipt recovery queue full")
		return false
	}
	s.settlementReceiptRecoveryKeys[key] = struct{}{}
	s.settlementReceiptRecoveryPending = append(s.settlementReceiptRecoveryPending, settlementReceiptRecoveryItem{
		key:     key,
		input:   input,
		attempt: 2,
	})
	if s.settlementReceiptRecoveryWorkers < settlementReceiptRecoveryMaxWorkers {
		s.settlementReceiptRecoveryWorkers++
		go s.drainSettlementReceiptRecoveries()
	}
	return true
}

func (s *Server) drainSettlementReceiptRecoveries() {
	for {
		s.settlementReceiptRecoveryMu.Lock()
		if len(s.settlementReceiptRecoveryPending) == 0 {
			s.settlementReceiptRecoveryWorkers--
			s.settlementReceiptRecoveryMu.Unlock()
			return
		}
		item := s.settlementReceiptRecoveryPending[0]
		s.settlementReceiptRecoveryPending = s.settlementReceiptRecoveryPending[1:]
		s.settlementReceiptRecoveryMu.Unlock()

		delay := settlementReceiptRecoveryBaseDelay << (item.attempt - 2)
		timer := time.NewTimer(delay)
		<-timer.C

		store, _, _ := s.billingState()
		var err error
		retryable := false
		if store == nil {
			err = fmt.Errorf("billing store unavailable")
			retryable = true
		} else {
			ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
			_, err = s.persistSettlementReceipt(ctx, store, item.input)
			cancel()
			retryable = settlementReceiptRetryable(err)
		}
		if err == nil {
			s.finishSettlementReceiptRecovery(item.key)
			s.log.Info().
				Str("request_id", item.input.identity.RequestID).
				Str("provider_id", item.input.identity.ProviderID).
				Int("attempt", item.attempt).
				Msg("settlement receipt recovery succeeded")
			continue
		}
		if retryable && item.attempt < settlementReceiptRecoveryMaxAttempts {
			item.attempt++
			s.settlementReceiptRecoveryMu.Lock()
			s.settlementReceiptRecoveryPending = append(s.settlementReceiptRecoveryPending, item)
			s.settlementReceiptRecoveryMu.Unlock()
			s.log.Warn().
				Err(err).
				Str("request_id", item.input.identity.RequestID).
				Str("provider_id", item.input.identity.ProviderID).
				Int("next_attempt", item.attempt).
				Msg("settlement receipt recovery retry scheduled")
			continue
		}
		s.finishSettlementReceiptRecovery(item.key)
		s.log.Error().
			Err(err).
			Str("request_id", item.input.identity.RequestID).
			Str("provider_id", item.input.identity.ProviderID).
			Int("attempt", item.attempt).
			Msg("settlement receipt recovery exhausted")
	}
}

func (s *Server) finishSettlementReceiptRecovery(key string) {
	s.settlementReceiptRecoveryMu.Lock()
	delete(s.settlementReceiptRecoveryKeys, key)
	s.settlementReceiptRecoveryMu.Unlock()
}
