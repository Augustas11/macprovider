package ws

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const testBootUUID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
const testInstUUID = "11111111-1111-1111-1111-111111111111"

func baseWire() supervisorEventWire {
	return supervisorEventWire{
		Schema: supervisorEventSchema, Kind: "beacon", BootID: testBootUUID, Seq: 5,
		SupervisorLabel: "provider-watchdog", SupervisorVersion: "1.0",
		RestartsTotal: 1, DeferralsTotal: 0,
	}
}

func TestNormalizeSupervisorWire(t *testing.T) {
	now := time.Now().UTC()
	t.Run("valid beacon accepted", func(t *testing.T) {
		w := baseWire()
		if !normalizeSupervisorWire(&w, now) {
			t.Fatal("valid beacon rejected")
		}
	})
	t.Run("wrong schema dropped", func(t *testing.T) {
		w := baseWire()
		w.Schema = "evil.v9"
		if normalizeSupervisorWire(&w, now) {
			t.Fatal("wrong schema accepted")
		}
	})
	t.Run("non-UUID boot_id dropped", func(t *testing.T) {
		w := baseWire()
		w.BootID = "/Users/x/host"
		if normalizeSupervisorWire(&w, now) {
			t.Fatal("non-UUID boot_id accepted")
		}
	})
	t.Run("counters exceeding seq dropped", func(t *testing.T) {
		w := baseWire()
		w.Seq = 2
		w.RestartsTotal = 2
		w.DeferralsTotal = 2 // 2+2 > 2
		if normalizeSupervisorWire(&w, now) {
			t.Fatal("restarts+deferrals>seq accepted")
		}
	})
	t.Run("supervisor_version bad charset coerced to unknown", func(t *testing.T) {
		w := baseWire()
		w.SupervisorVersion = "host /Users/x"
		if !normalizeSupervisorWire(&w, now) || w.SupervisorVersion != "unknown" {
			t.Fatalf("version = %q", w.SupervisorVersion)
		}
	})
	t.Run("non-wedge last_restart dropped", func(t *testing.T) {
		w := baseWire()
		w.Kind = "restart"
		w.LastRestart = &supervisorRestartWire{Seq: 5, Reason: "operator", CooldownState: "armed"}
		if !normalizeSupervisorWire(&w, now) || w.LastRestart != nil {
			t.Fatal("non-wedge last_restart not dropped")
		}
	})
	t.Run("restart without advanced counter dropped", func(t *testing.T) {
		w := baseWire()
		w.Kind = "restart"
		w.RestartsTotal = 0
		w.LastRestart = &supervisorRestartWire{Seq: 5, Reason: "wedge", CooldownState: "armed"}
		if !normalizeSupervisorWire(&w, now) || w.LastRestart != nil {
			t.Fatal("restart with restarts_total=0 not dropped")
		}
	})
	t.Run("non-UUID service_instance nulled", func(t *testing.T) {
		w := baseWire()
		w.Kind = "restart"
		bad := "/Users/x/host"
		w.LastRestart = &supervisorRestartWire{Seq: 5, Reason: "wedge", CooldownState: "armed", ServiceInstance: &bad}
		if !normalizeSupervisorWire(&w, now) || w.LastRestart == nil || w.LastRestart.ServiceInstance != nil {
			t.Fatal("non-UUID service_instance not nulled")
		}
	})
	t.Run("future ts nulled at field level, beacon kept", func(t *testing.T) {
		w := baseWire()
		w.Kind = "restart"
		w.LastRestart = &supervisorRestartWire{
			Seq: 5, Reason: "wedge", CooldownState: "armed",
			TS: now.Add(24 * time.Hour).Format(time.RFC3339),
		}
		if !normalizeSupervisorWire(&w, now) {
			t.Fatal("future-ts beacon wrongly rejected (must be field-level null)")
		}
		if w.LastRestart == nil || w.LastRestart.TS != "" {
			t.Fatalf("future ts not nulled: %q", func() string {
				if w.LastRestart == nil {
					return "<dropped>"
				}
				return w.LastRestart.TS
			}())
		}
	})
	t.Run("wrong deferral_reason dropped", func(t *testing.T) {
		w := baseWire()
		w.Kind = "deferral"
		w.DeferralsTotal = 1
		w.LastDeferral = &supervisorDeferralWire{Seq: 5, DeferralReason: "something"}
		if !normalizeSupervisorWire(&w, now) || w.LastDeferral != nil {
			t.Fatal("wrong deferral_reason not dropped")
		}
	})
}

func TestProjectSupervisorModelLiveness(t *testing.T) {
	t.Run("extra keys dropped, redaction", func(t *testing.T) {
		in := json.RawMessage(`{"token_age_ms":5,"active_inference":true,"active_inference_age_ms":9,"host":"/Users/x/private"}`)
		out := projectSupervisorModelLiveness(in)
		s := string(out)
		if strings.Contains(s, "host") || strings.Contains(s, "Users") {
			t.Fatalf("redaction-forbidden key survived: %s", s)
		}
		var m map[string]json.RawMessage
		if err := json.Unmarshal(out, &m); err != nil || len(m) != 3 {
			t.Fatalf("expected exactly 3 keys, got %s", s)
		}
	})
	t.Run("negative/over-range ages nulled", func(t *testing.T) {
		in := json.RawMessage(`{"token_age_ms":-1,"active_inference":false,"active_inference_age_ms":9999999999999999}`)
		out := projectSupervisorModelLiveness(in)
		var m struct {
			Tok  *int64 `json:"token_age_ms"`
			Acta *int64 `json:"active_inference_age_ms"`
		}
		if err := json.Unmarshal(out, &m); err != nil {
			t.Fatal(err)
		}
		if m.Tok != nil {
			t.Fatalf("negative token_age_ms not nulled: %v", *m.Tok)
		}
		if m.Acta != nil {
			t.Fatalf("over-range age not nulled: %v", *m.Acta)
		}
	})
	t.Run("null and invalid yield nil", func(t *testing.T) {
		if projectSupervisorModelLiveness(json.RawMessage(`null`)) != nil {
			t.Fatal("null should project to nil")
		}
		if projectSupervisorModelLiveness(json.RawMessage(`[1,2]`)) != nil {
			t.Fatal("array should project to nil")
		}
		if projectSupervisorModelLiveness(nil) != nil {
			t.Fatal("empty should project to nil")
		}
	})
}
