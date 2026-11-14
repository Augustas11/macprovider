#!/usr/bin/env bash
# Closed registry for the parameterized signed-journey jobs.
# The workflow job selects the journey. This case rejects every other value,
# including a journey that belongs to a different secret or promotion mode.
set -euo pipefail
case "${JOURNEY:-}" in
  buyer-enforce)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-BUYER-ENFORCE
    evidence_regex='^journeys/evidence/buyer-enforce-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-buyer-enforce-journey-result.py)
    payload_prefix=buyer-enforce-journey-result
    artifact_prefix=signed-buyer-enforce-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-buyer-enforce-journey-promotion
    schema=macprovider.signed-buyer-enforce-journey-promotion.v1
    copy_conformance=yes
    ;;
  buyer-crash-recovery)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-BUYER-CRASH-RECOVERY
    evidence_regex='^journeys/evidence/buyer-crash-recovery-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-buyer-crash-recovery-journey-result.py)
    payload_prefix=buyer-crash-recovery-journey-result
    artifact_prefix=signed-buyer-crash-recovery-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-buyer-crash-recovery-journey-promotion
    schema=macprovider.signed-buyer-crash-recovery-journey-promotion.v1
    copy_conformance=yes
    ;;
  buyer-paid-path)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-BUYER-PAID-PATH
    evidence_regex='^journeys/evidence/buyer-paid-path-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-buyer-paid-path-journey-result.py)
    payload_prefix=buyer-paid-path-journey-result
    artifact_prefix=signed-buyer-paid-path-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-buyer-paid-path-journey-promotion
    schema=macprovider.signed-buyer-paid-path-journey-promotion.v1
    copy_conformance=yes
    ;;
  byom-discovery)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-PROVIDER-BYOM-DISCOVERY
    evidence_regex='^journeys/evidence/provider-byom-discovery-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-byom-discovery-journey-result.py)
    payload_prefix=byom-discovery-journey-result
    artifact_prefix=signed-byom-discovery-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-byom-discovery-journey-promotion
    schema=macprovider.signed-byom-discovery-journey-promotion.v1
    copy_conformance=yes
    ;;
  network-model-admission)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-NETWORK-MODEL-ADMISSION
    evidence_regex='^journeys/evidence/network-model-admission-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-network-model-admission-journey-result.py)
    payload_prefix=network-model-admission-journey-result
    artifact_prefix=signed-network-model-admission-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-network-model-admission-journey-promotion
    schema=macprovider.signed-network-model-admission-journey-promotion.v1
    copy_conformance=yes
    ;;
  provider-prebeta)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-PROVIDER-PREBETA-ADMISSION
    evidence_regex='^journeys/evidence/provider-prebeta-admission-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-provider-prebeta-journey-result.py)
    payload_prefix=provider-prebeta-journey-result
    artifact_prefix=signed-provider-prebeta-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-provider-prebeta-journey-promotion
    schema=macprovider.signed-provider-prebeta-journey-promotion.v1
    copy_conformance=yes
    ;;
  trusted-pool-external-runtime)
    mode=promote
    confirm=promotion
    journey_id=JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME
    evidence_regex='^journeys/evidence/trusted-pool-external-runtime-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-trusted-pool-external-runtime-journey-result.py payload)
    payload_prefix=trusted-pool-external-runtime-journey-result
    artifact_prefix=signed-trusted-pool-external-runtime-journey-promotion
    artifact_mode=sha-slug
    export_dir_name=signed-trusted-pool-external-runtime-journey-promotion
    schema=macprovider.signed-trusted-pool-external-runtime-journey-promotion.v1
    copy_conformance=yes
    ;;
  trusted-pool-creator-mvp)
    mode=evidence
    confirm=evidence
    journey_id=JOURNEY-TRUSTED-POOL-CREATOR-MVP
    evidence_regex='^journeys/evidence/trusted-pool-creator-mvp-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-trusted-pool-creator-mvp-journey-result.py)
    payload_prefix=trusted-pool-creator-mvp-journey-result
    artifact_prefix=signed-trusted-pool-creator-mvp-journey-evidence
    artifact_mode=short
    export_dir_name=signed-trusted-pool-creator-mvp-journey-evidence
    schema=macprovider.signed-trusted-pool-creator-mvp-journey-evidence.v1
    copy_conformance=no
    ;;
  trusted-pool-layer2)
    mode=evidence
    confirm=evidence
    journey_id=JOURNEY-TRUSTED-POOL-LAYER2-MVP
    evidence_regex='^journeys/evidence/trusted-pool-layer2-[A-Za-z0-9_.:-]+\.redacted\.json$'
    builder=(python3 scripts/build-trusted-pool-layer2-journey-result.py)
    payload_prefix=trusted-pool-layer2-journey-result
    artifact_prefix=signed-trusted-pool-layer2-journey-evidence
    artifact_mode=sha-slug
    export_dir_name=signed-trusted-pool-layer2-journey-evidence
    schema=macprovider.signed-trusted-pool-layer2-journey-evidence.v1
    copy_conformance=no
    ;;
  *)
    echo "::error::unknown signed journey" >&2
    exit 1
    ;;
esac
[[ "${EXPECTED_MODE:-}" == "$mode" ]] || {
  echo "::error::journey is not valid for this job" >&2
  exit 1
}
export journey_id schema copy_conformance confirm mode
