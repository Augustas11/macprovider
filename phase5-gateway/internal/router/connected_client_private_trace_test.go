package router

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

const (
	connectedClientTraceRequestMax  = 4 << 20
	connectedClientTraceResponseMax = 1 << 20
)

type connectedClientPrivateTrace struct {
	dir string

	mu       sync.Mutex
	selected bool
}

func newConnectedClientPrivateTrace(raw, kind string, synthetic bool, upstream string, verifiedStudio bool) (*connectedClientPrivateTrace, error) {
	if raw == "" {
		return nil, nil
	}
	if kind != "opencode" || synthetic || upstream != "http://127.0.0.1:18055" || !verifiedStudio {
		return nil, fmt.Errorf("private trace requires actual OpenCode on the verified Studio loopback fixture")
	}
	if !filepath.IsAbs(raw) || filepath.Clean(raw) != raw {
		return nil, fmt.Errorf("private trace directory must be a clean absolute path")
	}
	parent := filepath.Dir(raw)
	canonicalParent, err := filepath.EvalSymlinks(parent)
	if err != nil || canonicalParent != parent {
		return nil, fmt.Errorf("private trace parent must be an existing canonical path")
	}
	parentInfo, err := os.Lstat(parent)
	if err != nil || !parentInfo.IsDir() || parentInfo.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("private trace parent must be a directory, not a symlink")
	}
	if parentInfo.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("private trace parent must deny group and other access")
	}
	if _, err := os.Lstat(raw); !os.IsNotExist(err) {
		return nil, fmt.Errorf("private trace directory must not already exist")
	}
	if err := os.Mkdir(raw, 0700); err != nil {
		return nil, fmt.Errorf("create private trace directory: %w", err)
	}
	info, err := os.Lstat(raw)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 {
		return nil, fmt.Errorf("private trace directory was not created privately")
	}
	return &connectedClientPrivateTrace{dir: raw}, nil
}

func (t *connectedClientPrivateTrace) captureRequest(body []byte, hasTools bool) (bool, error) {
	if t == nil || !hasTools {
		return false, nil
	}
	if len(body) > connectedClientTraceRequestMax {
		return false, fmt.Errorf("private trace request exceeded four MiB")
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.selected {
		return false, nil
	}
	t.selected = true
	if err := writeConnectedClientPrivateTraceFile(filepath.Join(t.dir, "request.json"), body); err != nil {
		return false, err
	}
	return true, nil
}

func (t *connectedClientPrivateTrace) captureResponse(body []byte, selected bool) error {
	if t == nil || !selected {
		return nil
	}
	if len(body) > connectedClientTraceResponseMax {
		return fmt.Errorf("private trace response exceeded one MiB")
	}
	return writeConnectedClientPrivateTraceFile(filepath.Join(t.dir, "response.sse"), body)
}

func writeConnectedClientPrivateTraceFile(path string, body []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return fmt.Errorf("create private trace file: %w", err)
	}
	written, writeErr := file.Write(body)
	closeErr := file.Close()
	if writeErr != nil {
		return fmt.Errorf("write private trace file: %w", writeErr)
	}
	if written != len(body) {
		return fmt.Errorf("write private trace file: short write")
	}
	if closeErr != nil {
		return fmt.Errorf("close private trace file: %w", closeErr)
	}
	return nil
}

func TestConnectedClientPrivateTraceScope(t *testing.T) {
	parent := privateTraceTestParent(t)
	for _, tc := range []struct {
		name           string
		kind           string
		synthetic      bool
		upstream       string
		verifiedStudio bool
	}{
		{name: "other client", kind: "codex", upstream: "http://127.0.0.1:18055", verifiedStudio: true},
		{name: "synthetic", kind: "opencode", synthetic: true, upstream: "http://127.0.0.1:18055", verifiedStudio: true},
		{name: "other upstream", kind: "opencode", upstream: "http://127.0.0.1:18056", verifiedStudio: true},
		{name: "unverified host", kind: "opencode", upstream: "http://127.0.0.1:18055"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(parent, filepath.Base(t.Name()))
			if _, err := newConnectedClientPrivateTrace(path, tc.kind, tc.synthetic, tc.upstream, tc.verifiedStudio); err == nil {
				t.Fatal("accepted private trace outside its bounded fixture scope")
			}
			if _, err := os.Lstat(path); !os.IsNotExist(err) {
				t.Fatal("scope rejection created a trace directory")
			}
		})
	}
	if trace, err := newConnectedClientPrivateTrace("", "codex", true, "", false); err != nil || trace != nil {
		t.Fatalf("absent opt-in changed default behavior: trace=%v error=%v", trace, err)
	}
}

