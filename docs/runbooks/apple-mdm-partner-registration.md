# Partner instructions — Apple Business Manager + MDM push identity

**Audience:** partner handling Apple org / certificate registration (no eng deploy required)  
**Why:** macprovider is building its own MDM so enrolled Macs can receive Apple Managed Device Attestation (MDA). Without an MDM APNs push certificate, enrolled devices will not wake for MDM commands.  
**Engineering status:** `POST /v1/enroll` and `malibu-cli enroll` already ship on `main`. Your work unblocks live enroll → check-in → push.

---

## What you are delivering

Hand back these artifacts to eng (1Password / secure share — not Slack/email plaintext):

| # | Artifact | Format | Used for |
|---|----------|--------|----------|
| 1 | **MDM APNs push certificate** | `.pem` or `.p12` + password | MicroMDM on Pearl |
| 2 | **Matching private key** | PEM or inside `.p12` | Same |
| 3 | **Push topic** | string like `com.apple.mgmt.External.<uuid>` | `tier2.mdm.push_topic` in coordinator config |
| 4 | **Apple ID used at identity.apple.com** | account email + how 2FA is held | **Only this Apple ID can renew** the cert yearly |
| 5 | **Team ID** | 10-char ID (we already sign as `YF7XNRJUG4` — Superposition Technologies) | Confirm same org; SE keychain access group |
| 6 | **ABM org name + MDM server nickname** (if created) | short note | Ops inventory |

Optional but useful:

- Screenshot of identity.apple.com certificate list (topic + expiry visible)
- Confirmation that ABM enrollment is complete (or blocked — see pitfalls)

---

## Timeline expectation

Apple-side work is often **days, not hours** (org verification, D-U-N-S, email confirmations). Start early; eng can keep wiring nginx/MicroMDM while you wait.

Renewal: MDM APNs certs expire **yearly**. Losing the Apple ID or creating a *new* cert (instead of renewing) **breaks all enrolled devices** — push topic must stay the same.

---

## Part A — Apple Business Manager (org)

**Portal:** https://business.apple.com/

### Goal

Establish the company as an Apple Business Manager organization so we can operate as a legitimate MDM customer org (and later use Automated Device Enrollment if we want).

### Steps

1. Open https://business.apple.com/ and start enrollment for **Superposition Technologies** (or the legal entity that owns Team ID `YF7XNRJUG4`).
2. Use a **company-owned Apple ID** (not a personal iCloud used for App Store shopping). Prefer something like `apple-admin@…` that multiple trusted ops can recover.
3. Complete Apple’s org verification (legal name, D-U-N-S if requested, domain/email verification).
4. Enable **two-factor authentication** on that Apple ID. Store recovery keys in the shared vault.
5. After approval, note:
   - Organization name as shown in ABM
   - Admin Apple ID(s)
   - Whether you can see **Settings → Device Management Settings** (MDM server list) — leave empty for now; eng will add MicroMDM later if we use ADE

### You do **not** need yet

- Uploading device serials into ABM (our first enroll path is user-installed `.mobileconfig`, not ADE)
- Linking ABM to MicroMDM (eng does that after the server exists)

### Done when

ABM shows the org as active / approved, and you can sign in as admin.

---

## Part B — MDM APNs push certificate (the critical piece)

**Portal:** https://identity.apple.com/pushcert/

This certificate is **not** the same as:

- App Store / Developer push certs for Malibu
- Signing / notarization certs for `malibu-cli`
- TLS certs for `coordinator.malibu.tech`

It is specifically an **MDM** APNs certificate. Topic always looks like `com.apple.mgmt.…`.

### Recommended path for us (self-hosted MicroMDM)

We need a CSR that Apple will accept as an MDM push request. Practical options:

| Method | When to use | Notes |
|--------|-------------|-------|
| **C — mdmcert.download** (usual for open-source MDM) | Default if we are not Apple Enterprise MDM Vendor | Free; org attestation required. MicroMDM `mdmctl` can drive CSR encrypt/decrypt. |
| **A — Apple Developer Enterprise + MDM Vendor CSR** | If we already have Enterprise Program + Vendor cert | Most “Apple-native”; heavier process. |
| ~~B — Profile Manager / Server.app export~~ | Avoid for production | Fine for lab only; renewal pain. |

