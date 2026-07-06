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

Consumer hooks never need the PFX password: `10-import-to-store` writes the imported
thumbprint to `current\deployed-thumbprint.txt`, and the others read it (falling back
to a store lookup by domain).

## Extending

Add more consumers as `50-…`, `60-…` etc. Dot-source the shared helpers with
`. (Join-Path $PSScriptRoot "_lib\Common.ps1")` and call `Get-DeployedThumbprint`.
`_lib` is a subfolder, so the agent's hook scanner does not execute it.

## Exit codes

- `0` OK or intentionally skipped (role disabled)
- `1` non-fatal skip (e.g. wrong output format)
- `3` fatal
