package router

import (
	"fmt"
	"strings"
	"sync"
)

const (
	adminStateWriteHandlerCapacity   = "capacity"
	adminStateWriteHandlerKillSwitch = "kill_switch"
)

type adminStateWriteMetrics struct {
	mu     sync.Mutex
	errors map[string]int64
}

func newAdminStateWriteMetrics() *adminStateWriteMetrics {
	return &adminStateWriteMetrics{errors: map[string]int64{
		adminStateWriteHandlerCapacity:   0,
		adminStateWriteHandlerKillSwitch: 0,
	}}
}

func (m *adminStateWriteMetrics) recordError(handler string) {
	if m == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.errors[normalizeAdminStateWriteHandler(handler)]++
}

func (m *adminStateWriteMetrics) prometheus() string {
	if m == nil {
		m = newAdminStateWriteMetrics()
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	var b strings.Builder
	b.WriteString("# HELP admin_state_write_error_total Admin control-plane state writes that failed durability or optimistic concurrency checks.\n")
	b.WriteString("# TYPE admin_state_write_error_total counter\n")
	for _, handler := range []string{adminStateWriteHandlerCapacity, adminStateWriteHandlerKillSwitch} {
		fmt.Fprintf(&b, "admin_state_write_error_total{handler=%q} %d\n", handler, m.errors[handler])
	}
	return b.String()
}

func normalizeAdminStateWriteHandler(handler string) string {
	switch handler {
	case adminStateWriteHandlerCapacity, adminStateWriteHandlerKillSwitch:
		return handler
	default:
		return "unknown"
	}
}
