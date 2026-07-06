<#
Enables LDAPS on an Active Directory Domain Controller by placing the renewed
certificate in the AD DS service store (NTDS\Personal) and telling the DC to reload
its LDAPS certificate — without restarting NTDS (which would be disruptive).

Requires OutputFormat = pfx and PfxPassword in hooks.json. Run on each DC.

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
    $ldaps = $config.LdapsDc
    if (-not $ldaps -or -not $ldaps.Enabled) {
        Write-HookLog "LDAPS-DC hook disabled in hooks.json. Skipping."
        exit 0
    }

    if ($Format -ne "pfx") { throw "LDAPS-DC hook requires OutputFormat = pfx." }
    $pfx = Join-Path $CurrentPath "certificate.pfx"
    if (-not (Test-Path -LiteralPath $pfx)) { throw "PFX not found: $pfx" }
    $pfxPassword = [string]$config.PfxPassword
    if ([string]::IsNullOrWhiteSpace($pfxPassword)) { throw "PfxPassword missing in hooks.json" }

    Write-HookLog "Importing certificate into the AD DS service store (NTDS\Personal) ..."
    & certutil -f -p $pfxPassword -importpfx "NTDS\Personal" $pfx | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "certutil -importpfx into NTDS\Personal failed (exit $LASTEXITCODE)." }

    # Non-disruptive reload: tell the DC to re-read its LDAPS certificate via the
    # rootDSE renewServerCertificate operational attribute (no NTDS restart).
    Write-HookLog "Triggering LDAPS certificate reload via rootDSE renewServerCertificate ..."
    $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://localhost/rootDSE")
    $root.Properties["renewServerCertificate"].Value = 1
    $root.CommitChanges()
    $root.Dispose()

    Write-HookLog "LDAPS certificate updated and reloaded."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
