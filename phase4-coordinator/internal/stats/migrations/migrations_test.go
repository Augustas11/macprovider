package migrations

import (
	"strings"
	"testing"
)

// TestEmbeddedMigrationsLoad verifies the //go:embed picks up
// every .up.sql file and the filename parser handles them.
// This runs in the default `go test` lane (no Postgres needed).
func TestEmbeddedMigrationsLoad(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatalf("All: %v", err)
	}
	// Step 1 ships exactly these 5 versions. Adjusting this
	// count is a Step 2/3/4 concern; if the slice grows in
	// Step 1 we want a forcing function to update the test.
	want := []struct {
		ver  int
		name string
	}{
		{1, "stats_tables"},
		{2, "bootstrap_health_and_rewards"},
		{3, "roles"},
		{4, "grants"},
		{5, "oltp_source_grants"},
	}
	if len(all) != len(want) {
		t.Fatalf("got %d migrations, want %d", len(all), len(want))
	}
	for i, w := range want {
		if all[i].Version != w.ver {
			t.Errorf("migration[%d] version = %d, want %d", i, all[i].Version, w.ver)
		}
		if all[i].Name != w.name {
			t.Errorf("migration[%d] name = %q, want %q", i, all[i].Name, w.name)
		}
		if strings.TrimSpace(all[i].SQL) == "" {
			t.Errorf("migration[%d] %q has empty body", i, w.name)
		}
	}
}

// TestEmbeddedSchemaShapesCorrect — defensive read of the SQL
// bytes to catch a v0.1.7 / v0.1.8 regression before it reaches
// a live Postgres. Specifically:
//   - earnings_work_bucket / earnings_rewards_bucket MUST NOT
//     appear in any leaderboard DDL (v0.1.7 §9.1 removal).
//   - rate_limit_burst MUST NOT appear in partner_keys
//     (v0.1.8 §5.4.1 removal).
//   - blocked_from_partner_projection MUST appear in
//     provider_visibility (v0.1.7 §6.1 stub).
//   - stats_components_health MUST NOT have a `status` column
//     (status is derived at request time per §5.3; BUILD §A.4
//     CRITICAL).
//   - The 7-component enum CHECK constraint MUST include all
//     seven v0.1.7 values.
func TestEmbeddedSchemaShapesCorrect(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatalf("All: %v", err)
	}
	var schema, bootstrap string
	for _, m := range all {
		switch m.Name {
		case "stats_tables":
			schema = m.SQL
		case "bootstrap_health_and_rewards":
			bootstrap = m.SQL
		}
	}
	if schema == "" {
		t.Fatal("stats_tables migration body is empty")
	}
	// The forbidden-substring checks must scan code, not
	// comments. The migration's prose comments document v0.1.7
	// removals by NAME, which is intentional for a future reader.
	schemaCode := stripSQLComments(schema)

	mustNotContain(t, schemaCode, "earnings_work_bucket",
		"v0.1.7 §9.1 removed per-axis work bucket")
	mustNotContain(t, schemaCode, "earnings_rewards_bucket",
		"v0.1.7 §9.1 removed per-axis rewards bucket")
	mustNotContain(t, schemaCode, "rate_limit_burst",
		"v0.1.8 §5.4.1 removed partner_keys.rate_limit_burst")
	mustContain(t, schemaCode, "blocked_from_partner_projection",
		"v0.1.7 §6.1 added the column stub")
	// status column ban — search inside the
	// stats_components_health DDL specifically.
	chBlock := extractBetween(schemaCode,
		"CREATE TABLE IF NOT EXISTS stats_components_health",
		");")
	mustNotContainColumn(t, chBlock, "status",
		"BUILD §A.4 — stats_components_health.status would be CRITICAL")

	// All 7 component enum values present.
	for _, c := range []string{
		"'overview'", "'timeseries_rpm'", "'timeseries_tpm'",
		"'leaderboard_24h'", "'leaderboard_7d'",
		"'leaderboard_30d'", "'leaderboard_all'",
	} {
		mustContain(t, schema, c,
			"v0.1.7 component enum")
	}

	// Bootstrap seeds exactly 7 component rows.
	for _, c := range []string{"overview", "timeseries_rpm", "timeseries_tpm",
		"leaderboard_24h", "leaderboard_7d", "leaderboard_30d", "leaderboard_all"} {
		mustContain(t, bootstrap, "'"+c+"'",
			"bootstrap row for component "+c)
	}
}

func mustContain(t *testing.T, body, needle, why string) {
	t.Helper()
	if !strings.Contains(body, needle) {
		t.Errorf("expected %q in body (%s)", needle, why)
	}
}

func mustNotContain(t *testing.T, body, needle, why string) {
	t.Helper()
	if strings.Contains(body, needle) {
		t.Errorf("forbidden substring %q present in body (%s)", needle, why)
	}
}

// mustNotContainColumn is like mustNotContain but rejects only
// occurrences that look like a column declaration:
// `<whitespace><name><whitespace>` followed by a type token.
// Pure substring match is too aggressive for short column
// names like "status" which could appear in unrelated SQL
// (e.g. `last_error_message`, function names, etc.).
func mustNotContainColumn(t *testing.T, body, col, why string) {
	t.Helper()
	for _, line := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(line)
		// Match `status SOMETHING` at start of line, optionally
		// preceded by quote/identifier chars. A column
		// declaration like `status TEXT NOT NULL` always begins
		// at the column-name token after the indent.
		if strings.HasPrefix(trimmed, col+" ") || strings.HasPrefix(trimmed, col+"\t") {
			t.Errorf("column %q declared in body (%s); line: %q", col, why, trimmed)
			return
		}
	}
}

// stripSQLComments removes line comments (-- to end-of-line) and
// block comments (/* ... */) from a SQL string. Approximate but
// good enough for shape-shape sanity checks against a known
// migration file authored without nested comments.
func stripSQLComments(s string) string {
	var out strings.Builder
	out.Grow(len(s))
	i := 0
	for i < len(s) {
		// Block comment.
		if i+1 < len(s) && s[i] == '/' && s[i+1] == '*' {
			j := strings.Index(s[i+2:], "*/")
			if j < 0 {
				break
			}
			i += 2 + j + 2
			continue
		}
		// Line comment.
		if i+1 < len(s) && s[i] == '-' && s[i+1] == '-' {
			j := strings.IndexByte(s[i:], '\n')
			if j < 0 {
				break
			}
			i += j
			continue
		}
		out.WriteByte(s[i])
		i++
	}
	return out.String()
}

func extractBetween(body, start, end string) string {
	i := strings.Index(body, start)
	if i < 0 {
		return ""
	}
	rest := body[i:]
	j := strings.Index(rest, end)
	if j < 0 {
		return rest
	}
	return rest[:j+len(end)]
}
