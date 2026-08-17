# Pearl MicroMDM install + enroll cutover

**Status:** engineering + ops  
**Depends on:** APNs push cert vaulted (see `docs/runbooks/apple-mdm-partner-registration.md`)  
**Host:** Pearl (`coordinator.malibu.tech` → 159.223.165.194)

## Goal

Run MicroMDM on Pearl (loopback `:8080`), terminate TLS at nginx, serve:

| Path | Upstream |
|------|----------|
| `POST /v1/enroll` | coordinator buyer mux `:8443` |
| `/mdm/*` | MicroMDM `:8080` |
| `/scep` | MicroMDM `:8080` |

Enrollment base URL: `https://coordinator.malibu.tech`

## Install MicroMDM + APNs cert

From a machine with the vaulted push cert:

```bash
bash phase4-coordinator/dist/install-micromdm-pearl.sh \
  --push-cert ~/Secrets/macprovider-mdm-apns/MDM_push_certificate.pem \
  --push-key  ~/Secrets/macprovider-mdm-apns/mdmcert.download.push.key \
  --push-key-password-file ~/Secrets/macprovider-mdm-apns/.push-password \
  --apply-nginx
```

Omit `--apply-nginx` if nginx will land via the normal coordinator Pearl deploy that installs `dist/nginx-coordinator.malibu.tech.conf`.

## Coordinator overlay (`tier2.mdm`)

MDM config is **startup-only**. Add to `/etc/macprovider/coordinator.pearl-overlays.yaml`:

```yaml
tier2:
  mdm:
    enrollment_base_url: "https://coordinator.malibu.tech"
    push_topic: "com.apple.mgmt.External.b3ba8c97-af5f-4feb-8d06-d9fd839c241b"
```

Then restart the coordinator (provider reconnect expected):

```bash
ssh pearl 'systemctl restart macprovider-coordinator'
# confirm mount log:
ssh pearl 'journalctl -u macprovider-coordinator -n 50 --no-pager | grep -i enroll'
```

Push topic must match the issued APNs cert. Renewals: Apple ID `augstar@gmail.com` at identity.apple.com — renew, do not create a new cert.

## Smoke tests

```bash
# Profile generation
curl -fsS -X POST 'https://coordinator.malibu.tech/v1/enroll' \
  -H 'content-type: application/json' \
  -d '{"serial_number":"C02TESTSERIAL"}' \
  -o /tmp/test.mobileconfig
file /tmp/test.mobileconfig
plutil -p /tmp/test.mobileconfig | head

# MicroMDM reachable via nginx (expect non-404)
curl -sI 'https://coordinator.malibu.tech/scep' | head -5
curl -sI 'https://coordinator.malibu.tech/mdm/checkin' | head -5

# Provider CLI (on Apple Silicon Mac)
macprovider-cli enroll status
macprovider-cli enroll run
```

After `enroll run`, confirm device check-in:

```bash
ssh pearl '/opt/micromdm/bin/mdmctl get devices'
```

## Security notes

- MicroMDM HTTP API stays on `127.0.0.1:8080`. Public `/v1/` remains 404 except exact allowlisted routes (including `/v1/enroll`).
- API key: `/etc/micromdm/api-key` (mode 600).
- APNs material: `/etc/micromdm/apns/` (mode 600).
- Do not commit push private keys or API keys to git.
