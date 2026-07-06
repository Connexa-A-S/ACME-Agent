<#
Imports the downloaded PFX into the LocalMachine\My certificate store and records the
resulting thumbprint for the other Windows-role hooks. Requires OutputFormat = pfx.

Exit codes: 0 = OK, 1 = skipped (not a fatal problem), 3 = fatal.
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
    if ($Format -ne "pfx") {
        Write-HookLog "OutputFormat is '$Format'; the windows-roles pack requires pfx. Skipping." "WARN"
        exit 1
    }

    $pfx = Join-Path $CurrentPath "certificate.pfx"
    if (-not (Test-Path -LiteralPath $pfx)) {
        Write-HookLog "PFX not found: $pfx" "ERROR"
        exit 3
    }

    $config = Get-HookConfig -HookRoot $PSScriptRoot
    $pfxPassword = [string]$config.PfxPassword
    if ([string]::IsNullOrWhiteSpace($pfxPassword)) {
        Write-HookLog "PfxPassword missing in hooks.json" "ERROR"
        exit 3
    }

    $secure = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force

    Write-HookLog "Importing PFX into Cert:\LocalMachine\My ..."
    $imported = Import-PfxCertificate -FilePath $pfx `
        -CertStoreLocation Cert:\LocalMachine\My -Password $secure -Exportable
    $thumb = $imported.Thumbprint
    Write-HookLog "Imported. Thumbprint=$thumb Subject=$($imported.Subject) NotAfter=$($imported.NotAfter)"

    Save-DeployedThumbprint -CurrentPath $CurrentPath -Thumbprint $thumb

    # Remove superseded certificates with the same subject so the store does not grow
    # unbounded. Consumer hooks (20/30/40) re-point services at the new thumbprint next.
    $subject = $imported.Subject
    Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq $subject -and $_.Thumbprint -ne $thumb } |
        ForEach-Object {
            try {
                Write-HookLog "Removing superseded certificate Thumbprint=$($_.Thumbprint) NotAfter=$($_.NotAfter)"
                Remove-Item -LiteralPath $_.PSPath -Force
            }
            catch {
                Write-HookLog "Could not remove $($_.Thumbprint): $($_.Exception.Message)" "WARN"
            }
        }

    Write-HookLog "Done."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
