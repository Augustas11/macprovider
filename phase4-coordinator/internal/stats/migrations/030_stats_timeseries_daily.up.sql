-- Issue #1736. Complete UTC days for GET /v1/stats/overview timeseries.daily_90d.
-- Written by the overview rollup tick. Request-path reads are stats_reader only.

CREATE TABLE IF NOT EXISTS stats_timeseries_daily (
    day_start      DATE PRIMARY KEY,
    requests       BIGINT NOT NULL,
    input_tokens   BIGINT NOT NULL,
    output_tokens  BIGINT NOT NULL
);

GRANT SELECT ON stats_timeseries_daily TO stats_reader;
GRANT SELECT, INSERT, DELETE ON stats_timeseries_daily TO stats_rollup;

REVOKE ALL ON stats_timeseries_daily FROM provider_portal;
