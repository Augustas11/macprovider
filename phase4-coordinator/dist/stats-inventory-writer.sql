-- Dedicated roles for the stats inventory sidecar.
--
-- Replace both passwords before applying. Keep the trust writer credential
-- separate from the ordinary inventory writer; it controls promotion roots for
-- provider-submitted hardware evidence.

DO $do$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'stats_inventory_writer') THEN
      CREATE ROLE stats_inventory_writer LOGIN PASSWORD 'REPLACE_ME';
   END IF;
   IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'stats_trust_inventory_writer') THEN
      CREATE ROLE stats_trust_inventory_writer LOGIN PASSWORD 'REPLACE_ME_WITH_DIFFERENT_SECRET';
   END IF;
END
$do$;

GRANT USAGE ON SCHEMA public TO stats_inventory_writer;
GRANT USAGE ON SCHEMA public TO stats_trust_inventory_writer;

GRANT SELECT, INSERT, UPDATE, DELETE ON chip_hardware_profiles TO stats_inventory_writer;
GRANT SELECT, INSERT, UPDATE ON provider_hardware_profiles TO stats_inventory_writer;
GRANT SELECT ON hardware_verification_jobs TO stats_inventory_writer;
GRANT SELECT ON hardware_verification_trust TO stats_inventory_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON hardware_verification_trust TO stats_trust_inventory_writer;
