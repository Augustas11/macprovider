package router

import (
	"net/http"
	"strconv"
	"sync"
	"time"
)

var wholesaleKeepaliveInterval = 15 * time.Second

const wholesaleKeepaliveComment = ": keepalive\n\n"

type wholesaleStreamWriter struct {
	mu      sync.Mutex
	stopped bool
	w       http.ResponseWriter
	flusher http.Flusher
}

func (s *wholesaleStreamWriter) Header() http.Header {
	return s.w.Header()
}

func (s *wholesaleStreamWriter) WriteHeader(statusCode int) {
	s.w.WriteHeader(statusCode)
}

func (s *wholesaleStreamWriter) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.w.Write(p)
}

func (s *wholesaleStreamWriter) Flush() {
	if s.flusher == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.flusher.Flush()
}

func (s *wholesaleStreamWriter) stopKeepalives() {
	s.mu.Lock()
	s.stopped = true
	s.mu.Unlock()
}

func (s *wholesaleStreamWriter) writeKeepalive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		return false
	}
	if _, err := s.w.Write([]byte(wholesaleKeepaliveComment)); err != nil {
		return false
	}
	if s.flusher != nil {
		s.flusher.Flush()
	}
	return true
}

func startWholesaleKeepalives(ctxDone <-chan struct{}, wrap *wholesaleStreamWriter) func() {
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(wholesaleKeepaliveInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctxDone:
				return
			case <-ticker.C:
				if !wrap.writeKeepalive() {
					return
				}
			}
		}
	}()
	return func() {
		wrap.stopKeepalives()
		select {
		case <-done:
		default:
			close(done)
		}
	}
}

func wholesaleUsageSSEChunk(prompt, completion int64) []byte {
	if prompt < 0 {
		prompt = 0
	}
	if completion < 0 {
		completion = 0
	}
	total := prompt + completion
	return []byte("data: {\"choices\":[],\"usage\":{\"prompt_tokens\":" +
		strconv.FormatInt(prompt, 10) + ",\"completion_tokens\":" + strconv.FormatInt(completion, 10) +
		",\"total_tokens\":" + strconv.FormatInt(total, 10) + "}}\n\n")
}