**Coordinate with eng before uploading to Apple:** eng (or you, with eng on a call) should generate the CSR / signed request with MicroMDM tooling so the private key never leaves a controlled machine.

High-level flow (Method C — typical):

1. Eng generates an encrypted CSR via MicroMDM / mdmcert.download instructions.
2. You create/sign in at https://identity.apple.com/pushcert/ with the **org Apple ID** from Part A (or a dedicated MDM-admin Apple ID — document which).
3. Upload the CSR Apple expects (decrypted/vendor-signed request — eng will give you the exact file).
4. Download the signed **MDM push certificate** from Apple.
5. Eng combines cert + private key into the format MicroMDM wants (usually PEM or PKCS#12).
6. Extract / record the **push topic** (from cert Subject / MicroMDM logs / `openssl` — eng can pull this if you only have the `.pem`).

Useful references (read, don’t invent a parallel process):

- MicroMDM certificates explainer: https://micromdm.io/blog/certificates/
- MicroMDM quickstart: https://github.com/micromdm/micromdm/blob/main/docs/user-guide/quickstart.md
- Push cert portal: https://identity.apple.com/pushcert/

### Gotchas (read these)

1. **Renew, don’t replace.** Next year: renew the *same* certificate entry. A brand-new cert → new topic → every enrolled Mac stops receiving pushes.
2. **One Apple ID owns renewals.** Write down which identity.apple.com account created the cert. Put it in the vault with 2FA.
3. **Not interchangeable with app push.** Don’t reuse Malibu’s APNs key.
4. **Keep the private key.** Without it, the downloaded Apple cert is useless.
5. **Expiry calendar.** Set a reminder ~30 days before expiry.

### Done when

You can securely deliver items 1–4 in the table at the top, and eng can set:

```yaml
tier2:
  mdm:
    push_topic: "com.apple.mgmt.External.<from-cert>"
    # plus enrollment_base_url / mdm_server_url / scep_url once MicroMDM is up
```

---

## Part C — Confirm Apple Developer Team ID (quick)

We already ship / notarize under:

- **Team:** Superposition Technologies Pte. Ltd.
- **Team ID:** `YF7XNRJUG4`

Please confirm in https://developer.apple.com/account → Membership that this is still the production team, and that the ABM org is the same legal entity (or explicitly note if ABM is under a different entity — that creates ops friction).

Also note any **Apple Developer Enterprise Program** status (yes/no). Needed only if we choose Method A for the push cert.

---

## What eng will do after you hand off (not your job)

- Install push cert + key on Pearl MicroMDM — see [`docs/runbooks/pearl-micromdm-install.md`](./pearl-micromdm-install.md)
- Set `tier2.mdm.push_topic` (and enroll URLs) on the coordinator
- Wire nginx `/v1/enroll` + MDM routes
- Run `malibu-cli enroll` on a test Mac and confirm check-in + push wake
- Later: DeviceInformation / MDA (Phase 3)

---

## Checklist (copy into a message when done)

```
[ ] ABM org approved — name: _______________
[ ] Admin Apple ID (ABM): _______________
[ ] identity.apple.com Apple ID (push cert): _______________   ← must be renewable
[ ] MDM APNs cert file shared securely
[ ] Private key shared securely (or .p12 + password)
[ ] Push topic: com.apple.mgmt._______________
[ ] Cert expiry date: _______________
[ ] Team ID confirmed: YF7XNRJUG4 (yes/no)
[ ] Enterprise Program / MDM Vendor cert: yes / no / n/a
[ ] Vault location for renewals: _______________
```

---

## Contacts / ownership

| Role | Owns |
|------|------|
| Partner (you) | ABM enrollment, identity.apple.com account, CSR upload, cert download, vault storage |
| Eng | CSR generation, MicroMDM install, coordinator `tier2.mdm.*`, enroll E2E test |
| Founder / ops | Legal entity confirmation if Apple asks for D-U-N-S / domain proof |

If Apple support asks “what MDM product?”: **self-hosted MicroMDM for macprovider / StreamVC provider Macs** — organization-owned devices for hardware attestation, read-only MDM rights (device info / security queries / profile inspection). Not a fleet-management product launch.
