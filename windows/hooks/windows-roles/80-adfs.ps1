<#
Applies the renewed certificate to AD FS: SSL certificate and (optionally) the
service-communications certificate, then restarts the AD FS service.

Run on a primary AD FS server. Web Application Proxy (WAP) servers must be updated
separately. The AD FS service account needs read access to the private key.

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
    $adfs = $config.Adfs
    if (-not $adfs -or -not $adfs.Enabled) {
        Write-HookLog "AD FS hook disabled in hooks.json. Skipping."
        exit 0
    }

    Import-Module ADFS -ErrorAction Stop
    $thumb = Get-DeployedThumbprint -CurrentPath $CurrentPath -Domain $Domain

    Write-HookLog "Setting AD FS SSL certificate to $thumb ..."
    Set-AdfsSslCertificate -Thumbprint $thumb

    if ($adfs.UpdateServiceCommunications) {
        Write-HookLog "Setting AD FS service-communications certificate to $thumb ..."
        Set-AdfsCertificate -CertificateType Service-Communications -Thumbprint $thumb
    }

    Write-HookLog "Restarting AD FS service (adfssrv) ..."
    Restart-Service adfssrv -Force
    Write-HookLog "AD FS certificate updated. Remember to update any WAP servers."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
