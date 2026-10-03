# SPEC-048 R015 fused-baseline preregistration

This directory preregisters the fresh formal R015 run for the Qwen3.6 A3B
native-MTP tuple after the ordinary path moved to the exact fused MLX fork
revision `ca29e9544777068a0b53aad87310ff1cfaf3fd1d`.

The frozen byte-exact `policy.json` has SHA-256
`de99e85c4b68dac589ea2b8fa33f1d8ee8a7371c254e233e3d3081e01e89b60b`.
It binds the lab binary to provider commit
`bcf7acccf8cac842eadb5305bc5b88390c5846f8`, built on the designated
`Mac15,14` Studio with `-DMACPROVIDER_LAB_HARNESS` and used only in an
isolated, no-join hardware window.

Status: preregistered; no measurement result is claimed yet. Raw JSONL and
contamination logs remain on the lab host. Analysis and redacted evidence will
be added without modifying this policy.
