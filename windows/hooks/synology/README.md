# Connexa ACME Synology DSM hook

Deploys a renewed certificate to Synology DSM devices via the DSM Web API: logs in, finds
the existing certificate by description, imports the new key/cert/chain (replacing it in
place), then logs out.

> **Template — targets DSM 7; verify the Web API against your device before production.**
> The DSM Web API and its versions differ between releases.

## Requirements

- Agent **OutputFormat = pem** (uploads `cert.key`, `cert.crt`, optional `issuer.crt`).
- A DSM account with permission to manage certificates. If 2FA is enforced, use a dedicated
  service account without 2FA (or the API login will fail).

## Install

Copy this folder to `C:\ProgramData\Connexa\ACMEAgent\hooks\synology\`, copy
`synology.example.xml` to `synology.xml`, and set device host (incl. DSM port, e.g. `:5001`),
credentials and the certificate `Description`. Point the agent at the folder with
`"OutputFormat": "pem"`.

## What it does

1. `SYNO.API.Auth` login (session `Certificate`).
2. `SYNO.Core.Certificate.CRT list` to find the certificate id whose `desc` matches
   `Description` (so renewals replace it in place).
3. `SYNO.Core.Certificate import` with the new key/cert/chain and `as_default` per config.
4. Logout.

## Exit codes

- `0` success · `2` retry (no PEM yet) · `3` fatal / one or more devices failed
