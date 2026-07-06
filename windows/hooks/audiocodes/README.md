# Connexa ACME AudioCodes hook

Deploys a renewed certificate to AudioCodes devices (Mediant SBC / gateway) via the
device REST API — uploads the PEM certificate and private key into a TLS context.

> **Template — verify the REST API against your firmware before production.**
> AudioCodes REST paths and verbs differ between firmware versions. The defaults target
> recent Mediant firmware; override `CertificateApiPath`, `PrivateKeyApiPath` and
> `UploadMethod` in `audiocodes.xml` if your device differs. Confirm against the
> "AudioCodes REST API" reference for your version.

## Requirements

- Agent **OutputFormat = pem** (uploads `cert.crt` and `cert.key`).
- A device admin account and REST/Web access reachable over HTTPS.
- The TLS context (`TlsContextId`) that your SIP interfaces use.

## Install

Copy this folder to:

```text
C:\ProgramData\Connexa\ACMEAgent\hooks\audiocodes\
```

Copy `audiocodes.example.xml` to `audiocodes.xml` and set device host(s), credentials and
the TLS context index. Point the agent at the folder with PEM output:

```json
{
  "OutputFormat": "pem",
  "HooksPath": "C:\\ProgramData\\Connexa\\ACMEAgent\\hooks\\audiocodes"
}
```

## What it does

1. Uploads the certificate to `CertificateApiPath` and the private key to `PrivateKeyApiPath`
   (with `{id}` replaced by `TlsContextId`).
2. Optionally saves the configuration (`SaveConfig` / `SaveConfigApiPath`).

Some deployments also require a device reset for listeners to pick up a new certificate —
check your firmware and add that step if needed.

## Exit codes

- `0` success
- `2` retry next run (no PEM present yet)
- `3` fatal — config error or one or more devices failed
