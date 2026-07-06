# Connexa ACME Palo Alto (PAN-OS) hook

Imports a renewed certificate and private key into one or more Palo Alto firewalls via
the PAN-OS XML API, then commits.

> **Template — test against your firewall before production.**

## Requirements

- Agent **OutputFormat = pem** (uploads `cert.crt` and `cert.key`).
- A PAN-OS **API key** per firewall (generate once via `type=keygen`).
- Works on Windows PowerShell 5.1 and PowerShell 7 (multipart upload is hand-rolled).

## Install

Copy this folder to:

```text
C:\ProgramData\Connexa\ACMEAgent\hooks\paloalto\
```

Copy `paloalto.example.xml` to `paloalto.xml` and set firewall host(s), API key(s),
`CertName` and the on-device key passphrase. Point the agent at the folder with PEM output:

```json
{
  "OutputFormat": "pem",
  "HooksPath": "C:\\ProgramData\\Connexa\\ACMEAgent\\hooks\\paloalto"
}
```

## What it does

1. Imports the certificate (`type=import&category=certificate`).
2. Imports the private key (`type=import&category=private-key`, protected with `KeyPassphrase`).
3. Commits (`type=commit`) — asynchronous.

Referencing the certificate from an SSL/TLS Service Profile (GlobalProtect portal/gateway,
management, decryption, etc.) is left to your configuration and is not changed by this hook.

## Exit codes

- `0` success
- `2` retry next run (no PEM present yet)
- `3` fatal — config error or one or more firewalls failed
