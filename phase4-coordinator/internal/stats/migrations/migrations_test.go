package migrations

import (
	"os"
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
	// Step 1 now ships SPEC-017 stats migrations plus SPEC-026
	// identity/onboarding schema. Adjusting this count is a
	// forcing function to update the schema-shape assertions.
	want := []struct {
		ver  int
		name string
	}{
		{1, "stats_tables"},
		{2, "bootstrap_health_and_rewards"},
		{3, "roles"},
		{4, "grants"},
		{5, "oltp_source_grants"},
		{6, "spec_026_identity"},
		{7, "hardware_profiles"},
		{8, "hardware_verification_jobs"},
		{9, "provider_auth_policy_approve_fix"},
		{10, "partner_keys_provider_id"},
		{11, "idle_prewarm_events"},
		{12, "malibu_emission_ledger"},
		{13, "pow_w2_hello_gate_grants"},
		{14, "malibu_trust_unlock"},
		{15, "provider_onboarding_hardware_decision_reason"},
		{16, "hardware_profile_memory_reverification"},
		{17, "autotune_current_hardware_gate_grants"},
		{18, "apptrack_register_attempts"},
		{19, "hardware_trust_operator_approval"},
		{20, "waiting_trust_chip_profile_projection"},
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
	var schema, bootstrap, spec026, hardware, hardwareJobs, authPolicyApproveFix, idlePrewarm, powW2HelloGateGrants, onboardingDecisionReason, hardwareMemoryReverification, autotuneCurrentHardwareGateGrants, hardwareTrustApproval, waitingTrustChipProfileProjection string
	for _, m := range all {
		switch m.Name {
		case "stats_tables":
			schema = m.SQL
		case "bootstrap_health_and_rewards":
			bootstrap = m.SQL
		case "spec_026_identity":
			spec026 = m.SQL
		case "hardware_profiles":
			hardware = m.SQL
		case "hardware_verification_jobs":
			hardwareJobs = m.SQL
		case "provider_auth_policy_approve_fix":
			authPolicyApproveFix = m.SQL
		case "idle_prewarm_events":
			idlePrewarm = m.SQL
		case "pow_w2_hello_gate_grants":
			powW2HelloGateGrants = m.SQL
		case "provider_onboarding_hardware_decision_reason":
			onboardingDecisionReason = m.SQL
		case "hardware_profile_memory_reverification":
			hardwareMemoryReverification = m.SQL
		case "autotune_current_hardware_gate_grants":
			autotuneCurrentHardwareGateGrants = m.SQL
		case "hardware_trust_operator_approval":
			hardwareTrustApproval = m.SQL
		case "waiting_trust_chip_profile_projection":
			waitingTrustChipProfileProjection = m.SQL
		}
	}
	if schema == "" {
		t.Fatal("stats_tables migration body is empty")
	}
	if waitingTrustChipProfileProjection == "" {
		t.Fatal("waiting_trust_chip_profile_projection migration body is empty")
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

	if spec026 == "" {
		t.Fatal("spec_026_identity migration body is empty")
	}
	for _, needle := range []string{
		"CREATE TABLE IF NOT EXISTS provider_identities",
		"app_attest_key_id BYTEA NULL UNIQUE",
		"CREATE TABLE IF NOT EXISTS provider_register_nonces",
		"provider_id, nonce, ts_utc",
		"source_ip, nonce, ts_utc",
		"CREATE OR REPLACE FUNCTION prune_provider_register_nonces",
		"retain_for must be at least 65 seconds",
		"CREATE TABLE IF NOT EXISTS provider_auth_policy",
		"CREATE TABLE IF NOT EXISTS provider_auth_policy_cutover_runs",
		"CREATE TABLE IF NOT EXISTS provider_auth_policy_pending",
		"CREATE TABLE IF NOT EXISTS provider_auth_policy_grants",
		"grant_source     TEXT NOT NULL DEFAULT 'operator'",
		"'spec-026-cutover-legacy'",
		"pg_advisory_xact_lock(26026, hashtext",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_auth_policy_pending_open_incident",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_auth_policy_grants_incident",
		"CREATE OR REPLACE FUNCTION seed_provider_auth_policy_cutover",
		"CREATE OR REPLACE FUNCTION request_provider_auth_policy_exemption",
		"CREATE OR REPLACE FUNCTION approve_provider_auth_policy_exemption",
		"SET search_path = pg_catalog, public, pg_temp",
		"CREATE ROLE provider_onboarding LOGIN",
		"ALTER ROLE provider_onboarding LOGIN",
		"CREATE ROLE provider_auth_policy_definer NOLOGIN",
		"CREATE ROLE provider_auth_policy_requester NOLOGIN",
		"CREATE ROLE provider_auth_policy_approver NOLOGIN",
		"CREATE ROLE provider_auth_policy_cutover NOLOGIN",
		"ALTER ROLE provider_auth_policy_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
		"ALTER ROLE provider_auth_policy_requester NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
		"FROM pg_auth_members m",
		"GRANT USAGE, CREATE ON SCHEMA public TO provider_auth_policy_definer",
		"GRANT SELECT ON provider_identities TO provider_auth_policy_definer",
		"GRANT SELECT, INSERT, UPDATE ON provider_auth_policy TO provider_auth_policy_definer",
		"GRANT SELECT, INSERT, UPDATE ON provider_auth_policy_cutover_runs TO provider_auth_policy_definer",
		"GRANT SELECT, INSERT, UPDATE ON provider_auth_policy_pending TO provider_auth_policy_definer",
		"GRANT SELECT, INSERT ON provider_auth_policy_grants TO provider_auth_policy_definer",
		"REVOKE ALL ON provider_auth_policy_pending FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover",
		"REVOKE ALL ON provider_auth_policy_grants FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover",
		"GRANT SELECT, INSERT, UPDATE ON provider_identities TO provider_onboarding",
		"GRANT SELECT, INSERT ON provider_register_nonces TO provider_onboarding",
		"GRANT SELECT ON provider_auth_policy TO provider_onboarding",
		"REVOKE ALL ON FUNCTION prune_provider_register_nonces(INTERVAL) FROM provider_onboarding",
		"REVOKE ALL ON provider_auth_policy_pending FROM provider_onboarding",
		"REVOKE ALL ON provider_auth_policy_grants FROM provider_onboarding",
		"REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM provider_onboarding",
		"REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM provider_onboarding",
		"REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM provider_onboarding",
		"GRANT EXECUTE ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) TO provider_auth_policy_cutover",
		"GRANT EXECUTE ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO provider_auth_policy_requester",
		"GRANT EXECUTE ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) TO provider_auth_policy_approver",
		"ALTER FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) OWNER TO provider_auth_policy_definer",
		"ALTER FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) OWNER TO provider_auth_policy_definer",
		"ALTER FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) OWNER TO provider_auth_policy_definer",
		"REVOKE CREATE ON SCHEMA public FROM provider_auth_policy_definer",
	} {
		mustContain(t, spec026, needle, "SPEC-026 schema/grant shape")
	}
	if autotuneCurrentHardwareGateGrants == "" {
		t.Fatal("autotune current hardware gate grants forward migration body is empty")
	}
	for _, needle := range []string{
		"GRANT SELECT (",
		"provider_id",
		"chip_normalized",
		"unified_memory_gb",
		"verified",
		") ON provider_hardware_profiles TO provider_onboarding",
		"GRANT SELECT (\n    chip_normalized,\n    unified_memory_gb\n) ON hardware_verification_jobs TO provider_onboarding",
	} {
		mustContain(t, autotuneCurrentHardwareGateGrants, needle,
			"autotune admission can compare the current verified capacity tuple")
	}
	mustContain(t, spec026, "ON CONFLICT ON CONSTRAINT provider_auth_policy_pkey DO UPDATE",
		"SPEC-026 approval upsert must avoid PL/pgSQL output-column ambiguity")
	if authPolicyApproveFix == "" {
		t.Fatal("provider_auth_policy_approve_fix migration body is empty")
	}
	if idlePrewarm == "" {
		t.Fatal("idle_prewarm_events migration body is empty")
	}
	idlePrewarmCode := stripSQLComments(idlePrewarm)
	for _, s := range []string{
		"CREATE TABLE IF NOT EXISTS stats_idle_prewarm_events",
		"idle_prewarm_fired",
		"idle_prewarm_completed",
		"idle_prewarm_skipped",
		"idle_prewarm_cancelled_by_real_request",
		"idle_prewarm_failed",
		"(event = 'idle_prewarm_skipped' AND reason IS NOT NULL)",
		"(event <> 'idle_prewarm_skipped' AND reason IS NULL)",
		"GRANT SELECT, INSERT, DELETE ON stats_idle_prewarm_events TO stats_rollup",
		"GRANT SELECT ON stats_idle_prewarm_events TO stats_reader",
		"REVOKE ALL ON stats_idle_prewarm_events FROM provider_portal",
	} {
		mustContain(t, idlePrewarmCode, s, "issue #381 idle-prewarm migration contract")
	}
	mustContain(t, authPolicyApproveFix, "CREATE OR REPLACE FUNCTION approve_provider_auth_policy_exemption",
		"forward migration must replace the approval function on existing deployments")
	mustContain(t, authPolicyApproveFix, "CREATE OR REPLACE FUNCTION seed_provider_auth_policy_cutover",
		"forward migration must replace the cutover seed function on existing deployments")
	mustContain(t, authPolicyApproveFix, "CREATE OR REPLACE FUNCTION request_provider_auth_policy_exemption",
		"forward migration must replace the request function on existing deployments")
	mustContain(t, authPolicyApproveFix, "SET search_path = pg_catalog, public, pg_temp",
		"forward approval function must use hardened SECURITY DEFINER search path")
	if got := strings.Count(authPolicyApproveFix, "SET search_path = pg_catalog, public, pg_temp"); got < 3 {
		t.Fatalf("forward migration has %d hardened auth-policy function search_path clauses, want at least 3", got)
	}
	mustContain(t, authPolicyApproveFix, "ON CONFLICT ON CONSTRAINT provider_auth_policy_pkey DO UPDATE",
		"forward approval fix must avoid PL/pgSQL output-column ambiguity")
	for _, role := range []string{
		"provider_auth_policy_requester",
		"provider_auth_policy_approver",
		"provider_auth_policy_cutover",
	} {
		mustNotContain(t, authPolicyApproveFix, "ALTER ROLE "+role+" NOLOGIN",
			"forward migration must preserve existing login/password state for "+role)
	}
	for _, needle := range []string{
		"CREATE ROLE provider_auth_policy_definer NOLOGIN",
		"CREATE ROLE provider_auth_policy_requester NOLOGIN",
		"CREATE ROLE provider_auth_policy_approver NOLOGIN",
		"CREATE ROLE provider_auth_policy_cutover NOLOGIN",
		"ALTER ROLE provider_auth_policy_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
		"ALTER ROLE provider_auth_policy_requester NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
		"FROM pg_auth_members m",
		"GRANT SELECT, INSERT, UPDATE ON provider_auth_policy_pending TO provider_auth_policy_definer",
		"REVOKE ALL ON provider_auth_policy_pending FROM provider_auth_policy_requester, provider_auth_policy_approver, provider_auth_policy_cutover",
		"REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM PUBLIC",
		"REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM PUBLIC",
		"REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM PUBLIC",
		"REVOKE ALL ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) FROM provider_onboarding",
		"REVOKE ALL ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) FROM provider_onboarding",
		"REVOKE ALL ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) FROM provider_onboarding",
		"GRANT EXECUTE ON FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) TO provider_auth_policy_cutover",
		"GRANT EXECUTE ON FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO provider_auth_policy_requester",
		"GRANT EXECUTE ON FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) TO provider_auth_policy_approver",
		"ALTER FUNCTION seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[]) OWNER TO provider_auth_policy_definer",
		"ALTER FUNCTION request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT) OWNER TO provider_auth_policy_definer",
		"ALTER FUNCTION approve_provider_auth_policy_exemption(UUID, TEXT) OWNER TO provider_auth_policy_definer",
		"REVOKE CREATE ON SCHEMA public FROM provider_auth_policy_definer",
	} {
		mustContain(t, authPolicyApproveFix, needle, "forward migration auth-policy privilege repair")
	}
	down, err := os.ReadFile("006_spec_026_identity.down.sql")
	if err != nil {
		t.Fatalf("read SPEC-026 rollback artifact: %v", err)
	}
	downSQL := string(down)
	for _, needle := range []string{
		"DROP TABLE IF EXISTS provider_auth_policy_pending",
		"DROP TABLE IF EXISTS provider_auth_policy_grants",
		"DROP TABLE IF EXISTS provider_auth_policy_cutover_runs",
		"DROP TABLE IF EXISTS provider_auth_policy",
		"DROP FUNCTION IF EXISTS seed_provider_auth_policy_cutover(TIMESTAMPTZ, TEXT[])",
		"DROP FUNCTION IF EXISTS request_provider_auth_policy_exemption(UUID, TEXT, TEXT, TIMESTAMPTZ, TEXT, TEXT)",
		"DROP FUNCTION IF EXISTS approve_provider_auth_policy_exemption(UUID, TEXT)",
		"DROP FUNCTION IF EXISTS prune_provider_register_nonces(INTERVAL)",
		"DROP TABLE IF EXISTS provider_register_nonces",
		"DROP TABLE IF EXISTS provider_identities",
		"DROP ROLE IF EXISTS provider_auth_policy_cutover",
		"DROP ROLE IF EXISTS provider_auth_policy_approver",
		"DROP ROLE IF EXISTS provider_auth_policy_requester",
		"DROP ROLE IF EXISTS provider_auth_policy_definer",
		"DROP ROLE IF EXISTS provider_onboarding",
	} {
		mustContain(t, downSQL, needle, "SPEC-026 rollback artifact")
	}
	if hardware == "" {
		t.Fatal("hardware_profiles migration body is empty")
	}
	hardwareCode := stripSQLComments(hardware)
	for _, needle := range []string{
		"CREATE TABLE IF NOT EXISTS provider_hardware_profiles",
		"chip_normalized      TEXT NOT NULL",
		"verified             BOOLEAN NOT NULL DEFAULT FALSE",
		"CREATE TABLE IF NOT EXISTS chip_hardware_profiles",
		"memory_bandwidth_gb_per_s    BIGINT NOT NULL",
		"CREATE OR REPLACE FUNCTION provider_hardware_profiles_guard_verification",
		"current_user <> 'provider_onboarding'",
		"NEW.verified := FALSE",
		"NEW.verified := OLD.verified",
		"CREATE TRIGGER trg_provider_hardware_profiles_guard_verification",
		"GRANT SELECT (provider_id, last_reported_at) ON provider_hardware_profiles TO provider_onboarding",
		"GRANT INSERT (",
		"GRANT UPDATE (",
		"last_reported_at\n) ON provider_hardware_profiles TO provider_onboarding",
		"GRANT SELECT ON",
		"provider_hardware_profiles",
		"chip_hardware_profiles",
		"TO stats_rollup",
		"FROM stats_reader, provider_portal",
	} {
		mustContain(t, hardware, needle, "hardware profile schema/grant shape")
	}
	mustNotContain(t, hardwareCode,
		"GRANT SELECT, INSERT, UPDATE ON provider_hardware_profiles TO provider_onboarding",
		"provider_onboarding must not receive table-wide hardware writes")
	mustNotContain(t, hardwareCode,
		"verified\n) ON provider_hardware_profiles TO provider_onboarding",
		"provider_onboarding must not receive column grants on verified")
	hardwareDown, err := os.ReadFile("007_hardware_profiles.down.sql")
	if err != nil {
		t.Fatalf("read hardware rollback artifact: %v", err)
	}
	hardwareDownSQL := string(hardwareDown)
	for _, needle := range []string{
		"REVOKE ALL ON provider_hardware_profiles FROM stats_rollup",
		"REVOKE ALL ON chip_hardware_profiles FROM stats_rollup",
		"REVOKE ALL ON provider_hardware_profiles FROM provider_onboarding",
		"REVOKE ALL ON FUNCTION provider_hardware_profiles_guard_verification() FROM PUBLIC",
		"DROP TRIGGER IF EXISTS trg_provider_hardware_profiles_guard_verification",
		"DROP FUNCTION IF EXISTS provider_hardware_profiles_guard_verification()",
		"DROP TABLE IF EXISTS chip_hardware_profiles",
		"DROP TABLE IF EXISTS provider_hardware_profiles",
	} {
		mustContain(t, hardwareDownSQL, needle, "hardware rollback artifact")
	}
	if hardwareJobs == "" {
		t.Fatal("hardware_verification_jobs migration body is empty")
	}
	hardwareJobsCode := stripSQLComments(hardwareJobs)
	for _, needle := range []string{
		"CREATE TABLE IF NOT EXISTS hardware_verification_jobs",
		"CREATE TABLE IF NOT EXISTS hardware_verification_trust",
		"status                     TEXT NOT NULL CHECK (status IN ('pending', 'waiting_trust', 'verified', 'rejected')) DEFAULT 'pending'",
		"evidence                   JSONB NOT NULL",
		"evidence_sha256            TEXT NOT NULL UNIQUE",
		"CREATE ROLE stats_hardware_verifier NOLOGIN",
		"ALTER ROLE stats_hardware_verifier NOLOGIN",
		"GRANT USAGE ON SCHEMA public TO stats_hardware_verifier",
		"GRANT SELECT (",
		"status,\n    submitted_at,\n    evidence_sha256\n) ON hardware_verification_jobs TO provider_onboarding",
		"GRANT INSERT (",
		"evidence_sha256\n) ON hardware_verification_jobs TO provider_onboarding",
		"GRANT USAGE, SELECT ON SEQUENCE hardware_verification_jobs_id_seq TO provider_onboarding",
		"current_user = 'stats_hardware_verifier'",
		"stats_hardware_verifier promotion requires matching trusted hardware evidence",
		"stats_hardware_verifier may not move hardware profile timestamps backward",
		"j.generated_at >= now() - interval '7 days'",
		"j.status IN ('pending', 'waiting_trust')",
		"FROM hardware_verification_jobs j",
		"JOIN hardware_verification_trust t",
		"JOIN chip_hardware_profiles ch",
		"CREATE OR REPLACE FUNCTION hardware_verification_jobs_guard_verifier_update()",
		"stats_hardware_verifier may not update finalized hardware verification jobs",
		"stats_hardware_verifier may only move jobs to waiting_trust, verified, or rejected",
		"CREATE TRIGGER trg_hardware_verification_jobs_guard_verifier_update",
		"REVOKE ALL ON FUNCTION hardware_verification_jobs_guard_verifier_update() FROM PUBLIC",
		"GRANT SELECT ON hardware_verification_jobs TO stats_hardware_verifier",
		"GRANT UPDATE (\n    status,\n    processed_at,\n    decision_reason\n) ON hardware_verification_jobs TO stats_hardware_verifier",
		"GRANT SELECT ON hardware_verification_trust TO stats_hardware_verifier",
		"GRANT SELECT ON provider_hardware_profiles TO stats_hardware_verifier",
		"GRANT INSERT (",
		"verified,\n    last_reported_at\n) ON provider_hardware_profiles TO stats_hardware_verifier",
		"GRANT UPDATE (",
		"verified,\n    last_reported_at\n) ON provider_hardware_profiles TO stats_hardware_verifier",
		"GRANT SELECT ON chip_hardware_profiles TO stats_hardware_verifier",
	} {
		mustContain(t, hardwareJobs, needle, "hardware verification job schema/grant shape")
	}
	if onboardingDecisionReason == "" {
		t.Fatal("provider_onboarding decision_reason forward migration body is empty")
	}
	mustContain(t, onboardingDecisionReason,
		"GRANT SELECT (decision_reason)\nON hardware_verification_jobs\nTO provider_onboarding",
		"existing provider_onboarding role gains replay decision_reason read")
	if hardwareMemoryReverification == "" {
		t.Fatal("hardware profile memory reverification forward migration body is empty")
	}
	hardwareMemoryReverificationCode := stripSQLComments(hardwareMemoryReverification)
	for _, needle := range []string{
		"CREATE OR REPLACE FUNCTION provider_hardware_profiles_guard_verification",
		"NEW.chip_normalized IS DISTINCT FROM OLD.chip_normalized",
		"OR NEW.unified_memory_gb IS DISTINCT FROM OLD.unified_memory_gb",
		"NEW.verified := FALSE",
		"NEW.verified := OLD.verified",
		"REVOKE ALL ON FUNCTION provider_hardware_profiles_guard_verification() FROM PUBLIC",
	} {
		mustContain(t, hardwareMemoryReverificationCode, needle,
			"existing deployments clear hardware verification when the capacity tuple changes")
	}
	mustNotContain(t, hardwareJobsCode,
		"PASSWORD 'REPLACE_ME'",
		"embedded migrations must not create committed placeholder passwords")
	mustNotContain(t, hardwareJobsCode,
		"CREATE ROLE stats_hardware_verifier LOGIN",
		"stats_hardware_verifier login must be enabled only by operator bootstrap with secret material")
	mustNotContain(t, hardwareJobsCode,
		"GRANT UPDATE ON hardware_verification_jobs TO provider_onboarding",
		"provider_onboarding must not process hardware jobs")
	mustNotContain(t, hardwareJobsCode,
		"GRANT SELECT, INSERT, UPDATE ON chip_hardware_profiles TO stats_hardware_verifier",
		"stats_hardware_verifier must not write operator-managed chip capacity inventory")
	mustNotContain(t, hardwareJobsCode,
		"GRANT SELECT, UPDATE ON hardware_verification_jobs TO stats_hardware_verifier",
		"stats_hardware_verifier job writes must be column limited")
	mustNotContain(t, hardwareJobsCode,
		"GRANT SELECT, INSERT, UPDATE ON provider_hardware_profiles TO stats_hardware_verifier",
		"stats_hardware_verifier profile writes must be column limited and trigger guarded")
	mustNotContain(t, hardwareJobsCode,
		"j.status IN ('pending', 'waiting_trust', 'verified')",
		"stats_hardware_verifier must not replay finalized verification jobs")
	hardwareJobsDown, err := os.ReadFile("008_hardware_verification_jobs.down.sql")
	if err != nil {
		t.Fatalf("read hardware verification rollback artifact: %v", err)
	}
	hardwareJobsDownSQL := string(hardwareJobsDown)
	for _, needle := range []string{
		"REVOKE ALL ON hardware_verification_jobs FROM provider_onboarding",
		"REVOKE ALL ON hardware_verification_trust FROM provider_onboarding",
		"REVOKE ALL ON SEQUENCE hardware_verification_jobs_id_seq FROM provider_onboarding",
		"REVOKE ALL ON hardware_verification_jobs FROM stats_hardware_verifier",
		"REVOKE ALL ON hardware_verification_trust FROM stats_hardware_verifier",
		"REVOKE ALL ON provider_hardware_profiles FROM stats_hardware_verifier",
		"REVOKE ALL ON chip_hardware_profiles FROM stats_hardware_verifier",
		"REVOKE USAGE ON SCHEMA public FROM stats_hardware_verifier",
		"REVOKE ALL ON FUNCTION hardware_verification_jobs_guard_verifier_update() FROM PUBLIC",
		"DROP TRIGGER IF EXISTS trg_hardware_verification_jobs_guard_verifier_update",
		"DROP FUNCTION IF EXISTS hardware_verification_jobs_guard_verifier_update()",
		"DROP TABLE IF EXISTS hardware_verification_trust",
		"DROP TABLE IF EXISTS hardware_verification_jobs",
		"DROP ROLE IF EXISTS stats_hardware_verifier",
	} {
		mustContain(t, hardwareJobsDownSQL, needle, "hardware verification rollback artifact")
	}
	if powW2HelloGateGrants == "" {
		t.Fatal("pow_w2_hello_gate_grants migration body is empty")
	}
	mustContain(t, powW2HelloGateGrants,
		"GRANT SELECT (\n    generated_at,\n    evidence\n) ON hardware_verification_jobs TO provider_onboarding",
		"provider_onboarding hello gate read grants")
	if hardwareTrustApproval == "" {
		t.Fatal("hardware_trust_operator_approval migration body is empty")
	}
	hardwareTrustApprovalCode := stripSQLComments(hardwareTrustApproval)
	for _, needle := range []string{
		"ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'inventory'",
		"CHECK (source IN ('inventory', 'operator_api'))",
		// Terminal structural fix: the trust table PK is widened to include source so
		// the operator-approval and inventory-sync authorities own independent rows.
		"DROP CONSTRAINT hardware_verification_trust_pkey",
		"ADD PRIMARY KEY (provider_id, hardware_identity_hash, source)",
		"CREATE ROLE hardware_trust_definer NOLOGIN",
		"CREATE ROLE hardware_trust_requester NOLOGIN",
		"CREATE ROLE hardware_trust_approver NOLOGIN",
		"ALTER ROLE hardware_trust_definer NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
		"CREATE TABLE IF NOT EXISTS hardware_trust_pending",
		"CREATE TABLE IF NOT EXISTS hardware_trust_grants",
		"job_id",
		"cancelled_at",
		"CHECK (action IN ('grant', 'revoke'))",
		"CHECK (approved_by IS NULL OR approved_by <> requested_by)",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_pending_open_incident",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_pending_open_identity",
		"WHERE committed_at IS NULL AND cancelled_at IS NULL",
		"CREATE UNIQUE INDEX IF NOT EXISTS idx_hardware_trust_grants_incident",
		"CREATE OR REPLACE FUNCTION request_hardware_trust_approval",
		"CREATE OR REPLACE FUNCTION approve_hardware_trust_approval",
		"CREATE OR REPLACE FUNCTION revoke_hardware_trust_approval",
		// FIX 1 (round-12): revoke reports whether the tuple is now FULLY untrusted
		// (no active trust root of any source) so the handler evicts the live session
		// only then — a still-active inventory root leaves the session connected.
		"out_now_untrusted BOOLEAN",
		"now_untrusted := NOT EXISTS (",
		"SET search_path = pg_catalog, public, pg_temp",
		"dual_control_required",
		"job not waiting_trust",
		"job no longer waiting_trust",
		"hardware_trust_pending_expired",
		// Approval upserts ONLY the operator_api row via the 3-column conflict target;
		// it never rides or clobbers an inventory row (terminal structural fix #582).
		"ON CONFLICT (provider_id, hardware_identity_hash, source) DO UPDATE",
		"'operator_api'",
		"job not approvable via hardware trust",
		// FIX 1: both job reads lock FOR SHARE to serialize against the verifier,
		// permitted by a LOCK-ONLY column-level UPDATE(status) grant.
		"FOR SHARE",
		"GRANT UPDATE (status) ON hardware_verification_jobs TO hardware_trust_definer",
		// FIX 1: the profile-promotion guard trigger and the SQL functions compare
		// trust activity against clock_timestamp() (real time, advances mid-tx),
		// not the frozen now(), so a mid-transaction revocation is seen as inactive.
		"AND (t.expires_at IS NULL OR t.expires_at > clock_timestamp())",
		"revoke_time := clock_timestamp();",
		"approval_time := clock_timestamp();",
		// FIX 3 (round-8): approval re-checks a chip profile exists for the job's chip
		// so the verifier cannot re-park an approved job for missing_trusted_chip_profile.
		"hardware_trust_chip_profile_missing",
		"FROM chip_hardware_profiles ch",
		"GRANT SELECT (chip_normalized) ON chip_hardware_profiles TO hardware_trust_definer",
		// FIX 4 (round-8): approval gates the OLDEST benchmark timestamp on the same
		// evidence-age boundary the verifier's stale_benchmark check uses.
		"SELECT min((b->>'generated_at')::timestamptz)",
		"FROM jsonb_array_elements(COALESCE(job.evidence->'benchmarks', '[]'::jsonb)) b",
		// Approval returns source/effective-expiry columns (retained; scanned
		// positionally by the Go store). Post terminal fix these are always
		// 'operator_api' and the operator_api row's expiry.
		"out_source TEXT",
		"out_effective_expires_at TIMESTAMPTZ",
		// FIX 5 (round-6): approval rejects a job whose evidence aged past the
		// verifier's limit with a distinct error. The 7-day window is HARDCODED as a
		// definer-owned invariant (kept in sync with hardwareverify.MaxEvidenceAgeDays)
		// rather than a caller parameter, so it cannot be bypassed.
		"IF job.generated_at < approval_time - interval '7 days' THEN",
		"hardware_trust_job_evidence_stale",
		// FIX 6 (round-6): approval rejects up front when the effective trust root
		// lacks a small (5-minute) promotion runway, so a "success" cannot re-park or
		// reject moments later on the next verifier tick.
		"hardware_trust_promotion_runway_insufficient",
		// FIX 4: revoke atomically demotes, so the definer reads the job evidence
		// tuple and flips the profile verified bit.
		"GRANT UPDATE (verified) ON provider_hardware_profiles TO hardware_trust_definer",
		"GRANT SELECT (chip) ON hardware_verification_jobs TO provider_onboarding",
		// FIX 4 (round-6): the autotune admission gate (LatestVerified) now joins
		// hardware_verification_trust to re-check live trust, so provider_onboarding
		// needs a READ-ONLY SELECT on the trust table (re-added; round-3 had removed
		// it). Write boundary preserved — still no INSERT/UPDATE/DELETE or EXECUTE.
		"GRANT SELECT ON hardware_verification_trust TO provider_onboarding",
		"GRANT SELECT (id, provider_id, status, chip_normalized, unified_memory_gb, os_version, binary_version, generated_at, evidence, decision_reason) ON hardware_verification_jobs TO hardware_trust_definer",
		"GRANT SELECT, INSERT, UPDATE ON hardware_verification_trust TO hardware_trust_definer",
		"GRANT EXECUTE ON FUNCTION request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT) TO hardware_trust_requester",
		"GRANT EXECUTE ON FUNCTION approve_hardware_trust_approval(UUID, TEXT) TO hardware_trust_approver",
		"GRANT EXECUTE ON FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) TO hardware_trust_approver",
		"ALTER FUNCTION request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT) OWNER TO hardware_trust_definer",
		"ALTER FUNCTION approve_hardware_trust_approval(UUID, TEXT) OWNER TO hardware_trust_definer",
		"ALTER FUNCTION revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT) OWNER TO hardware_trust_definer",
		"REVOKE CREATE ON SCHEMA public FROM hardware_trust_definer",
	} {
		mustContain(t, hardwareTrustApprovalCode, needle, "hardware trust operator approval schema/grant shape")
	}
	// Anti-fraud boundary: provider_onboarding must never write the trust root.
	mustNotContain(t, hardwareTrustApprovalCode,
		"INSERT, UPDATE ON hardware_verification_trust TO provider_onboarding",
		"provider_onboarding must not receive trust-table writes")
	mustNotContain(t, hardwareTrustApprovalCode,
		"GRANT INSERT ON hardware_verification_trust TO provider_onboarding",
		"provider_onboarding must not receive trust-table inserts")
	mustNotContain(t, hardwareTrustApprovalCode,
		"GRANT UPDATE ON hardware_verification_trust TO provider_onboarding",
		"provider_onboarding must not receive trust-table updates")
	// FIX 4 (round-6): provider_onboarding now DOES hold a READ-ONLY SELECT on
	// hardware_verification_trust (asserted positively above) so the LatestVerified
	// admission gate can re-check live trust. The anti-fraud boundary is the WRITE
	// grants only (mustNotContain above), never the read.
	waitingTrustChipProfileProjectionCode := stripSQLComments(waitingTrustChipProfileProjection)
	mustContain(t, waitingTrustChipProfileProjectionCode,
		"GRANT SELECT (chip_normalized) ON chip_hardware_profiles TO provider_onboarding",
		"waiting-trust projection can evaluate chip-profile presence with a column-limited runtime-role grant")
	mustNotContain(t, waitingTrustChipProfileProjectionCode,
		"GRANT SELECT ON chip_hardware_profiles TO provider_onboarding",
		"provider_onboarding must not receive table-wide chip profile read")
	mustNotContain(t, waitingTrustChipProfileProjectionCode,
		"INSERT, UPDATE ON chip_hardware_profiles TO provider_onboarding",
		"provider_onboarding must not receive chip profile writes")
	mustNotContain(t, waitingTrustChipProfileProjectionCode,
		"GRANT INSERT ON chip_hardware_profiles TO provider_onboarding",
		"provider_onboarding must not receive chip profile inserts")
	mustNotContain(t, waitingTrustChipProfileProjectionCode,
		"GRANT UPDATE ON chip_hardware_profiles TO provider_onboarding",
		"provider_onboarding must not receive chip profile updates")
	waitingTrustChipProfileProjectionDown, err := os.ReadFile("020_waiting_trust_chip_profile_projection.down.sql")
	if err != nil {
		t.Fatalf("read waiting-trust chip-profile projection rollback artifact: %v", err)
	}
	waitingTrustChipProfileProjectionDownSQL := string(waitingTrustChipProfileProjectionDown)
	for _, needle := range []string{
		"\\set ON_ERROR_STOP on",
		"BEGIN;",
		"REVOKE SELECT (chip_normalized) ON chip_hardware_profiles FROM provider_onboarding",
		"DELETE FROM schema_migrations_spec017 WHERE version = 20;",
		"COMMIT;",
	} {
		mustContain(t, waitingTrustChipProfileProjectionDownSQL, needle, "waiting-trust chip-profile projection rollback artifact")
	}

	hardwareTrustApprovalDown, err := os.ReadFile("019_hardware_trust_operator_approval.down.sql")
	if err != nil {
		t.Fatalf("read hardware trust approval rollback artifact: %v", err)
	}
	hardwareTrustApprovalDownSQL := string(hardwareTrustApprovalDown)
	for _, needle := range []string{
		"DROP FUNCTION IF EXISTS revoke_hardware_trust_approval(UUID, TEXT, TEXT, TEXT, TEXT)",
		"DROP FUNCTION IF EXISTS approve_hardware_trust_approval(UUID, TEXT)",
		"DROP FUNCTION IF EXISTS request_hardware_trust_approval(UUID, BIGINT, TEXT, TIMESTAMPTZ, TEXT, TEXT)",
		"DROP TABLE IF EXISTS hardware_trust_grants",
		"DROP TABLE IF EXISTS hardware_trust_pending",
		"DELETE FROM hardware_verification_trust WHERE source = 'operator_api'",
		"ALTER TABLE hardware_verification_trust DROP COLUMN IF EXISTS source",
		// Rollback restores migration 008's 2-column primary key after removing the
		// operator_api rows (duplicate resolution) and dropping the source column.
		"DROP CONSTRAINT hardware_verification_trust_pkey",
		"ADD PRIMARY KEY (provider_id, hardware_identity_hash)",
		"DROP ROLE IF EXISTS hardware_trust_approver",
		"DROP ROLE IF EXISTS hardware_trust_requester",
		"DROP ROLE IF EXISTS hardware_trust_definer",
		// FIX 4: atomic + fail-fast so a mid-script failure rolls back the whole
		// rollback and the script is re-runnable.
		"\\set ON_ERROR_STOP on",
		"BEGIN;",
		"COMMIT;",
		// FIX 4(a): demote profiles backed only by operator_api roots BEFORE the
		// roots are deleted, so rollback never strands admission trusting a
		// removed root.
		"SET verified = FALSE",
		"AND t.source <> 'operator_api'",
		// rollback removes 019's recorded version row so a later migrate re-applies
		// 019 rather than leaving 19 recorded while the feature is gone. Scoped to 19
		// only — must never touch version 18 (018_apptrack_register_attempts).
		"DELETE FROM schema_migrations_spec017 WHERE version = 19;",
		// FIX 1: rollback restores migration 016's guard body (trust activity on
		// now()) so the trigger returns to its exact pre-019 definition.
		"AND (t.expires_at IS NULL OR t.expires_at > now())",
		// FIX 4 (round-6): rollback also revokes the read-only trust SELECT that the
		// up migration re-added to provider_onboarding for the admission re-check.
		"REVOKE SELECT ON hardware_verification_trust FROM provider_onboarding",
	} {
		mustContain(t, hardwareTrustApprovalDownSQL, needle, "hardware trust operator approval rollback artifact")
	}
}

// TestValidateNoDuplicateVersions covers the FIX D (issue #582) runner guard
// that rejects two embedded migrations sharing one integer version — the
// duplicate-018 collision class — so the second cannot be silently skipped by
// Apply's already-applied guard.
func TestValidateNoDuplicateVersions(t *testing.T) {
	if err := validateNoDuplicateVersions([]Migration{
		{Version: 1, Name: "a"},
		{Version: 2, Name: "b"},
		{Version: 3, Name: "c"},
	}); err != nil {
		t.Fatalf("distinct versions rejected: %v", err)
	}
	err := validateNoDuplicateVersions([]Migration{
		{Version: 18, Name: "apptrack_register_attempts"},
		{Version: 18, Name: "hardware_trust_operator_approval"},
	})
	if err == nil {
		t.Fatal("duplicate version accepted, want error")
	}
	if !strings.Contains(err.Error(), "duplicate migration version 18") {
		t.Fatalf("error = %q, want it to name the duplicate version", err)
	}
	// The real embedded set must be collision-free.
	if _, err := All(); err != nil {
		t.Fatalf("embedded migrations failed duplicate-version guard: %v", err)
	}
}

// TestValidateAppliedNames covers the FIX D (issue #582) Apply guard that rejects
// a recorded schema_migrations_spec017 row whose name differs from the embedded
// migration of the same version (a diverged-history / renumber-on-one-side drift),
// while ignoring recorded versions that no longer have an embedded counterpart
// (a normal rollback/removal).
func TestValidateAppliedNames(t *testing.T) {
	embedded := []Migration{
		{Version: 18, Name: "apptrack_register_attempts"},
		{Version: 19, Name: "hardware_trust_operator_approval"},
	}
	// Matching recorded names → no error.
	if err := validateAppliedNames(map[int]string{
		18: "apptrack_register_attempts",
		19: "hardware_trust_operator_approval",
	}, embedded); err != nil {
		t.Fatalf("matching applied names rejected: %v", err)
	}
	// Name drift on a recorded version → error.
	err := validateAppliedNames(map[int]string{
		18: "hardware_trust_operator_approval",
	}, embedded)
	if err == nil {
		t.Fatal("applied-version name mismatch accepted, want error")
	}
	if !strings.Contains(err.Error(), "version 18") {
		t.Fatalf("error = %q, want it to name the drifted version", err)
	}
	// Recorded version with no embedded counterpart (rollback/removal) → ignored.
	if err := validateAppliedNames(map[int]string{
		17: "some_removed_migration",
	}, embedded); err != nil {
		t.Fatalf("recorded-only version treated as drift: %v", err)
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

func TestApptrackRegisterAttemptsMigrationShape(t *testing.T) {
	all, err := All()
	if err != nil {
		t.Fatalf("All: %v", err)
	}
	var body string
	for _, m := range all {
		if m.Name == "apptrack_register_attempts" {
			body = m.SQL
		}
	}
	if body == "" {
		t.Fatal("apptrack_register_attempts migration body is empty")
	}
	for _, needle := range []string{
		"CREATE TABLE IF NOT EXISTS provider_register_attempts",
		"PRIMARY KEY (provider_id, nonce, ts_utc)",
		"CREATE OR REPLACE FUNCTION prune_provider_register_attempts",
		"retain_for must be at least 7 days",
		"SET search_path = pg_catalog, public, pg_temp",
		"REVOKE INSERT ON provider_register_attempts FROM provider_onboarding",
		"GRANT SELECT ON provider_register_attempts TO provider_onboarding",
		"GRANT INSERT (provider_id, nonce, ts_utc, source_ip)",
		"REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM PUBLIC",
		"REVOKE ALL ON FUNCTION prune_provider_register_attempts(INTERVAL) FROM provider_onboarding",
	} {
		mustContain(t, body, needle, "durable registration attempt marker migration")
	}
	mustNotContain(t, body, "GRANT DELETE ON provider_register_attempts",
		"runtime onboarding role must not delete durable attempt markers")
	mustNotContain(t, body, "GRANT SELECT, INSERT ON provider_register_attempts",
		"runtime onboarding role must not receive table-level insert")
	mustNotContain(t, body, "PRIMARY KEY (provider_id, nonce, ts_utc, source_ip)",
		"connection metadata must not participate in commitment identity")

	down, err := os.ReadFile("018_apptrack_register_attempts.down.sql")
	if err != nil {
		t.Fatalf("read rollback artifact: %v", err)
	}
	downSQL := string(down)
	for _, needle := range []string{
		"REVOKE ALL ON provider_register_attempts FROM provider_onboarding",
		"DROP FUNCTION IF EXISTS prune_provider_register_attempts(INTERVAL)",
		"DROP TABLE IF EXISTS provider_register_attempts",
	} {
		mustContain(t, downSQL, needle, "registration attempt rollback artifact")
	}
}
