<#
Creates or updates the WinRM HTTPS listener with the freshly imported certificate,
so remote management over 5986 keeps working after renewal.

Note: this does not open the Windows Firewall for 5986; manage that separately.

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
    $winrm = $config.WinRm
    if (-not $winrm -or -not $winrm.Enabled) {
        Write-HookLog "WinRM hook disabled in hooks.json. Skipping."
        exit 0
    }

    $thumb = Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain
    $hostName = if ($winrm.HostName) { [string]$winrm.HostName } elseif ($Domain) { $Domain } else { $env:COMPUTERNAME }

    $existing = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -contains "Transport=HTTPS" } |
        Select-Object -First 1

    if ($existing) {
        Write-HookLog "Updating existing WinRM HTTPS listener certificate to $thumb."
        Set-WSManInstance -ResourceURI "winrm/config/Listener" `
            -SelectorSet @{ Address = "*"; Transport = "HTTPS" } `
            -ValueSet @{ CertificateThumbprint = $thumb } | Out-Null
    }
    else {
        Write-HookLog "Creating WinRM HTTPS listener (host '$hostName', cert $thumb)."
        New-WSManInstance -ResourceURI "winrm/config/Listener" `
            -SelectorSet @{ Address = "*"; Transport = "HTTPS" } `
            -ValueSet @{ Hostname = $hostName; CertificateThumbprint = $thumb } | Out-Null
    }

    Write-HookLog "WinRM HTTPS listener updated."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
