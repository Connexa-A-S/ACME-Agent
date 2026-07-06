<#
Enables the freshly imported certificate for Exchange Server services
(IIS, SMTP, IMAP, POP). Runs on an Exchange server; uses Windows PowerShell 5.1
(the Exchange management snap-in is not available in PowerShell 7).

Exit codes: 0 = OK/skip, 3 = fatal.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CertificatePath,
    [Parameter(Mandatory)][string] $CurrentPath,
    [Parameter(Mandatory)][string] $VersionPath,
    [Parameter(Mandatory)][string] $MetadataPath,
    [Parameter(Mandatory)][string] $Format,
    [string] $ServiceId,
    [string] $ServiceName,
    [string] $CustomerNumber,
    [string] $Domain,
    [string] $Fingerprint,
    [string] $PreviousFingerprint
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_lib\Common.ps1")

try {
    $config = Get-HookConfig -HookRoot $PSScriptRoot
    $ex = $config.Exchange
    if (-not $ex -or -not $ex.Enabled) {
        Write-HookLog "Exchange hook disabled in hooks.json. Skipping."
        exit 0
    }

    if (-not (Get-PSSnapin -Registered -Name "Microsoft.Exchange.Management.PowerShell.SnapIn" -ErrorAction SilentlyContinue)) {
        throw "Exchange management snap-in not found. Run this on an Exchange server with Windows PowerShell 5.1."
    }
    if (-not (Get-PSSnapin -Name "Microsoft.Exchange.Management.PowerShell.SnapIn" -ErrorAction SilentlyContinue)) {
        Add-PSSnapin "Microsoft.Exchange.Management.PowerShell.SnapIn"
    }

    $thumb = Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain

    $servicesRaw = if ($ex.Services) { [string]$ex.Services } else { "IIS,SMTP" }
    $services = $servicesRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    Write-HookLog "Enabling Exchange certificate $thumb for services: $($services -join ', ')"
    Enable-ExchangeCertificate -Thumbprint $thumb -Services $services -Force

    Write-HookLog "Exchange certificate enabled."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
