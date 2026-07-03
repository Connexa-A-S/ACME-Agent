# Connexa ACME FortiGate Hook Pack

This hook pack deploys a downloaded PFX certificate from the Connexa ACME Windows fetch agent to one or more FortiGates.

## Requirements

The ACME service must be created with RSA for FortiGate compatibility:

```json
{
  "certificate_type": "wildcard",
  "deployment_type": "agent",
  "key_type": "rsa"
}
```

The Windows agent config must use PFX:

```json
{
  "Format": "pfx",
  "PfxPassword": "same-password-as-fortigate.xml",
  "HooksPath": "C:\\ProgramData\\Connexa\\ACMEAgent\\hooks\\fortigate"
}
```

## Install

Copy these files to:

```text
C:\ProgramData\Connexa\ACMEAgent\hooks\fortigate\
```

Then copy:

```text
fortigate.example.xml
```

to:

```text
fortigate.xml
```

and configure FortiGate host(s), API token(s), VDOM, certificate name and
`FallbackCert` (an existing local FortiGate certificate — default `Fortinet_Factory`).

## Safe replacement

When the target certificate name already exists and is in use, the uploader parks the
Admin GUI and SSL-VPN references on `FallbackCert`, deletes the old certificate, imports
the renewed one under the final name, and moves the references back. Idempotent API calls
are retried, because FortiGate can briefly reset its HTTPS listener after a certificate or
admin-server-cert change.

> For richer safe-replace (incl. user auth and SAML references) prefer the platform's
> direct FortiGate deployment (`POST /services/{id}/deploy/fortigate`). This hook covers
> the Admin GUI and SSL-VPN references only.

## Requirements

Works on both Windows PowerShell 5.1 and PowerShell 7. Authentication uses a Bearer token
header, and TLS 1.2 is enabled explicitly on 5.1.

## Hook order

`20-UploadFortigate.ps1` is executed by the agent when a new certificate version is downloaded.

## Exit codes

- `0` success
- `2` retry next agent run (no PFX present yet)
- `3` fatal — configuration error or a failed deployment to one or more FortiGates

A failed upload/reference update is reported as `3` (fatal), so the agent surfaces it
instead of treating it as a warning.
