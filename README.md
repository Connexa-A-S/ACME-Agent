# CNXA ACME Agent

Lightweight fetch agent and certificate-deployment hooks for the CNXA ACME Platform.

The agent is a client: it authenticates to the platform with a service API key,
downloads the assigned certificate when it changes, keeps a local versioned copy, and
runs deployment hooks. It contains no platform internals or secrets — real credentials
live in local config files that are never committed.

## Layout

```text
windows/
  CNXA-AcmeFetch.ps1     Fetch agent (scheduled task)
  install-agent.ps1      Installer
  README.md              Agent documentation
  hooks/
    windows-roles/       Cert store + IIS, RDP, WinRM
    fortigate/           FortiGate (admin GUI + SSL VPN)
    netscaler/           Citrix NetScaler / ADC (NITRO)
    audiocodes/          AudioCodes Mediant (REST)
```

Start with [windows/README.md](windows/README.md), then the per-pack READMEs under
`windows/hooks/`.

## Platform API contract

The agent depends only on the platform's `GET /agent/info` response and the download
endpoints it points to:

| Field | Purpose |
|-------|---------|
| `service_id`, `service_name`, `customer_number`, `domain`, `domains` | Identity / metadata |
| `status` | Only `active` triggers a fetch |
| `not_after` | Certificate expiry |
| `fingerprint` | Change detection (SHA-256 of the certificate) |
| `download_pem_url`, `download_pfx_url` | Where to fetch the certificate |

Authentication is a service API key sent as `X-API-Key`.

## Requirements

Windows PowerShell 5.1 or PowerShell 7. See [windows/README.md](windows/README.md).
