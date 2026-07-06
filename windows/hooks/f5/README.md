# Connexa ACME F5 BIG-IP hook

Deploys a renewed certificate to F5 BIG-IP systems via iControl REST: uploads the cert
and key, then installs both under a fixed name.

> **Template — test against your BIG-IP before production.**

## Requirements

- Agent **OutputFormat = pem**.
- A BIG-IP admin (or a user with the right role) reachable on the management address.

## Install

Copy this folder to `C:\ProgramData\Connexa\ACMEAgent\hooks\f5\`, copy `f5.example.xml`
to `f5.xml`, and set the BIG-IP host(s), credentials and `CertName`. Point the agent at the
folder with `"OutputFormat": "pem"`.

## What it does

1. Uploads `cert.crt` and `cert.key` via `/mgmt/shared/file-transfer/uploads/`.
2. Installs the certificate (`/mgmt/tm/sys/crypto/cert`) and key (`/mgmt/tm/sys/crypto/key`)
   under `<CertName>.crt` / `<CertName>.key`.

Installing under an existing name updates it in place, so a client-ssl profile that already
references that cert/key uses the new material. Creating and binding profiles is left to your
configuration. For very large chains the single-request upload may need chunking.

## Exit codes

- `0` success · `2` retry (no PEM yet) · `3` fatal / one or more devices failed
