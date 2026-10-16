package ws

import (
	"context"
	"database/sql"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/fleetcache"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
)

func TestConversationCachePurgeControlAndMatchingSessionAck(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	defer db.Close()
	store, err := fleetcache.NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	grant, err := store.Grant(ctx, "acct-a", "conv:opaque", "provider-a")
	if err != nil {
		t.Fatal(err)
	}
	purged, err := store.PurgeAccount(ctx, "acct-a")
	if err != nil || len(purged.Pending) != 1 {
		t.Fatalf("purge = %+v, %v", purged, err)
	}

	registry := pool.NewRegistry(nil)
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	provider := &pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", ModelID: "model-a",
		State: pool.StateReady, FleetCacheProtocol: 1,
	}
	if _, ok := registry.Register(provider, serverConn); !ok {
		t.Fatal("register provider")
	}
	server := NewServer(config.Default(), registry, zerolog.Nop(), WithFleetCache(store))
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, 4)
	server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
	go session.runWriter()
	defer session.close()

	server.DispatchConversationCachePurge(purged.Pending[0])
	_ = providerConn.SetReadDeadline(time.Now().Add(time.Second))
	raw, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatal(err)
	}
	var control conversationCachePurge
	if err := json.Unmarshal(raw, &control); err != nil {
		t.Fatal(err)
	}
	if control.Type != "conversation_cache_purge" || control.PurgeID != purged.Pending[0].PurgeID || control.ConversationKey != grant.ConversationKey || control.Generation != 1 {
		t.Fatalf("control = %+v", control)
	}
	ack, _ := json.Marshal(conversationCachePurgeAck{
		Type: "conversation_cache_purge_ack", PurgeID: control.PurgeID,
		ConversationKey: control.ConversationKey, Generation: control.Generation, Purged: true,
	})
	server.handleConversationCachePurgeAck(provider.ProviderID, "stale-session", ack)
	pending, err := store.PendingForProvider(ctx, provider.ProviderID)
	if err != nil || len(pending) != 1 {
		t.Fatalf("stale session cleared pending: %+v, %v", pending, err)
	}
	server.handleConversationCachePurgeAck(provider.ProviderID, provider.AssignedID, ack)
	pending, err = store.PendingForProvider(ctx, provider.ProviderID)
	if err != nil || len(pending) != 0 {
		t.Fatalf("matching ack left pending: %+v, %v", pending, err)
	}
}