func TestConnectedClientPrivateTracePathSafety(t *testing.T) {
	t.Run("private new child", func(t *testing.T) {
		parent := privateTraceTestParent(t)
		path := filepath.Join(parent, "trace")
		trace, err := newConnectedClientPrivateTrace(path, "opencode", false, "http://127.0.0.1:18055", true)
		if err != nil || trace == nil {
			t.Fatalf("create private trace: %v", err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0700 {
			t.Fatalf("trace mode=%v", info.Mode().Perm())
		}
	})
	t.Run("relative", func(t *testing.T) {
		if _, err := newConnectedClientPrivateTrace("trace", "opencode", false, "http://127.0.0.1:18055", true); err == nil {
			t.Fatal("accepted relative trace path")
		}
	})
	t.Run("public parent", func(t *testing.T) {
		parent := privateTraceTestParent(t)
		if err := os.Chmod(parent, 0750); err != nil {
			t.Fatal(err)
		}
		if _, err := newConnectedClientPrivateTrace(filepath.Join(parent, "trace"), "opencode", false, "http://127.0.0.1:18055", true); err == nil {
			t.Fatal("accepted group-accessible parent")
		}
	})
	t.Run("existing", func(t *testing.T) {
		parent := privateTraceTestParent(t)
		path := filepath.Join(parent, "trace")
		if err := os.Mkdir(path, 0700); err != nil {
			t.Fatal(err)
		}
		if _, err := newConnectedClientPrivateTrace(path, "opencode", false, "http://127.0.0.1:18055", true); err == nil {
			t.Fatal("accepted existing trace directory")
		}
	})
	t.Run("symlink parent", func(t *testing.T) {
		parent := privateTraceTestParent(t)
		link := filepath.Join(filepath.Dir(parent), "parent-link")
		if err := os.Symlink(parent, link); err != nil {
			t.Fatal(err)
		}
		if _, err := newConnectedClientPrivateTrace(filepath.Join(link, "trace"), "opencode", false, "http://127.0.0.1:18055", true); err == nil {
			t.Fatal("accepted symlinked parent")
		}
	})
	t.Run("symlink child", func(t *testing.T) {
		parent := privateTraceTestParent(t)
		path := filepath.Join(parent, "trace")
		if err := os.Symlink(filepath.Join(parent, "missing"), path); err != nil {
			t.Fatal(err)
		}
		if _, err := newConnectedClientPrivateTrace(path, "opencode", false, "http://127.0.0.1:18055", true); err == nil {
			t.Fatal("accepted symlink trace child")
		}
	})
}

func TestConnectedClientPrivateTraceCapture(t *testing.T) {
	parent := privateTraceTestParent(t)
	trace, err := newConnectedClientPrivateTrace(filepath.Join(parent, "trace"), "opencode", false, "http://127.0.0.1:18055", true)
	if err != nil {
		t.Fatal(err)
	}
	request := []byte(`{"model":"fixture","tools":[{"type":"function"}]}`)
	response := []byte("data: {\"choices\":[]}\n\ndata: [DONE]\n\n")
	if selected, err := trace.captureRequest([]byte(`{"model":"no-tools"}`), false); err != nil || selected {
		t.Fatalf("tool-free request selected=%v error=%v", selected, err)
	}
	selected, err := trace.captureRequest(request, true)
	if err != nil || !selected {
		t.Fatalf("first tools request selected=%v error=%v", selected, err)
	}
	if err := trace.captureResponse(response, selected); err != nil {
		t.Fatal(err)
	}
	if selected, err := trace.captureRequest([]byte(`{"later":true}`), true); err != nil || selected {
		t.Fatalf("later tools request selected=%v error=%v", selected, err)
	}
	assertPrivateTraceFile(t, filepath.Join(trace.dir, "request.json"), request)
	assertPrivateTraceFile(t, filepath.Join(trace.dir, "response.sse"), response)
}

func TestConnectedClientPrivateTraceSelectsOneConcurrentRequest(t *testing.T) {
	trace := newPrivateTraceForTest(t)
	bodies := [][]byte{[]byte(`{"request":1,"tools":[{}]}`), []byte(`{"request":2,"tools":[{}]}`)}
	start := make(chan struct{})
	selected := make(chan bool, len(bodies))
	errors := make(chan error, len(bodies))
	for _, body := range bodies {
		body := body
		go func() {
			<-start
			got, err := trace.captureRequest(body, true)
			selected <- got
			errors <- err
		}()
	}
	close(start)
	selectedCount := 0
	for range bodies {
		if <-selected {
			selectedCount++
		}
		if err := <-errors; err != nil {
			t.Fatal(err)
		}
	}
	if selectedCount != 1 {
		t.Fatalf("selected %d concurrent requests", selectedCount)
	}
	got, err := os.ReadFile(filepath.Join(trace.dir, "request.json"))
	if err != nil || (!bytes.Equal(got, bodies[0]) && !bytes.Equal(got, bodies[1])) {
		t.Fatalf("captured request mismatch: error=%v bytes=%d", err, len(got))
	}
}

func TestConnectedClientPrivateTraceBoundsAndExclusiveFiles(t *testing.T) {
	t.Run("request", func(t *testing.T) {
		trace := newPrivateTraceForTest(t)
		if selected, err := trace.captureRequest(make([]byte, connectedClientTraceRequestMax+1), true); err == nil || selected {
			t.Fatalf("oversize request selected=%v error=%v", selected, err)
		}
		if _, err := os.Stat(filepath.Join(trace.dir, "request.json")); !os.IsNotExist(err) {
			t.Fatal("oversize request was written")
		}
	})
	t.Run("response", func(t *testing.T) {
		trace := newPrivateTraceForTest(t)
		selected, err := trace.captureRequest([]byte(`{"tools":[{}]}`), true)
		if err != nil || !selected {
			t.Fatal(err)
		}
		if err := trace.captureResponse(make([]byte, connectedClientTraceResponseMax+1), true); err == nil {
			t.Fatal("accepted oversize response")
		}
		if _, err := os.Stat(filepath.Join(trace.dir, "response.sse")); !os.IsNotExist(err) {
			t.Fatal("oversize response was written")
		}
	})
	t.Run("exclusive", func(t *testing.T) {
		trace := newPrivateTraceForTest(t)
		path := filepath.Join(trace.dir, "response.sse")
		if err := os.WriteFile(path, []byte("existing"), 0600); err != nil {
			t.Fatal(err)
		}
		if err := trace.captureResponse([]byte("replacement"), true); err == nil {
			t.Fatal("overwrote existing trace file")
		}
		assertPrivateTraceFile(t, path, []byte("existing"))
	})
}

func privateTraceTestParent(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	return root
}

func newPrivateTraceForTest(t *testing.T) *connectedClientPrivateTrace {
	t.Helper()
	parent := privateTraceTestParent(t)
	trace, err := newConnectedClientPrivateTrace(filepath.Join(parent, "trace"), "opencode", false, "http://127.0.0.1:18055", true)
	if err != nil {
		t.Fatal(err)
	}
	return trace
}

func assertPrivateTraceFile(t *testing.T, path string, want []byte) {
	t.Helper()
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("trace content mismatch: error=%v got_bytes=%d want_bytes=%d", err, len(got), len(want))
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("trace file mode mismatch: mode=%v", info.Mode().Perm())
	}
}
