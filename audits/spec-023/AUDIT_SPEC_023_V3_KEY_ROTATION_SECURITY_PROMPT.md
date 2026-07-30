# AUDIT: SPEC-023 v3 keypair rotation + catalog re-sign — SECURITY lens

## Change under audit

Branch: `fix/spec023-catalog-v3-resign` on top of `origin/main` (v1.7.9 + install.sh AMFI retry).

Read the DIFF with:

```
git -C /Users/augstar/macprovider-catalog-v3 diff origin/main
```

See `specs/AUDIT_SPEC_023_V3_KEY_ROTATION_CODE_PROMPT.md` for the file
list and CODE-lane context.

## What the change does — security-relevant summary

- Generates a fresh Curve25519 (Ed25519) keypair.
- Commits **only** the public key at
  `phase3-binary/dist/static/keys/autotune-static-v3.public.base64` and
  bakes it into `AutotuneRecommend.swift` as
  `autotune_static_json_ed25519_v3`. The v3 keyID
  `streamvc-autotune-static-v3` is checked at runtime in
  `sidecarIsValid`.
- The **private** key is stored off-repo, default path
  `~/.config/macprovider/keys/autotune-static-v3.private.base64`
  (`chmod 0600`), overridable via env
  `AUTOTUNE_STATIC_V3_PRIVATE_KEY_PATH`.
- `scripts/resign-autotune-static.sh` reads the private key from that
  path, refuses to run if the file permissions are wider than 0600, and
  signs each JSON exactly as it lives on disk.
- The v3-signed feed will replace the v2 feed at
  `coordinator.streamvc.live/static/*` after this PR merges + is
  deployed.

## SECURITY lens — what to audit

Focus strictly on security properties: key handling, signature model,
supply-chain surface, argument injection, DoS. Other lenses cover
correctness and architecture.

1. **Private-key exposure.** Confirm from the git diff that no file
   named `*.private.base64` or containing the raw private-key material
   is added. The only committed files in the `keys/` directory should
   be `autotune-static-v3.public.base64` and `README.md`.
2. **Private-key permission enforcement.** The resign script reads
   `stat` (macOS and Linux forms) and refuses to run if the key file
   is mode wider than `0600` / `0400`. Argue whether this is a
   meaningful guard or a paper tiger:
   - Could an operator disable it (yes — they own the script) — but is
     the guard useful as a tripwire against inadvertent `chmod 0644`
     mistakes?
   - Are there race conditions where the file is briefly world-readable
     between `install` and `chmod`? Not applicable here (the operator
     places the file themselves).
3. **Private-key material handling in the script.** The script:
   - `tr -d '[:space:]' < "$KEY_PATH"` — reads key into `private_b64`
     shell variable.
   - Passes to `swift -e` via `env PRIV_B64=... swift -e ...`.
   - `swift -e`'s `ProcessInfo.processInfo.environment["PRIV_B64"]`
     reads it back.

   Argue:
   - Is the private key visible in `ps auxeE` output (env vars) during
     script execution? On macOS, other users cannot read your env by
     default, but the same-user attack surface is real.
   - Is the private key ever written to any tempfile? Grep the script.
   - Is the private key ever echoed / logged / included in an error
     message? Grep for `printf.*private_b64` etc.
4. **v3 public-key baking supply-chain surface.** The new v3 pubkey
   `1qzXegR2OEu0TaQNWjUkN4PamQAHdpvBcYW/pJ4h6oE=` is baked in
   `AutotuneRecommend.swift` and committed to git. Argue whether that
   is the right place (yes: the client has to have SOME baked trust
   root; a runtime-fetched pubkey would be circular). Confirm the
   base64 decodes to a valid 32-byte Curve25519 public point (the
   existing `testPinnedPublicKeyIsValidCurve25519SigningKey` test
   asserts this — verify it's been updated to v3 and still passes).
5. **Rotation replay.** With v2 replaced by v3 at
   `coordinator.streamvc.live/static/*`, argue whether an attacker
   who kept a copy of a valid v2-signed catalog could serve it back
   via TLS MITM and cause v1.7.9- clients (still trusting v2) to
   accept a stale catalog:
   - Yes in principle: v1.7.9- clients still trust v2.
   - But the stale catalog's `generated_at` is fixed at 2026-07-02;
     the client's freshness gate rejects catalogs older than 30 days
     wall-clock, so this attack has a bounded lifetime.
   - Once the operator upgrades to v1.7.10, the v2 sig is rejected
     by `sidecarIsValid` regardless.

   Is the 30-day freshness cliff good enough, or should v0.2 also
   introduce a revocation mechanism? Argue.
6. **Attacker with the v3 private key: what can they do?** Suppose
   the operator's laptop is compromised and the v3 private key leaks.
   Enumerate the concrete attacks:
   - Sign a malicious catalog. But delivery still requires TLS MITM
     against `coordinator.streamvc.live` OR compromising the Pearl
     VPS filesystem (both harder than key theft).
   - The attacker cannot recommend a novel model — `model_sha256`
     is verified against the HuggingFace-downloaded artifact bytes.
     Only a slower existing HF model can be recommended.
   - The attacker cannot manipulate provider earnings — rate card
     is a separate TLS-signed coordinator endpoint.
   - Providers install v1.7.10 that bakes v3 pubkey. If the operator
     detects the leak and rotates to v4 in v1.7.11, existing v1.7.10
     providers keep trusting v3 sigs until they upgrade to v1.7.11.

   Argue whether the revocation surface is acceptable given the
   deployment topology.
7. **Argument-injection surface in the resign script.** The script
   invokes `swift -e "..."` with a small Swift program that reads env
   vars. Confirm no user input is directly interpolated into the
   Swift program body.
8. **`chmod` guard on the private key file — attacker-controlled
   permissions.** Could an attacker with local shell access `chmod
   0600` a file they don't own and then substitute a malicious key?
   No — they'd still need write access to the file itself. Confirm.
9. **Old v2 private key.** Argue whether the v2 private key (which
   we don't have to hand — it was held by whoever signed the 2026-07-02
   feed) should be actively revoked or just abandoned. Given v2 is now
   only trusted by v1.7.9- clients and those will roll to v1.7.10 over
   time, revocation is largely a wall-clock question.
10. **Deployment posture.** The resign script writes new `.sig` files
    into the repo; `phase4-coordinator/dist/deploy-pearl-vps.sh`
    already ships those files to Pearl. Argue whether the deployment
    step needs any additional signature-verification gate (e.g.
    verify locally before deploying that the sig verifies against
    the baked pubkey).

## Bar

CRITICAL / HIGH / MEDIUM findings must be fixed. LOW / INFO may ship
with PR-body documentation. Return findings as a structured list; no
speculative findings without a concrete attack scenario.
