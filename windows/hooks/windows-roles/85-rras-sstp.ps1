<#
Applies the renewed certificate to the RRAS SSTP VPN listener and restarts the
Remote Access service.

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
    $sstp = $config.RrasSstp
    if (-not $sstp -or -not $sstp.Enabled) {
        Write-HookLog "RRAS/SSTP hook disabled in hooks.json. Skipping."
        exit 0
    }

    Import-Module RemoteAccess -ErrorAction Stop
    $thumb = Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain
    $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumb"

    Write-HookLog "Setting RRAS SSTP certificate to $thumb ..."
    Set-RemoteAccess -SslCertificate $cert -Force

    Write-HookLog "Restarting RemoteAccess service ..."
    Restart-Service RemoteAccess -Force
    Write-HookLog "RRAS SSTP certificate updated."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
