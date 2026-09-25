package buyer

import (
	"context"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-042-R014 / SPEC-006-R016 (#1690 M7): the coordinator engine filter at
// the request-level gate, the candidate and pinned paths, and the slot-queue
// poll.

func engineReq(poolID, engineClass string) chatRequest {
	req := poolChatReq(poolID)
	req.engineClass = engineClass
	return req
}

func loopbackPoolProvider(providerID, runtimeSource string) pool.Provider {
	p := poolProvider(providerID)
	p.RuntimeSource = runtimeSource
	p.AdmissionSandboxed = true
	return p
}

func TestInternalEngineSelectionClosedVocabulary(t *testing.T) {
	for _, tc := range []struct {
		values []string
		want   string
		ok     bool
	}{
		{nil, "", true},
		{[]string{""}, "", true},
		{[]string{"mlx_cache"}, "mlx_cache", true},
		{[]string{" llamacpp_loopback "}, "llamacpp_loopback", true},
		{[]string{"ollama_loopback", "ollama_loopback"}, "ollama_loopback", true},
		{[]string{"mlxlm_loopback"}, "mlxlm_loopback", true},
		{[]string{"native"}, "", false},
		{[]string{"lmstudio_loopback"}, "", false},
		{[]string{"openai_compatible_loopback"}, "", false},
		{[]string{"MLX_CACHE"}, "", false},
		{[]string{"mlx_cache", "llamacpp_loopback"}, "", false},
	} {
		h := http.Header{}
		for _, v := range tc.values {
			h.Add(engineInternalHeader, v)
		}
		got, ok := internalEngineSelection(h)
		if got != tc.want || ok != tc.ok {
			t.Fatalf("%q: got (%q,%v) want (%q,%v)", tc.values, got, ok, tc.want, tc.ok)
		}
	}
}

func TestProviderEngineClassNativeUnlessLoopback(t *testing.T) {
	for source, want := range map[string]string{
		"":                  "mlx_cache",
		"mlx_cache":         "mlx_cache",
		"llamacpp_loopback": "llamacpp_loopback",
		"ollama_loopback":   "ollama_loopback",
		"something_else":    "mlx_cache",
	} {
		if got := providerEngineClass(pool.Provider{RuntimeSource: source}); got != want {
			t.Fatalf("runtime_source %q: class %q want %q", source, got, want)
		}
	}
}

func TestEngineRouteErrorRequiresAllowlistingPool(t *testing.T) {
	cases := []struct {
		engine    string
		pool      bool
		allowlist []string
		code      string
	}{
		{"", false, nil, ""},
		{"mlx_cache", false, nil, ""},
		{"mlx_cache", true, nil, ""},
		{"llamacpp_loopback", false, []string{"llamacpp_loopback"}, "engine_unavailable"},
		{"llamacpp_loopback", true, nil, "engine_unavailable"},
		{"ollama_loopback", true, []string{"llamacpp_loopback"}, "engine_unavailable"},
		{"llamacpp_loopback", true, []string{"llamacpp_loopback"}, ""},
	}
	for _, tc := range cases {
		err := engineRouteError(tc.engine, tc.pool, tc.allowlist)
		got := ""
		if err != nil {
			got = err.code
			if err.status != http.StatusServiceUnavailable || spec018Retryable(err.code) {
				t.Fatalf("%+v: status=%d retryable=%v", tc, err.status, spec018Retryable(err.code))
			}
		}
		if got != tc.code {
			t.Fatalf("%+v: code %q want %q", tc, got, tc.code)
		}
	}
}

// SPEC-042-R014 (a): a non-native engine on a global route or on a pool whose
// active allowlist lacks it fails closed before any candidate is considered.
func TestEngineSelection_NonNativeFailsClosedWithoutAllowlistingPool(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	native := poolProvider("member-a")
	registry.Register(&native, nil)
	loop := loopbackPoolProvider("member-b", "llamacpp_loopback")
	registry.Register(&loop, nil)
	tp.AddMember("P", "member-a")
	tp.AddMember("P", "member-b") // AddMember pools carry no runtime allowlist.
	for name, req := range map[string]chatRequest{
		"global llamacpp": engineReq("", "llamacpp_loopback"),
		"global ollama":   engineReq("", "ollama_loopback"),
		"pool llamacpp":   engineReq("P", "llamacpp_loopback"),
	} {
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", req, http.Header{}, nil, "2024-01-01", &forwardState{})
		if routeErr == nil || routeErr.code != "engine_unavailable" {
			t.Fatalf("%s: want engine_unavailable, got %+v", name, routeErr)
		}
	}
}

// SPEC-042-R014 (b): native selects only native sessions, on a pool route and
// on a global route; an absent selection is unchanged.
func TestEngineSelection_NativeSelectsOnlyNativeSessions(t *testing.T) {
	for _, poolID := range []string{"P", ""} {
		for _, engine := range []string{"mlx_cache", ""} {
			s, registry, tp := poolIsolationServer(t)
			// The external-runtime session is registered first and is not
			// sandboxed here, so only the engine filter keeps it out.
			loop := loopbackPoolProvider("member-b", "llamacpp_loopback")
			loop.AdmissionSandboxed = false
			loop.ThroughputTPSEstimate = 1000
			registry.Register(&loop, nil)
			native := poolProvider("member-a")
			registry.Register(&native, nil)
			tp.AddMember("P", "member-a")
			tp.AddMember("P", "member-b")
			state := &forwardState{}
			p, routeErr := s.selectProviderExcluding(context.Background(), "rid", engineReq(poolID, engine), http.Header{}, nil, "2024-01-01", state)
			if engine == "" {
				// Absent selection: today's behavior, whatever it picks.
				if state.engineClass != "" {
					t.Fatalf("pool %q absent: engine class %q", poolID, state.engineClass)
				}
				continue
			}
			if routeErr != nil || p.ProviderID != "member-a" {
				t.Fatalf("pool %q native: provider=%q err=%+v", poolID, p.ProviderID, routeErr)
			}
			if state.engineClass != "mlx_cache" {
				t.Fatalf("forward state engine class %q", state.engineClass)
			}
		}
	}
}

// SPEC-042-R014 (d): native on a pool whose only member is an external
// runtime has no session of the selected class, so it fails closed instead
// of spilling to the external runtime or to global.
func TestEngineSelection_NativeOnPoolWithOnlyExternalRuntimeFailsClosed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	loop := loopbackPoolProvider("member-b", "llamacpp_loopback")
	registry.Register(&loop, nil)
	outside := poolProvider("global-native")
	registry.Register(&outside, nil)
	tp.AddMember("P", "member-b")
	_, routeErr := s.selectProviderExcluding(context.Background(), "rid", engineReq("P", "mlx_cache"), http.Header{}, nil, "2024-01-01", &forwardState{})
	if routeErr == nil || routeErr.code != "engine_unavailable" {
		t.Fatalf("want engine_unavailable, got %+v", routeErr)
	}
}

// SPEC-042-R014 (c): a pin never bypasses the engine filter.
func TestEngineSelection_PinnedProviderOfOtherClassFailsClosed(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	loop := loopbackPoolProvider("member-b", "llamacpp_loopback")
	registry.Register(&loop, nil)
	native := poolProvider("member-a")
	registry.Register(&native, nil)
	tp.AddMember("P", "member-a")
	tp.AddMember("P", "member-b")
	for name, pin := range map[string][2]string{
		"provider pin": {"X-MacProvider-Provider", "member-b"},
		"session pin":  {"X-MacProvider-Session", "s-member-b"},
	} {
		headers := http.Header{}
		headers.Set(pin[0], pin[1])
		_, routeErr := s.selectProviderExcluding(context.Background(), "rid", engineReq("P", "mlx_cache"), headers, nil, "2024-01-01", &forwardState{})
		if routeErr == nil || routeErr.code != "engine_unavailable" {
			t.Fatalf("%s: want engine_unavailable, got %+v", name, routeErr)
		}
	}
}

// SPEC-042-R014 (c): the slot queue stores only a provider ID, so a same-ID
// reconnect of another class is terminal for the waiter.
func TestEngineSelection_SlotQueuePollTerminalForOtherClass(t *testing.T) {
	s, registry, tp := poolIsolationServer(t)
	member := poolProvider("member-a")
	registry.Register(&member, nil)
	tp.AddMember("P", "member-a")
	w, ok := s.slotQueue.enter("member-a")
	if !ok {
		t.Fatal("enter returned no waiter")
	}
	defer s.slotQueue.leave(w)
	snap := tp.Snapshot("P")
	state := &forwardState{poolID: "P", poolMembers: snap.Members, engineClass: "llamacpp_loopback"}
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, state); status != queuedProviderTerminal {
		t.Fatalf("poll status = %v, want terminal for a session of another class", status)
	}
	state.engineClass = "mlx_cache"
	if _, status := s.pollQueuedProvider(w, "model-a", nil, 100, state); status == queuedProviderTerminal {
		t.Fatalf("poll status = %v for the selected class, want not terminal", status)
	}
}
