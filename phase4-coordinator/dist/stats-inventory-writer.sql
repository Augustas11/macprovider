-- Dedicated role for the stats inventory sidecar.
--
-- Replace the password before applying. This role can update only the trusted
-- inventory tables used by the existing asynchronous stats hardware cache.

CREATE ROLE stats_inventory_writer LOGIN PASSWORD 'REPLACE_ME';

GRANT USAGE ON SCHEMA public TO stats_inventory_writer;

GRANT SELECT, INSERT, UPDATE, DELETE ON chip_hardware_profiles TO stats_inventory_writer;
GRANT SELECT, INSERT, UPDATE ON provider_hardware_profiles TO stats_inventory_writer;
