<#
Sets the RDP listener (RDP-Tcp) TLS certificate to the freshly imported certificate.

Applies to the standard Remote Desktop / RDS Session Host listener. RD Gateway,
RD Web and Connection Broker use different roles and are out of scope for this hook.

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
    $rdp = $config.Rdp
    if (-not $rdp -or -not $rdp.Enabled) {
        Write-HookLog "RDP hook disabled in hooks.json. Skipping."
        exit 0
    }

    $thumb = Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain
    Write-HookLog "Setting RDP-Tcp SSL certificate to $thumb."

    $tsSetting = Get-WmiObject -Class "Win32_TSGeneralSetting" `
        -Namespace "root\cimv2\TerminalServices" -Filter "TerminalName='RDP-Tcp'"
    if (-not $tsSetting) {
        throw "RDP-Tcp listener not found (Remote Desktop may not be enabled)."
    }

    Set-WmiInstance -Path $tsSetting.__path -Argument @{ SSLCertificateSHA1Hash = "$thumb" } | Out-Null
    Write-HookLog "RDP listener certificate updated."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
