<#
Applies the renewed certificate to Remote Desktop Services roles
(RD Gateway, RD Web Access, RD Connection Broker - Publishing/Redirector).

Set-RDCertificate takes a PFX, so this hook needs OutputFormat = pfx and the
PfxPassword from hooks.json. Run it against (or on) the RD Connection Broker.

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
    $rds = $config.Rds
    if (-not $rds -or -not $rds.Enabled) {
        Write-HookLog "RDS hook disabled in hooks.json. Skipping."
        exit 0
    }

    if ($Format -ne "pfx") { throw "RDS hook requires OutputFormat = pfx." }
    $pfx = Join-Path $CurrentPath "certificate.pfx"
    if (-not (Test-Path -LiteralPath $pfx)) { throw "PFX not found: $pfx" }

    $pfxPassword = [string]$config.PfxPassword
    if ([string]::IsNullOrWhiteSpace($pfxPassword)) { throw "PfxPassword missing in hooks.json" }
    $secure = ConvertTo-SecureString -String $pfxPassword -AsPlainText -Force

    Import-Module RemoteDesktop -ErrorAction Stop

    $broker = if ($rds.ConnectionBroker) { [string]$rds.ConnectionBroker } else { [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName }

    $rolesRaw = if ($rds.Roles) { $rds.Roles } else { @("RDGateway", "RDWebAccess", "RDRedirector", "RDPublishing") }
    $roles = @($rolesRaw)

    foreach ($role in $roles) {
        Write-HookLog "Setting RD certificate for role $role on broker $broker ..."
        Set-RDCertificate -Role $role -ImportPath $pfx -Password $secure -ConnectionBroker $broker -Force
    }

    Write-HookLog "RDS certificates updated."
    exit 0
}
catch {
    Write-HookLog $_.Exception.Message "ERROR"
    exit 3
}
