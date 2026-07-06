# Connexa ACME Windows-role hook pack

Deploys a renewed certificate to common Windows Server roles: the machine
certificate store, IIS, the RDP listener and the WinRM HTTPS listener.

> **Templates — test in each environment before production.** These hooks run as
> `SYSTEM` and touch live services. They cover the common cases; verify against the
> specific server before relying on them unattended.

## Requirements

- The ACME service and agent must use **PFX** output (`OutputFormat = pfx`), because
  `10-import-to-store` imports the PFX into `LocalMachine\My`.
- Windows PowerShell 5.1 or PowerShell 7. IIS hook needs the Web-Scripting-Tools
  (`WebAdministration` module); RDP/WinRM need the respective roles enabled.

## Install

Copy this whole folder (including `_lib`) to:

```text
C:\ProgramData\Connexa\ACMEAgent\hooks\windows-roles\
```

Copy `hooks.example.json` to `hooks.json` and configure it. Point the agent at the
folder:

```json
{
  "OutputFormat": "pfx",
  "PfxPassword": "local-pfx-password",
  "HooksPath": "C:\\ProgramData\\Connexa\\ACMEAgent\\hooks\\windows-roles"
}
```

`hooks.json` holds the same PFX password (used to import the certificate) plus a
section per role. Set `Enabled` to turn each consumer on or off:

```json
{
  "PfxPassword": "local-pfx-password",
  "Iis":   { "Enabled": true,  "SiteName": "Default Web Site", "Port": 443, "HostHeader": "" },
  "Rdp":   { "Enabled": false },
  "WinRm": { "Enabled": false, "HostName": "" }
}
```

## Execution order

Hooks run in filename order, so the import always runs first:

| Hook | Role |
|------|------|
| `10-import-to-store.ps1` | Import PFX into `LocalMachine\My`, record thumbprint, prune superseded certs |
| `20-iis-binding.ps1` | Point an IIS https binding at the new thumbprint |
| `30-rdp-listener.ps1` | Set the RDP-Tcp listener certificate |
| `40-winrm-https.ps1` | Create/update the WinRM HTTPS listener |
| `45-ldaps-dc.ps1` | Import into the AD DS store (`NTDS\Personal`) + non-disruptive LDAPS reload |
| `50-exchange.ps1` | `Enable-ExchangeCertificate` for IIS/SMTP/IMAP/POP (Exchange server, PS 5.1) |
| `55-java-keystore.ps1` | Import into a Java keystore (JKS/PKCS12) via keytool for Tomcat/Java apps |
| `60-rds.ps1` | `Set-RDCertificate` for RD Gateway / Web / Broker (needs the PFX) |
| `70-sql-server.ps1` | Set SQL Server `SuperSocketNetLib\Certificate`, grant key ACL, restart |
| `80-adfs.ps1` | `Set-AdfsSslCertificate` (+ service-communications), restart AD FS |
| `85-rras-sstp.ps1` | `Set-RemoteAccess -SslCertificate` for SSTP VPN, restart RemoteAccess |
| `90-copy-and-run.ps1` | Generic: copy cert files to a path, restart a service, run a command |
| `95-notify.ps1` | Post a deploy notification to a Teams/webhook URL (on success) |

Each hook is off by default and gated by its section in `hooks.json` — enable only the
roles present on the server. Consumer hooks never need the PFX password: `10-import-to-store`
writes the imported thumbprint to `current\deployed-thumbprint.txt`, and the others read it
(falling back to a store lookup by domain). `60-rds` is the exception — `Set-RDCertificate`
takes a PFX, so it uses `PfxPassword` from `hooks.json`.

> **Templates — test each on a representative server before unattended use.** `70-sql-server`
> in particular touches the registry, private-key ACLs and restarts the SQL service.

## Extending

Add more consumers as `50-…`, `60-…` etc. Dot-source the shared helpers with
`. (Join-Path $PSScriptRoot "_lib\Common.ps1")` and call `Get-DeployedThumbprint`.
`_lib` is a subfolder, so the agent's hook scanner does not execute it.

## Exit codes

- `0` OK or intentionally skipped (role disabled)
- `1` non-fatal skip (e.g. wrong output format)
- `3` fatal
