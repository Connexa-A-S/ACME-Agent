# Connexa ACME vCenter hook

Replaces the Machine SSL certificate on VMware vCenter Server (VCSA) appliances via the
supported certificate-management REST API (vCenter 7.0 U2+ / 8.x).

> **Template — test against a non-production vCenter first.** Applying the Machine SSL
> certificate restarts vCenter services, so expect a short management outage per appliance.
> This hook does **not** touch ESXi host certificates — manage those via vCenter's VMCA.

## Requirements

- Agent **OutputFormat = pem** (uses `cert.crt`, `cert.key`, `issuer.crt`).
- The certificate must contain the vCenter FQDN in its SAN and chain to a CA vCenter trusts.
- An SSO administrator account (e.g. `administrator@vsphere.local`).

## Install

Copy this folder to `C:\ProgramData\Connexa\ACMEAgent\hooks\vcenter\`, copy
`vcenter.example.xml` to `vcenter.xml`, and set the vCenter FQDN(s) and credentials.
Point the agent at the folder with `"OutputFormat": "pem"`.

## What it does

1. Creates a REST session (`POST /api/session`).
2. Applies the certificate (`PUT /api/vcenter/certificate-management/vcenter/tls`) with the
   leaf, key and (optionally) the chain as `root_cert`.
3. Closes the session.

## Exit codes

- `0` success · `2` retry (no PEM yet) · `3` fatal / one or more vCenters failed
