# Connexa ACME Kemp LoadMaster hook

Uploads a renewed certificate to Kemp LoadMaster appliances via the REST API
(`access/addcert`) as a combined PEM (key + cert + chain).

> **Template — test against your LoadMaster before production.**

## Requirements

- Agent **OutputFormat = pem**.
- A LoadMaster user with API access (e.g. `bal`) — enable API/RESTful access on the LM.

## Install

Copy this folder to `C:\ProgramData\Connexa\ACMEAgent\hooks\kemp\`, copy
`kemp.example.xml` to `kemp.xml`, and set the LoadMaster host(s), credentials and `CertName`.
Point the agent at the folder with `"OutputFormat": "pem"`.

## What it does

POSTs the combined PEM to `https://<lm>/access/addcert?cert=<CertName>&replace=1`. With
`replace=1` an existing certificate of that name is updated in place, so Virtual Services
that reference it pick up the new certificate. Binding the certificate to a Virtual Service
is left to your configuration.

## Exit codes

- `0` success · `2` retry (no PEM yet) · `3` fatal / one or more LoadMasters failed
