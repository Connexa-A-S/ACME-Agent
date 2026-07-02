<#
Example hook for CNXA ACME Fetch Agent.

Hooks are executed in alphabetical order. Exit codes:
  0 = OK
  1 = Warning, continue pipeline
  2 = Retry requested, agent exits with failure so scheduled task can retry next run
  3+ = Fatal failure
#>

[CmdletBinding()]
param(
    [string]$CertificatePath,
    [string]$CurrentPath,
    [string]$VersionPath,
    [string]$MetadataPath,
    [string]$Format,
    [string]$ServiceId,
    [string]$ServiceName,
    [string]$CustomerNumber,
    [string]$Domain,
    [string]$Fingerprint,
    [string]$PreviousFingerprint
)

Write-Host "Hook received certificate update for $ServiceName / $Domain"
Write-Host "Current: $CurrentPath"
Write-Host "Version: $VersionPath"
Write-Host "Format:  $Format"
Write-Host "SHA256:  $Fingerprint"

exit 0
