-- Waiting-trust admin projection reads only chip_hardware_profiles.chip_normalized
-- to report whether a parked job has the chip profile required by the hardware
-- trust approval function. Keep provider_onboarding's access column-limited:
-- the role still cannot write chip inventory or trust roots.
GRANT SELECT (chip_normalized) ON chip_hardware_profiles TO provider_onboarding;
