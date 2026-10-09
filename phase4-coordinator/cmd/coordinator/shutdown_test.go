package main

import (
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/rs/zerolog"
)

func TestCoordinatorHTTPShutdownDeadlineClosesConnectionsAndStores(t *testing.T) {
	req, err := requestlog.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer req.Close()
	if _, err := billing.NewStore(req.DB()); err != nil {
		t.Fatal(err)
	}
	events, err := providerevents.Open(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer events.Close()
	var servers []*httptest.Server
	var done []chan struct{}
	for range 2 {
		entered, finished := make(chan struct{}), make(chan struct{})
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			close(entered)
			<-r.Context().Done()
			close(finished)
		}))
		t.Cleanup(s.Close)
		servers = append(servers, s)
		done = append(done, finished)
		go func() {
			resp, err := s.Client().Get(s.URL)
			if err == nil {
				resp.Body.Close()
			}
		}()
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatal("handler never entered")
		}
	}
	code := func() int {
		defer req.Close()
		defer events.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		defer cancel()
		exitCode := 0
		// The provider gets the shared deadline already exhausted by the buyer.
		for i, s := range servers {
			err := shutdownHTTPServer(ctx, s.Config, []string{"buyer", "provider"}[i], zerolog.Nop())
			if !errors.Is(err, context.DeadlineExceeded) {
				t.Errorf("server %d: got %v", i, err)
			}
			if err != nil {
				exitCode = 1
			}
			select {
			case <-done[i]:
			case <-time.After(2 * time.Second):
				t.Errorf("server %d: active connection survived Close", i)
			}
		}
		return exitCode
	}()
	if code != 1 {
		t.Fatalf("exit status = %d", code)
	}
	if err := req.DB().Ping(); err == nil {
		t.Fatal("request log / shared billing DB still open")
	}
	// Closed connection-event store must reject a DB operation.
	if err := events.ReconcileBounds(context.Background()); err == nil {
		t.Fatal("connection-event DB still open")
	}
}

func TestCoordinatorHTTPShutdownCleanDrain(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := shutdownHTTPServer(ctx, s.Config, "buyer", zerolog.Nop()); err != nil {
		t.Fatal(err)
	}
}

// The runtime test exercises real HTTP and SQLite. This guard links it to the
// production exit boundary: the old signal branch terminated before defers ran.
func TestCoordinatorHTTPShutdownProductionCleanupBoundary(t *testing.T) {
	data, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "os.Exit(runCoordinator())") {
		t.Fatal("process must exit after cleanup-owning runner returns")
	}
	f, err := parser.ParseFile(token.NewFileSet(), "main.go", data, 0)
	if err != nil {
		t.Fatal(err)
	}
	var runner *ast.FuncDecl
	for _, d := range f.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == "runCoordinator" {
			runner = fn
		}
	}
	if runner == nil {
		t.Fatal("missing cleanup-owning runner")
	}
	closed := map[string]bool{}
	var shutdown *ast.CommClause
	ast.Inspect(runner, func(n ast.Node) bool {
		if d, ok := n.(*ast.DeferStmt); ok {
			ast.Inspect(d, func(n ast.Node) bool {
				if s, ok := n.(*ast.SelectorExpr); ok && s.Sel.Name == "Close" {
					if name, ok := s.X.(*ast.Ident); ok {
						closed[name.Name] = true
					}
				}
				return true
			})
		}
		if c, ok := n.(*ast.CommClause); ok && c.Comm != nil {
			ast.Inspect(c.Comm, func(n ast.Node) bool {
				if s, ok := n.(*ast.SelectorExpr); ok && s.Sel.Name == "term" {
					shutdown = c
				}
				return true
			})
		}
		return true
	})
	for _, name := range []string{"tokenStore", "reqLogStore", "moneyCheckpointDB", "routeSnapshotDB", "routeSnapshotJournalDB", "routeSnapshotJournalCheckpointDB", "auditStore", "settlementReceiptAuditStore", "connectionEventStore", "billingReadStore", "statsPools", "rewardsDB", "onboardingStore", "relayBlindStore", "mdaStore"} {
		if !closed[name] {
			t.Errorf("missing deferred close: %s", name)
		}
	}
	if shutdown == nil {
		t.Fatal("missing signal branch")
	}
	drains := 0
	ast.Inspect(shutdown, func(n ast.Node) bool {
		if s, ok := n.(*ast.SelectorExpr); ok && (s.Sel.Name == "Exit" || s.Sel.Name == "Fatal") {
			t.Errorf("shutdown bypasses cleanup with %s", s.Sel.Name)
		}
		if c, ok := n.(*ast.CallExpr); ok {
			if name, ok := c.Fun.(*ast.Ident); ok && name.Name == "shutdownHTTPServer" {
				drains++
			}
		}
		return true
	})
	if drains != 2 {
		t.Fatalf("expected both HTTP drains, got %d", drains)
	}
}
