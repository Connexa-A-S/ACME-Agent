# Connexa ACME Fetch Agent for Windows

The Windows agent is intentionally simple. It does not know anything about IIS,
Exchange, RDS, Tomcat, Nginx, or other products. It only synchronizes a
certificate from Connexa ACME Platform to a local folder and then runs optional
hook scripts when the certificate changes.

## What it does

1. Calls `GET /agent/info` using the service API key.
2. Compares the remote fingerprint with `state.json`.
3. Downloads the certificate only when it has changed, or when local files are missing.
4. Stores the certificate in a local immutable `versions/` folder.
5. Updates `current/` with the latest certificate.
6. Runs hook scripts in alphabetical order.

## Default location

```text
C:\ProgramData\Connexa\ACMEAgent\
  CNXA-AcmeFetch.ps1
  config.json
  state.json
  certs\
  hooks\
  logs\
```

## Install

Run PowerShell as Administrator:

```powershell
.\install-agent.ps1 `
  -ApiBaseUrl "https://acme.cnxa.cloud/api" `
  -ServiceApiKey "cnxa_svc_REPLACE_ME" `
  -OutputFormat "pfx" `
  -PfxPassword "local-pfx-password" `
  -StoreSecretsProtected
```

The installer creates a Scheduled Task named:

```text
Connexa ACME Agent
```

It runs as `SYSTEM` every 12 hours by default.

## Security

- Run the installer from an elevated PowerShell (it verifies this and refuses otherwise).
- The installer locks the install tree (`C:\ProgramData\Connexa\ACMEAgent`) down to
  `SYSTEM` + `Administrators` only, so non-admin users cannot read secrets or drop in
  hooks that would run as `SYSTEM`.
- Use `-StoreSecretsProtected` to store the API key / PFX password with machine-scoped
  DPAPI instead of plaintext in `config.json`. It is decryptable by the `SYSTEM` task on
  the same machine, regardless of which admin account ran the installer.

## Manual test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\ProgramData\Connexa\ACMEAgent\CNXA-AcmeFetch.ps1" `
  -ConfigPath "C:\ProgramData\Connexa\ACMEAgent\config.json" `
  -Force
```

## Hook pipeline

Hooks are `.ps1` files in the configured `HooksPath` and are executed in
alphabetical order.

Example:

```text
hooks\
  10-import-certificate.ps1
  20-update-iis-binding.ps1
  30-restart-service.ps1
```

The agent also supports a static `Hooks` array in `config.json`, but `HooksPath`
is recommended for MSP deployment because hooks can be dropped into the folder
without changing config.

## Included hook packs

Each pack is a self-contained folder under `hooks/`. Point `HooksPath` at the one you
need, copy its `*.example.*` config to the real name, and configure it.

| Pack | Target | Output format |
|------|--------|---------------|
| `hooks/windows-roles/` | Cert store + IIS, RDP, WinRM, LDAPS DC, Exchange, RDS, Java keystore, SQL Server, AD FS, RRAS/SSTP, generic copy+run, notify | `pfx` |
| `hooks/fortigate/` | FortiGate (admin GUI + SSL VPN, safe replace) | `pfx` |
| `hooks/netscaler/` | Citrix NetScaler / ADC (NITRO REST) | `pem` |
| `hooks/audiocodes/` | AudioCodes Mediant SBC / gateway (REST) | `pem` |
| `hooks/paloalto/` | Palo Alto (PAN-OS XML API) | `pem` |
| `hooks/kemp/` | Kemp LoadMaster (REST `addcert`) | `pem` |
| `hooks/f5/` | F5 BIG-IP (iControl REST) | `pem` |
| `hooks/synology/` | Synology DSM (Web API) | `pem` |
| `hooks/vcenter/` | VMware vCenter Server (Machine SSL, REST) | `pem` |

Within `windows-roles/`, each role hook is off by default and enabled per section in
`hooks.json`, so one pack covers a whole Windows server.

All packs are templates — test them in each environment before running unattended. See each
pack's `README.md`.

## Hook parameters

Every hook receives:

```powershell
-CertificatePath
-CurrentPath
-VersionPath
-MetadataPath
-Format
-ServiceId
-ServiceName
-CustomerNumber
-Domain
-Fingerprint
-PreviousFingerprint
```

## Hook exit codes

```text
0 = OK
1 = Warning, continue pipeline
2 = Retry requested, agent exits with failure and tries again on next scheduled run
3+ = Fatal failure
```

Each hook gets its own log file:

```text
logs\hook-10-import-certificate-20260626.log
```

## Output formats

### PFX

```text
certs\<service-name>\current\certificate.pfx
```

### PEM

```text
certs\<service-name>\current\cert.crt
certs\<service-name>\current\cert.key
certs\<service-name>\current\issuer.crt
```

## Notes

The agent uses `state.json` for fingerprint tracking. If `current/` is missing
or incomplete, the agent repairs it from `versions/`. If repair fails, it
redownloads the certificate.

---

## About

This agent is designed to work with the Connexa A/S ACME platform. Interested in managed
certificate automation for your servers and appliances?

**Connexa A/S** · [salg@cnxa.dk](mailto:salg@cnxa.dk) · +45 44 225 226
