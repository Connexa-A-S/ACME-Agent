# Connexa ACME NetScaler / ADC hook

Deploys a renewed certificate to Citrix NetScaler / ADC appliances via the NITRO REST API.

> **Template — test against your appliance before production.**

## Requirements

- Agent **OutputFormat = pem** (the hook uploads `cert.crt` and `cert.key`).
- A NITRO-capable account (e.g. `nsroot` or a scoped admin) reachable on the NSIP/management IP.
- The `sslcertkey` object should already exist and be bound to the relevant vservers, so
  renewals update it in place. First-time creation is supported, but binding to vservers
  is left to you (logged as a warning).

## Install

Copy this folder to:

```text
C:\ProgramData\Connexa\ACMEAgent\hooks\netscaler\
```

Copy `netscaler.example.xml` to `netscaler.xml` and set the appliance host(s), credentials
and `CertKeyName`. Point the agent at the folder with PEM output:

```json
{
  "OutputFormat": "pem",
  "HooksPath": "C:\\ProgramData\\Connexa\\ACMEAgent\\hooks\\netscaler"
}
```

## What it does

1. Uploads `<CertKeyName>.cer` and `<CertKeyName>.key` to `FileLocation` (default `/nsconfig/ssl`),
   replacing any existing files with those names.
2. If the `sslcertkey` exists it is updated in place (`action=update`, `nodomaincheck`), which
   hot-swaps the certificate on all vservers that reference it. Otherwise it is created.
3. Optionally saves the running config (`SaveConfig`).

## Exit codes

- `0` success
- `2` retry next run (no PEM present yet)
- `3` fatal — config error or one or more appliances failed
