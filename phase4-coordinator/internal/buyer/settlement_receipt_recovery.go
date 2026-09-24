package buyer

import (
	"context"
	"crypto/sha256"
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
		})
	}
	return store.IngestSettlementReceipt(ctx, billing.SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: input.identity,
		Header:                    input.header,
		ProviderReceiptPubkey:     input.providerReceiptPubkey,
	})
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

// recordSettlementPoolLabels stamps the SPEC-042 R006 labels after the verdict
// is durable. A failure only leaves the label unrecorded, which already keeps
// the request out of pool-scoped accounting; it never fails settlement.
func (s *Server) recordSettlementPoolLabels(ctx context.Context, store *billing.Store, input settlementReceiptRecoveryInput) {
	var rec billing.SettlementPoolLabelRecord
	var err error
	// A transient store failure is retried; a persistent one is logged as a
	// terminal, operator-visible event. Either way the request stays out of
	// pool-scoped accounting, because only a verified label counts there.
	for attempt := 1; attempt <= settlementPoolLabelAttempts; attempt++ {
		rec, err = store.RecordSettlementPoolLabels(ctx, input.identity, input.poolLabels)
		if err == nil || ctx.Err() != nil {
			break
		}
		if attempt < settlementPoolLabelAttempts {
			time.Sleep(time.Duration(attempt) * settlementPoolLabelRetryBackoff)
		}
	}
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

// settlementPoolLabels captures the SPEC-042 R006 settlement-time labels: the
// selected pool, its manifest as the live registry holds it now, and the route
// snapshot digest recorded at routing time. nil for global traffic.
func (b *billingRecorder) settlementPoolLabels() *billing.SettlementPoolLabels {
	if b == nil || b.state == nil || b.state.poolID == "" {
		return nil
	}
	labels := &billing.SettlementPoolLabels{
		PoolID:            b.state.poolID,
		RouteSnapshotHash: b.settlementRouteSnapshotDigest,
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
			retryable = settlementOutputPersistFailedAfterCredit(err)
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
