Read `audits/2026-09-24/AUDIT_1690_M8_COMMON.md` first.

**Lane: trust and money-path security.** Can M8 let an operator earn as `mlxlm_loopback` while serving different weights than the catalog snapshot, beyond the stated administrative-trust boundary? Can it let a GGUF or native session claim `mlxlm_loopback`? Can it widen admission for any non-pool route?

Also check whether the `mlxlm` engine selector can be abused, and whether the Ollama path via `ollama_library_tag` identity is bound correctly.
