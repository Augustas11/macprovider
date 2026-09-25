## Lane: ARCHITECTURE

Check:
- Consistency with the signed updater (`ops/pearl-updater/catalog-canary-proof.py`, `macprovider-pearl-update`) and the catalog-content lane, which already include the rate card.
- SPEC-023 R014 deploy-classification semantics.
- The rollout plan: Pearl runtime tag, then the deploy, with the canary Mac on signed CLI v1.8.195.
