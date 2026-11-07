package ws

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	gobwas "github.com/gobwas/ws"
	"github.com/rs/zerolog"
)

// TestConcurrentEncryptedDispatchesReachProviderInC2PSequenceOrder covers
// #2245: dispatches parked behind a rekey wake together, and each one's write
// probe can finish after a later dispatch's. The provider accepts only the
// exact next C2P sequence number, so the payloads must reach the socket in the
// order their sequence numbers were assigned.
func TestConcurrentEncryptedDispatchesReachProviderInC2PSequenceOrder(t *testing.T) {
	const rounds = 20
	const dispatches = 16
	for round := 0; round < rounds; round++ {
		if err := runConcurrentEncryptedDispatchRound(t, dispatches); err != nil {
			t.Fatalf("round %d: %v", round, err)
		}
	}
}

func runConcurrentEncryptedDispatchRound(t *testing.T, dispatches int) error {
	t.Helper()
	serverConn, providerConn := net.Pipe()
	defer func() {
		_ = providerConn.Close()
		_ = serverConn.Close()
	}()
	tier2Session := &pool.Tier2Session{
		AEADSuite:                      tier2.PillarBAEADA256GCM,
		ResponseChunkPlaintextEnvelope: true,
		InBandAEADRekeyV1:              true,
		C2PKey:                         bytes.Repeat([]byte{0x11}, 32),
		P2CKey:                         bytes.Repeat([]byte{0x22}, 32),
		C2PNonceBase:                   []byte{0x01, 0x02, 0x03, 0x04},
		P2CNonceBase:                   []byte{0x05, 0x06, 0x07, 0x08},
		C2PCounter:                     1,
		KeyID:                          "test-kid",
		StartedAt:                      time.Now(),
	}
	provider := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      dispatches,
		SlotsTotal:     dispatches,
		MaxConcurrency: dispatches,
		EncryptedLeg:   true,
		Tier2Session:   tier2Session,
	}
	registry := pool.NewRegistry(nil)
	registry.Register(provider, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	awaitStartupSnapshots(t, s)
	session := newProviderSession("p1", "s1", serverConn, 4*dispatches)
	session.probeWrites = true
	session.useTier2Session(tier2Session)
	session.onWriteFailure = s.handleProviderWriteFailure
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	// Fake provider: hold every write until all dispatches have queued their
	// probe, then require each inference_request to carry exactly the next
	// C2P sequence number, as Tier2ProviderSession does.
	orderErr := make(chan error, 1)
	received := make(chan struct{}, dispatches)
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		for len(session.writeCh) < dispatches-1 {
			if time.Now().After(deadline) {
				orderErr <- fmt.Errorf("only %d frames queued before the provider read", len(session.writeCh))
				return
			}
			time.Sleep(time.Millisecond)
		}
		next := uint64(1)
		for {
			frame, err := gobwas.ReadFrame(providerConn)
			if err != nil {
				return
			}
			if frame.Header.OpCode != gobwas.OpText {
				continue
			}
			var msg encryptedInferenceRequest
			if err := json.Unmarshal(frame.Payload, &msg); err != nil || msg.Type != "inference_request" {
				continue
			}
			if msg.Enc.Seq != next {
				select {
				case orderErr <- fmt.Errorf("provider got c2p seq %d, want %d", msg.Enc.Seq, next):
				default:
				}
			}
			next++
			received <- struct{}{}
		}
	}()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var wg sync.WaitGroup
	dispatchErrs := make(chan error, dispatches)
	for i := 0; i < dispatches; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			if _, err := s.DispatchInference(ctx, *provider, fmt.Sprintf("req-c2p-order-%d", i), []byte(`{"model":"model-a"}`), true); err != nil {
				dispatchErrs <- err
			}
		}(i)
	}
	wg.Wait()
	close(dispatchErrs)
	for err := range dispatchErrs {
		return fmt.Errorf("dispatch: %w", err)
	}
	timeout := time.After(5 * time.Second)
	for i := 0; i < dispatches; i++ {
		select {
		case <-received:
		case err := <-orderErr:
			return err
		case <-timeout:
			return fmt.Errorf("provider received %d of %d requests", i, dispatches)
		}
	}
	select {
	case err := <-orderErr:
		return err
	default:
	}
	return nil
}
