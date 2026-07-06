<#
Posts a certificate-deployed notification to a Microsoft Teams (or generic) webhook.

Because it runs near the end of the pipeline, it fires only on a successful deploy
(a fatal earlier hook aborts the pipeline first). Deployment failures are surfaced by
the platform's monitoring/Teams alerts and by the scheduled task result.

Exit codes: 0 = OK/skip. Notification failure is logged as a warning, not fatal.
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
    $n = $config.Notify
    if (-not $n -or -not $n.Enabled) {
        Write-HookLog "Notify hook disabled in hooks.json. Skipping."
        exit 0
    }

    $webhook = [string]$n.TeamsWebhookUrl
    if ([string]::IsNullOrWhiteSpace($webhook)) {
        Write-HookLog "TeamsWebhookUrl missing in hooks.json; nothing to notify." "WARN"
        exit 0
    }

    $notAfter = ""
    if (Test-Path -LiteralPath $MetadataPath) {
        try { $notAfter = [string]((Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json).not_after) } catch { }
    }

    $card = @{
        "@type"      = "MessageCard"
        "@context"   = "http://schema.org/extensions"
        summary      = "Certificate deployed: $Domain"
        themeColor   = "2EB67D"
        title        = "Certificate deployed: $Domain"
        sections     = @(
            @{
                facts = @(
                    @{ name = "Host";        value = $env:COMPUTERNAME }
                    @{ name = "Service";     value = $ServiceName }
                    @{ name = "Customer";    value = $CustomerNumber }
                    @{ name = "Domain";      value = $Domain }
                    @{ name = "Expires";     value = $notAfter }
                    @{ name = "Fingerprint"; value = $Fingerprint }
                )
            }
        )
    }

    Invoke-RestMethod -Method POST -Uri $webhook -ContentType "application/json" `
        -Body ($card | ConvertTo-Json -Depth 10) | Out-Null
    Write-HookLog "Deploy notification sent."
    exit 0
}
catch {
    Write-HookLog "Notification failed: $($_.Exception.Message)" "WARN"
    exit 0
}
