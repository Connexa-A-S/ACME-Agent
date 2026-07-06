# CNXA ACME Agent

Lightweight fetch agent and certificate-deployment hooks, built to work with the
**Connexa A/S ACME platform** — Connexa's certificate lifecycle service for issuing,
renewing and distributing certificates.

The agent is a client: it authenticates to the platform with a service API key,
downloads the assigned certificate when it changes, keeps a local versioned copy, and
runs deployment hooks. It contains no platform internals or secrets — real credentials
live in local config files that are never committed.

## Layout

```text
windows/                 Windows agent (scheduled task, PowerShell)
  CNXA-AcmeFetch.ps1     Fetch agent
  install-agent.ps1      Installer
  hooks/                 windows-roles, fortigate, netscaler, audiocodes,
                         paloalto, kemp, f5, synology
unix/                    Unix agent (systemd timer, bash)
  cnxa-acme-fetch.sh     Fetch agent
  install-agent.sh       Installer
  hooks.d/               Hooks (env-var context; nginx example included)
```

- Windows: start with [windows/README.md](windows/README.md), then the per-pack READMEs.
- Unix/Linux: see [unix/README.md](unix/README.md).

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

- Windows: Windows PowerShell 5.1 or PowerShell 7. See [windows/README.md](windows/README.md).
- Unix: `bash`, `curl`, `sed`, `grep` (+ `unzip` for PEM). See [unix/README.md](unix/README.md).

## License

MIT — see [LICENSE](LICENSE).

---

## About

This agent is designed to work with the Connexa A/S ACME platform. Interested in managed
certificate automation for your servers and appliances?

**Connexa A/S** · [salg@cnxa.dk](mailto:salg@cnxa.dk) · +45 44 225 226
