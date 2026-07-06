<#
Points an IIS HTTPS binding at the freshly imported certificate (by thumbprint).

Covers the common single-binding case. For SNI / many-host bindings, extend the
Iis config with additional entries or manage those bindings out of band.

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
    $iis = $config.Iis
    if (-not $iis -or -not $iis.Enabled) {
        Write-HookLog "IIS hook disabled in hooks.json. Skipping."
        exit 0
    }

    Import-Module WebAdministration -ErrorAction Stop

    $thumb = Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain
    $site = if ($iis.SiteName) { [string]$iis.SiteName } else { "Default Web Site" }
    $port = if ($iis.Port) { [int]$iis.Port } else { 443 }
    $hostHeader = [string]$iis.HostHeader

    Write-HookLog "Binding certificate $thumb to IIS site '$site' on port $port (host '$hostHeader')."

    $binding = Get-WebBinding -Name $site -Protocol https -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $binding) {
        Write-HookLog "No https binding found on '$site'; creating one."
        if ([string]::IsNullOrWhiteSpace($hostHeader)) {
            New-WebBinding -Name $site -Protocol https -Port $port
        }
        else {
            New-WebBinding -Name $site -Protocol https -Port $port -HostHeader $hostHeader
        }
        $binding = Get-WebBinding -Name $site -Protocol https -ErrorAction Stop |
            Select-Object -First 1
    }

    # AddSslCertificate replaces the certificate on the binding's IP:port endpoint.
    $binding.AddSslCertificate($thumb, "My")
    Write-HookLog "IIS binding updated."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
